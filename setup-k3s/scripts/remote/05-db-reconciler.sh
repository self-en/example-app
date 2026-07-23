#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
export ARGOCD_NAMESPACE POSTGRES_NAMESPACE POSTGRES_CLUSTER_NAME

echo "[db-reconciler] applying CronJob that drops per-branch databases whose Application is gone..."
# Restrict envsubst to these three vars only - the manifest embeds a shell
# script with its own $-prefixed variables (token, cacert, expected, ...) that
# unrestricted envsubst would otherwise blank out too.
envsubst '${ARGOCD_NAMESPACE} ${POSTGRES_NAMESPACE} ${POSTGRES_CLUSTER_NAME}' \
  < "$ROOT_DIR/manifests/db-reconciler.yaml.tpl" | kubectl apply -f -

kubectl -n "${POSTGRES_NAMESPACE:-postgres}" get cronjob db-reconciler
