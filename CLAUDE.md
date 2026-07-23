# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`self-en` provisions a single-VM k3s cluster that acts as a branch-preview platform:
push a branch to a configured GitHub repo and ArgoCD automatically deploys it at
`<branch-slug>.self-en.local`. The platform automation (`setup-k3s/`) is pure
shell/Helm/Kubernetes manifests; the only actual application is `example-app/`
(a small Node/Express + Postgres todo app), which exists to exercise the
platform end-to-end.

This repo **is itself** the GitHub repo the platform watches (`GITHUB_OWNER=self-en`,
`GITHUB_REPO=example-app`, matching this repo's own `origin` remote) — it's
self-referential/dogfooding, not a separate "target" repo.

Everything under `setup-k3s/` is synced to the remote host with `rsync` and executed
there; nothing runs locally except orchestration (`ssh`/`rsync`).

## Commands

```bash
cd setup-k3s
cp .env.example .env && $EDITOR .env   # set GITHUB_OWNER (must be an Org, see below), GITHUB_REPO, GITHUB_TOKEN, APP_CHART_PATH

./scripts/install.sh                   # rsync setup-k3s/ to $SSH_HOST:~/self-en, then run remote/run-all.sh there
./scripts/uninstall.sh                 # tear down ApplicationSet/apps, Postgres, Envoy Gateway, ArgoCD, dnsmasq
./scripts/uninstall.sh --purge-k3s     # same, plus removes k3s itself (destructive, asks for confirmation)
```

There is no build, lint, or test suite — this is infrastructure automation.
"Testing" a change means re-running `install.sh` against the target VM (every
remote step is idempotent/re-runnable) and checking state with `kubectl`, e.g.:

```bash
ssh ubuntu kubectl get nodes
ssh ubuntu kubectl -n argocd get applicationset,application
ssh ubuntu kubectl -n envoy-gateway-system get gateway,gatewayclass
ssh ubuntu kubectl -n postgres get cluster
```

To run a single remote step in isolation (e.g. while iterating on one script),
sync then invoke it directly instead of `run-all.sh`:

```bash
rsync -az --delete --exclude '.git' setup-k3s/ ubuntu:~/self-en/
ssh ubuntu 'bash ~/self-en/scripts/remote/03-postgres.sh'
```

## Architecture

**Orchestration flow**: `scripts/install.sh` reads `.env`, rsyncs the project to
the remote host, then runs `scripts/remote/run-all.sh`, which executes these
steps in order (each is idempotent):

```
00-k3s.sh → 01-envoy-gateway.sh → dnsmasq.sh → 02-argocd.sh → 03-postgres.sh → 04-appset.sh
```

Each `remote/*.sh` script independently `source`s `setup-k3s/.env`, exports the
variables it needs, and uses `envsubst` to render the matching template(s) in
`manifests/*.yaml.tpl` (or plain `.yaml`) before `kubectl apply -f -`. There is
no shared templating engine — `envsubst` + shell env vars is the whole
mechanism, so a new install step generally means: a `manifests/*.yaml(.tpl)`
file, a `scripts/remote/NN-*.sh` step, and an entry in `run-all.sh` (and its
mirror in `uninstall-all.sh`).

`scripts/uninstall.sh` mirrors this by rsyncing then running
`scripts/remote/uninstall-all.sh`, which tears things down in roughly reverse
order and independently sweeps any leftover `preview-*` namespaces (see
Known limitation below).

**Branch-preview mechanism** (`manifests/applicationset.yaml.tpl`): a single
ArgoCD `ApplicationSet` uses the `scmProvider.github` generator (`allBranches:
true`, filtered to `GITHUB_REPO`) to poll for branches every
`requeueAfterSeconds` (default 180s). For each branch it templates (via
`goTemplate`/`slugify`) an `Application` named `preview-<branch-slug>` that:
- deploys the Helm chart at `APP_CHART_PATH` from that branch,
- passes the per-branch hostname as a Helm parameter (`hostname={{branch-slug}}.${DOMAIN_SUFFIX}`),
- targets namespace `preview-<branch-slug>` (auto-created via `CreateNamespace=true`),
- has `resources-finalizer.argocd.argoproj.io` so deleting the branch prunes the
  Deployment/Service/HTTPRoute/Application together (verified end-to-end per README).

**Chart contract**: any chart deployed by the ApplicationSet (`APP_CHART_PATH`)
MUST accept a `hostname` value and consume it in an `HTTPRoute` bound to the
shared Gateway (`gateway.name`/`gateway.namespace`, matching
`GATEWAY_NAME`/`GATEWAY_NAMESPACE`). `helm/` at the repo root is the generic
reference/minimal implementation of this contract (Deployment + Service +
HTTPRoute, nginx by default) — copy and adapt it for other apps rather than
editing it in place. `example-app/chart` is that same contract adapted for the
real demo app (`APP_CHART_PATH=example-app/chart` in `.env`).

**example-app CI/CD** (`.github/workflows/example-app.yml` +
`example-app/chart`): on every push touching `example-app/**`, the workflow
builds `example-app/Dockerfile` and pushes it to
`ghcr.io/self-en/example-app/example-app`, tagged with both the short commit
sha and the pushed branch's slug (computed with the same lowercase/`[^a-z0-9]`→`-`
rule as ArgoCD's `slugify`). The ApplicationSet passes an extra helm parameter,
`image.tag={{.branch | slugify}}`, so each branch's preview Deployment pulls
the image that branch's own CI run just built — no separate "deploy" step or
image-tag-bump commit needed. On `pull_request` events the workflow only
builds (to validate the Dockerfile), it doesn't push.

One thing this still depends on: the `ghcr.io/self-en/example-app/example-app`
package must be public, otherwise k3s can't pull it. GitHub has no API to
change package visibility (verified: no REST/GraphQL endpoint for it) — only
the package's own "Change visibility" UI page, which can be blocked by
GitHub's anti-abuse restrictions on new/unverified orgs ("Setting is disabled
by organization administrators" — not something the org owner can override
from that page; check Organization → Settings → Packages → "Package
creation" for a default-visibility policy instead, which applies to
newly-created packages). If it has to stay private, `example-app/chart`
supports an optional `imagePullSecrets` entry (`imagePullSecret.name`, default
`ghcr-pull-secret`) — that secret still has to be created manually per
`preview-<slug>` namespace (see README), since it's credential material and
deliberately NOT baked into the ApplicationSet the way Postgres credentials
are below.

**Postgres access for previews — one isolated database per branch**:
`04-appset.sh` reads the real app-user and superuser passwords straight out of
the `<POSTGRES_CLUSTER_NAME>-app`/`-superuser` secrets (namespace `postgres`;
superuser access requires `enableSuperuserAccess: true` on the CNPG `Cluster`,
see `manifests/postgres-cluster.yaml`) and passes them as plain
`postgres.host`/`appUser`/`appPassword`/`adminPassword` helm parameters on the
ApplicationSet (`manifests/applicationset.yaml.tpl`). The chart
(`example-app/chart`) does the rest, entirely on its own, with no per-branch
involvement from the platform scripts:
- `templates/db-create-job.yaml`, a `PreSync` hook Job, creates a database
  named `example-app.dbName` (`_helpers.tpl`: `.Release.Name` with `-` → `_`,
  e.g. `preview-main` → `preview_main`) if it doesn't already exist, owned by
  the app user.
- `templates/deployment.yaml` builds `DATABASE_URL` from the same helm values
  plus that database name — one shared Postgres Cluster, one database per
  branch, not one Postgres instance per branch (keeps this light on a
  single-node VM).
- `templates/db-drop-job.yaml`, a `PreDelete` hook Job, runs
  `DROP DATABASE ... WITH (FORCE)` for that same database. **PreDelete hooks
  only fire on genuine Application deletion** (the finalizer-driven teardown
  that happens when a branch disappears from the ApplicationSet's generator),
  not on ordinary resource pruning within a still-existing Application's sync
  — that distinction is exactly why this works for "branch deleted → DB
  deleted" here.

No Kubernetes Secret anywhere in this path, no per-namespace copying —
deliberately simple/insecure (including handing every preview's Job the
Postgres *superuser* password), chosen because this is a single-tenant lab VM,
not a place credentials need to be defended in depth.

**Networking**: one shared Envoy Gateway (`manifests/gateway.yaml`/
`gatewayclass.yaml`) listens on port 80 for `*.${DOMAIN_SUFFIX}` and fans out
to every preview namespace via per-app `HTTPRoute`s. `dnsmasq.sh` configures
the VM to resolve `*.${DOMAIN_SUFFIX}` to itself; clients point at the VM via
`/etc/resolver/<DOMAIN_SUFFIX>` (macOS) so only that domain is affected.

The ArgoCD UI rides the same Gateway: `02-argocd.sh` applies
`manifests/argocd-httproute.yaml.tpl` right after the Helm install, routing
`argocd.${DOMAIN_SUFFIX}` to the `argocd-server` Service's port 80 (which
targets container port 8080 — plain HTTP, since `argocd-values.yaml` sets
`server.insecure: true` specifically so it can sit behind the Gateway without
TLS). This mirrors the per-app `HTTPRoute` pattern rather than introducing a
new mechanism.

**Constraint — `GITHUB_OWNER` must be a GitHub Organization**, not a personal
account: ArgoCD's `scmProvider.github` generator only calls the "list org
repos" API and 404s on personal accounts (confirmed by testing).

## Known limitations (from README, don't "fix" without discussing scope)

- Deleting a branch removes the ArgoCD `Application` and its resources, but the
  `preview-<slug>` namespace (created via `CreateNamespace=true`) is not tracked
  by ArgoCD and is left behind, empty. `uninstall.sh` sweeps these during full
  teardown; there's no periodic cleanup during normal operation (out of scope).
- Without `GITHUB_TOKEN`, the SCM generator polls the GitHub API unauthenticated
  (60 req/hour limit) — fine at the default 180s requeue interval (~20 req/hour)
  but private repos require a token regardless.
