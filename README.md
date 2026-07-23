# self-en: piattaforma di preview per branch su k3s

Installa su una singola VM (raggiungibile via `ssh <SSH_HOST>`, default `ubuntu`):

- **k3s** (Traefik disabilitato, servicelb attivo)
- **Envoy Gateway** (Gateway API) con un `Gateway` condiviso su porta 80
- **ArgoCD** con un `ApplicationSet` che scopre ogni branch di un repo GitHub e
  crea/aggiorna automaticamente un ambiente di preview raggiungibile su
  `<branch-slug>.self-en.local`, senza bisogno di modifiche nel branch
- **CloudNativePG** con un'istanza Postgres condivisa sul cluster
- **dnsmasq** sulla VM per risolvere `*.self-en.local` verso se stessa

## Prerequisiti

- Accesso SSH funzionante e passwordless sudo sull'host target (`ssh ubuntu` deve
  già funzionare, come verificato).
- `rsync`, `ssh` disponibili in locale.
- Un repository GitHub il cui contenuto, per ogni branch, includa un Helm chart
  nel percorso indicato da `APP_CHART_PATH` che esponga un value `hostname`
  consumato da un template `HTTPRoute` (vedi `helm/` come riferimento/contratto
  minimo da copiare e adattare). **Questo stesso repo** soddisfa già il
  requisito: è il repo GitHub configurato di default (`self-en/example-app`) e
  contiene sia l'app demo (`example-app/`, con la sua pipeline CI in
  `.github/workflows/example-app.yml` che builda e pusha l'immagine su GHCR ad
  ogni push) sia il chart che la deploya (`example-app/chart`,
  `APP_CHART_PATH=example-app/chart`).
- **`GITHUB_OWNER` deve essere una GitHub Organization**, non un account utente
  personale: il generator `scmProvider.github` di ArgoCD chiama solo l'API "list
  org repos" e restituisce 404 su un account personale (verificato). Creare una
  org gratuita se non se ne ha già una (github.com/account/organizations/new).

## Setup

```bash
cd setup-k3s
cp .env.example .env
$EDITOR .env   # imposta GITHUB_OWNER, GITHUB_REPO, GITHUB_TOKEN, APP_CHART_PATH, ...
```

## Install

```bash
./scripts/install.sh
```

Sincronizza il progetto sull'host remoto ed esegue in ordine:
`k3s → Envoy Gateway (+ GatewayClass/Gateway) → dnsmasq → ArgoCD → CloudNativePG → ApplicationSet`.
Ogni step è idempotente (ri-eseguibile senza effetti collaterali).

## Verifica

```bash
ssh ubuntu kubectl get nodes
ssh ubuntu kubectl -n argocd get applicationset,application
ssh ubuntu kubectl -n envoy-gateway-system get gateway,gatewayclass
ssh ubuntu kubectl -n postgres get cluster
```

Configura la risoluzione DNS sul tuo client (es. macOS, dominio scoped, non
tocca la risoluzione degli altri domini):

```bash
sudo mkdir -p /etc/resolver
printf 'nameserver %s\n' '<IP-nodo-ubuntu>' | sudo tee /etc/resolver/self-en.local
```

Poi, per un branch esistente nel repo (es. `feature/foo`):

```bash
curl http://feature-foo.self-en.local/
```

Push di un nuovo branch nel repo configurato → entro `requeueAfterSeconds`
(default 180s, in `manifests/applicationset.yaml.tpl`) compare una nuova
`Application` ArgoCD e il relativo namespace `preview-<slug>`. Cancellare il
branch rimuove automaticamente Application e risorse deployate (Deployment,
Service, HTTPRoute) grazie al finalizer `resources-finalizer.argocd.argoproj.io`
- comportamento verificato end-to-end.

## Note

- La pipeline `.github/workflows/example-app.yml` builda `example-app/` e pusha
  l'immagine su `ghcr.io/self-en/example-app/example-app`, taggata con lo slug
  del branch (stessa regola di `slugify` usata da ArgoCD per l'hostname). Il
  chart (`example-app/chart`) riceve quel tag tramite il parametro helm
  `image.tag` impostato dall'ApplicationSet: ogni preview scarica quindi la
  build fatta dal proprio branch, senza bisogno di un commit di bump del tag.
  **Il package GHCR deve essere pubblico** perché k3s riesca a fare il pull
  in modo anonimo. GitHub non offre un modo per cambiare la visibilità di un
  package via API (solo UI: Package settings → Change visibility - se il
  radio button/pulsante non risponde con "Setting is disabled by organization
  administrators", è una restrizione anti-abuso di GitHub su org nuove/non
  verificate, non qualcosa che l'owner può sbloccare da lì; in alcuni casi
  **Organization → Settings → Packages → "Package creation"** permette di
  impostare la visibilità di default per i *nuovi* package, il che sblocca il
  problema se cancelli il package esistente e lo lasci ricreare dalla
  pipeline). In alternativa, se il package resta privato, c'è un
  `imagePullSecret` opzionale nel chart (`imagePullSecret.name`, default
  `ghcr-pull-secret`, vedi `example-app/chart/values.yaml`):
  ```bash
  ssh ubuntu 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; \
    kubectl -n preview-<slug> create secret docker-registry ghcr-pull-secret \
    --docker-server=ghcr.io --docker-username=<github-username> \
    --docker-password="<PAT con scope read:packages>" \
    --docker-email=noreply@example.com --dry-run=client -o yaml | kubectl apply -f -'
  ```
  Non viene creato automaticamente nei namespace `preview-<slug>` futuri, va
  ripetuto per ogni branch (irrilevante finché il package resta pubblico).
- **Ogni preview ha il proprio database**, isolato dalle altre, sullo stesso
  cluster Postgres condiviso (un database logico per branch, non un'istanza
  Postgres dedicata - resta leggero su una VM single-node). `04-appset.sh`
  legge una volta le credenziali reali (`<POSTGRES_CLUSTER_NAME>-app` per
  l'utente applicativo, `<POSTGRES_CLUSTER_NAME>-superuser` per creare/droppare
  database - richiede `enableSuperuserAccess: true` sul Cluster CNPG) e le
  passa come parametri helm all'ApplicationSet (vedi
  `manifests/applicationset.yaml.tpl`). Il chart (`example-app/chart`):
  - crea il database `preview_<slug>` al primo sync con un hook `PreSync`
    (`templates/db-create-job.yaml`) - idempotente, non tocca nulla se esiste già.

  La cancellazione **non** è un hook `PreDelete` nel chart: un `PreDelete`
  richiede ad ArgoCD di rigenerare i manifest dell'hook al momento della
  cancellazione, ma a quel punto il branch è già sparito da git e ArgoCD non
  riesce a risolvere `targetRevision` a un commit ("unable to resolve
  '<branch>' to a commit SHA" - **verificato**, l'`Application` resta bloccata
  in `Terminating` per sempre). La pulizia è invece un `CronJob`
  (`manifests/db-reconciler.yaml.tpl`, ogni 5 minuti, installato una volta da
  `05-db-reconciler.sh`) che confronta i database `preview_*` esistenti con le
  `Application` ArgoCD ancora presenti (via label `branch`) e droppa (`WITH
  (FORCE)`) quelli senza più un'`Application` corrispondente - **verificato
  end-to-end**: creato un branch di prova, confermato il database isolato
  (`preview_<slug>`), cancellato il branch (l'`Application` si elimina pulita,
  a differenza del tentativo con `PreDelete`), triggerato il CronJob e
  confermato che il database orfano viene droppato.

  Stessa scelta "niente sicurezza" già vista sopra per GHCR: credenziali
  (incluso l'accesso superuser a Postgres) in chiaro nello spec
  dell'`Application`/nei Job/nel CronJob, per semplicità.
- Se il repo GitHub è pubblico e non imposti `GITHUB_TOKEN`, il generator SCM
  di ArgoCD interroga la API di GitHub non autenticato (limite 60 richieste/ora):
  con `requeueAfterSeconds: 180` sono ~20 richieste/ora, entro il limite, ma
  consigliato impostare comunque un token per margine e per repo privati.
- **Limite noto**: quando un branch viene cancellato, ArgoCD rimuove
  l'`Application` e tutte le risorse al suo interno, ma il namespace
  `preview-<slug>` creato via `CreateNamespace=true` resta (vuoto) - ArgoCD non
  lo traccia come risorsa da eliminare. `scripts/uninstall.sh` ripulisce tutti i
  namespace `preview-*` residui in fase di disinstallazione completa; per una
  pulizia periodica durante l'uso normale servirebbe un CronJob dedicato (non
  incluso, fuori scope base).
- Accesso alla UI di ArgoCD: esposta sul Gateway condiviso su
  `http://argocd.self-en.local/` (HTTP semplice, coerente col resto della
  piattaforma - nessuna cifratura, va bene su una VM/LAN di fiducia). Utente
  `admin`, password in
  `ssh ubuntu kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
  In alternativa, senza passare dal DNS: `ssh -L 8080:localhost:8080 ubuntu
  kubectl -n argocd port-forward svc/argocd-server 8080:443` poi
  `https://localhost:8080`.

## Uninstall

```bash
./scripts/uninstall.sh                 # rimuove ApplicationSet/app, Postgres, Envoy Gateway, ArgoCD, dnsmasq
./scripts/uninstall.sh --purge-k3s     # come sopra, e in più disinstalla k3s dal nodo (distruttivo, chiede conferma)
```
