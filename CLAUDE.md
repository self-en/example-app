# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small Node/Express + Postgres todo app, used as the real demo application
for the [self-en/infra](https://github.com/self-en/infra) branch-preview
platform. This repo contains only the app and its own Helm chart — the
platform automation (k3s, Envoy Gateway, ArgoCD, CloudNativePG, per-branch
database isolation) lives in `self-en/infra`, not here.

`self-en/infra`'s ArgoCD `ApplicationSet` watches every branch of this repo
and deploys `chart/` from it, passing three things in as Helm parameters at
sync time (not stored in this repo): the per-branch hostname, the image tag
matching this branch's own CI build, and Postgres connection info for a
database dedicated to that branch.

## Workflow

Ogni volta che viene richiesta una modifica al codice, crea prima un nuovo
branch (a partire da `main` aggiornato) e lavora lì — non committare mai
direttamente su `main`.

## Commands

```bash
cd backend && npm install        # only needed for editing outside Docker
docker build -t example-app:dev .
docker run --rm -p 3000:3000 -e DATABASE_URL="postgresql://user:pass@host:5432/db" example-app:dev
```

No build/lint/test suite. "Testing" a change means running the container
locally against a real Postgres (see README) and hitting `/api/health`,
`/api/todos`, and `/` (frontend). For the full deployed path (branch → CI
build → ArgoCD sync → live preview), see self-en/infra.

`helm lint chart` / `helm template chart --set hostname=... --set image.tag=...
--set postgres.appPassword=... --set postgres.adminPassword=...` to check the
chart renders before pushing — the ApplicationSet in self-en/infra needs all
of `hostname`, `image.tag`, `postgres.host`, `postgres.appUser`,
`postgres.appPassword`, `postgres.adminPassword` to actually work; without
them the chart still renders (empty defaults in `chart/values.yaml`) but the
app has no `DATABASE_URL`.

## Architecture

**Backend** (`backend/src/index.js`): single-file Express app. Connects to
Postgres via `DATABASE_URL` (or discrete `PGHOST`/`PGUSER`/... env vars, which
`pg.Pool` reads natively if `DATABASE_URL` is unset), creates the `todos`
table on startup if missing, and serves `frontend/` as static files from the
same process/port — deliberately one process, one container, matching the
chart's single Deployment/Service.

**Frontend** (`frontend/`): no build step, no framework. `app.js` fetches
`/api/todos` and does the dark-mode toggle (CSS custom properties in
`style.css`, switched via `data-theme` on `<html>`, default from
`prefers-color-scheme`, persisted in `localStorage`).

**Chart** (`chart/`): implements self-en/infra's chart contract (accept
`hostname`, wire it into an `HTTPRoute` on the shared Gateway named by
`gateway.name`/`gateway.namespace`). Beyond that minimum:
- `templates/db-create-job.yaml`, an ArgoCD `PreSync` hook Job, creates a
  Postgres database named after the release (`.Release.Name` with `-` → `_`,
  e.g. `preview-main` → `preview_main`, see `templates/_helpers.tpl`) if it
  doesn't exist yet, owned by `postgres.appUser`. Needs `postgres.adminPassword`
  since creating a database isn't something the app's own user can do.
- `templates/deployment.yaml` builds `DATABASE_URL` directly from the
  `postgres.*` values plus that per-branch database name — plain env var, no
  Kubernetes Secret (self-en/infra's call, not this repo's — credentials
  arrive as helm parameters set at sync time, deliberately not secured).
- Cleanup (dropping that database when the branch is gone) is NOT done here:
  it can't be, since ArgoCD can't re-render a `PreDelete` hook once the branch
  is deleted from git. self-en/infra runs a separate reconciler CronJob for
  that — see its CLAUDE.md if you need the detail.

**Image tags**: `.github/workflows/example-app.yml` pushes
`ghcr.io/self-en/example-app/example-app` tagged with the short commit sha
always, and — on push events only — with the branch slug computed by the
same lowercase/`[^a-z0-9]`→`-` rule ArgoCD's `slugify` uses. That match
matters: self-en/infra's ApplicationSet sets the chart's `image.tag` to
`{{.branch | slugify}}`, so it must land on the exact tag this workflow
pushed for that branch.

**Auto-redeploy on every commit**: `image.tag` alone doesn't change between
commits to the same branch (still just the branch slug), so ArgoCD wouldn't
otherwise see any Deployment spec drift and would leave already-running pods
on stale content. self-en/infra's ApplicationSet also passes `commitSha`
(the scmProvider generator's `{{.sha}}`, which does change every push), and
`templates/deployment.yaml` stamps it as a pod annotation
(`self-en.dev/commit-sha`) — so the spec genuinely differs on every commit,
`selfHeal: true` redeploys automatically, and `imagePullPolicy: Always` then
pulls the fresh image.
