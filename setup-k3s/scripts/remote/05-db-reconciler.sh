#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
export ARGOCD_NAMESPACE POSTGRES_NAMESPACE POSTGRES_CLUSTER_NAME

echo "[db-reconciler] applying CronJob that drops per-branch databases whose Application is gone..."
envsubst < "$ROOT_DIR/manifests/db-reconciler.yaml.tpl" | kubectl apply -f -

kubectl -n "${POSTGRES_NAMESPACE:-postgres}" get cronjob db-reconciler
