#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
export ARGOCD_NAMESPACE GITHUB_OWNER GITHUB_REPO GITHUB_TOKEN APP_CHART_PATH DOMAIN_SUFFIX

# Baked straight into the ApplicationSet as plain helm parameters (see
# manifests/applicationset.yaml.tpl) so every generated preview can create its
# own per-branch database (via a PreSync/PreDelete hook in example-app/chart)
# without copying any secret into each namespace.
POSTGRES_HOST="${POSTGRES_CLUSTER_NAME:-postgres}-rw.${POSTGRES_NAMESPACE:-postgres}.svc.cluster.local"
POSTGRES_APP_USER="$(kubectl -n "${POSTGRES_NAMESPACE:-postgres}" get secret "${POSTGRES_CLUSTER_NAME:-postgres}-app" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)"
POSTGRES_APP_PASSWORD="$(kubectl -n "${POSTGRES_NAMESPACE:-postgres}" get secret "${POSTGRES_CLUSTER_NAME:-postgres}-app" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
POSTGRES_ADMIN_PASSWORD="$(kubectl -n "${POSTGRES_NAMESPACE:-postgres}" get secret "${POSTGRES_CLUSTER_NAME:-postgres}-superuser" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
export POSTGRES_HOST POSTGRES_APP_USER POSTGRES_APP_PASSWORD POSTGRES_ADMIN_PASSWORD

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "[appset] WARNING: GITHUB_TOKEN is empty - the SCM provider generator will poll" \
       "the GitHub API unauthenticated (60 req/hour) and private repos won't work." >&2
  export GITHUB_TOKEN_REF_BLOCK=""
else
  echo "[appset] applying GitHub token + repo credential secrets..."
  envsubst < "$ROOT_DIR/manifests/github-token-secret.yaml.tpl" | kubectl apply -f -
  envsubst < "$ROOT_DIR/manifests/github-repo-secret.yaml.tpl" | kubectl apply -f -
  export GITHUB_TOKEN_REF_BLOCK=$'tokenRef:\n          secretName: github-token\n          key: token'
fi

echo "[appset] applying branch-previews ApplicationSet for ${GITHUB_OWNER}/${GITHUB_REPO}..."
envsubst < "$ROOT_DIR/manifests/applicationset.yaml.tpl" | kubectl apply -f -

kubectl -n "${ARGOCD_NAMESPACE}" get applicationset branch-previews
