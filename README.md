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
  consumato da un template `HTTPRoute` (vedi `charts/example-app` come
  riferimento/contratto minimo da copiare e adattare).
- **`GITHUB_OWNER` deve essere una GitHub Organization**, non un account utente
  personale: il generator `scmProvider.github` di ArgoCD chiama solo l'API "list
  org repos" e restituisce 404 su un account personale (verificato). Creare una
  org gratuita se non se ne ha già una (github.com/account/organizations/new).

## Setup

```bash
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

- Il segreto di connessione Postgres (`<POSTGRES_CLUSTER_NAME>-app`, chiavi
  `username`/`password`/`uri`) vive nel namespace `postgres`. Le app di preview
  girano in namespace `preview-<slug>` separati: se un'app deve accedere al
  database, il segreto va copiato/sincronizzato nel suo namespace (fuori scope
  di questa automazione base).
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
- Accesso alla UI di ArgoCD (non esposta su Gateway in questa automazione):
  `ssh -L 8080:localhost:8080 ubuntu kubectl -n argocd port-forward svc/argocd-server 8080:443`
  poi `https://localhost:8080` (utente `admin`, password in
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).

## Uninstall

```bash
./scripts/uninstall.sh                 # rimuove ApplicationSet/app, Postgres, Envoy Gateway, ArgoCD, dnsmasq
./scripts/uninstall.sh --purge-k3s     # come sopra, e in più disinstalla k3s dal nodo (distruttivo, chiede conferma)
```
