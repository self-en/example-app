# example-app

Piccola todo app (Node/Express + Postgres, frontend statico vanilla JS) usata
come esempio reale per validare la piattaforma di preview
[self-en/infra](https://github.com/self-en/infra): un `Deployment` +
`Service` + `HTTPRoute` per branch, ognuno con il proprio database Postgres
isolato.

## Struttura

- `backend/` — API Express (`GET/POST /api/todos`, `PATCH/DELETE /api/todos/:id`),
  connessione a Postgres via `DATABASE_URL`, serve anche il frontend statico.
- `frontend/` — HTML/CSS/JS vanilla (nessuna build), con toggle dark/light mode
  (rispetta `prefers-color-scheme`, persistito in `localStorage`).
- `chart/` — Helm chart che deploya l'app (Deployment/Service/HTTPRoute +
  hook `PreSync` che crea il database isolato per il branch). Contratto
  minimo di riferimento in [self-en/infra](https://github.com/self-en/infra)'s `helm/`.
- `Dockerfile` — singolo stage `node:20-alpine`, serve backend+frontend sulla
  porta 3000 (`PORT` override via env).

## Sviluppo locale

```bash
docker build -t example-app:dev .
docker run --rm -p 3000:3000 -e DATABASE_URL="postgresql://user:pass@host:5432/db" example-app:dev
```

`DATABASE_URL` è opzionale in sviluppo: senza Postgres raggiungibile il
processo esce all'avvio (fallisce la connessione), stessa logica usata in
produzione dalla piattaforma di preview.

## Observability (OpenTelemetry)

L'app supporta metriche e log via OpenTelemetry (nessuna traccia - vedi
`backend/src/instrumentation.js`). Disabilitato di default: viene avviato
solo se è impostata `OTEL_EXPORTER_OTLP_ENDPOINT` (endpoint HTTP di un OTLP
collector, es. `http://otel-collector:4318`), per non generare errori di
connessione a vuoto in locale o in preview senza collector configurato.

```bash
docker run --rm -p 3000:3000 \
  -e DATABASE_URL="postgresql://user:pass@host:5432/db" \
  -e OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4318" \
  -e OTEL_SERVICE_NAME="example-app" \
  example-app:dev
```

`OTEL_SERVICE_NAME` è opzionale (default `example-app`). Il chart espone lo
stesso comportamento tramite `otel.endpoint` in `chart/values.yaml` (vuoto di
default, impostato per branch da self-en/infra una volta disponibile un
collector).

## CI/CD

`.github/workflows/example-app.yml` builda e pusha l'immagine su
`ghcr.io/self-en/example-app/example-app` ad ogni push, taggata con lo sha
corto e con lo slug del branch (stessa regola di `slugify` usata da ArgoCD
per l'hostname di preview) - il chart (`chart/values.yaml`) riceve quel tag
tramite il parametro helm `image.tag` impostato dall'ApplicationSet in
self-en/infra, così ogni preview scarica la build fatta dal proprio branch.

**Il package GHCR deve essere pubblico** perché il cluster k3s riesca a fare
il pull anonimo - vedi il README di self-en/infra per i dettagli e
l'alternativa con `imagePullSecret`.

## Deploy

Non gestito da questo repo: [self-en/infra](https://github.com/self-en/infra)
lo fa automaticamente per ogni branch, tramite un ArgoCD `ApplicationSet` che
punta a `chart/` qui dentro (`APP_CHART_PATH=chart`).

