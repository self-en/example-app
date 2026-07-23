#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
export ARGOCD_NAMESPACE GATEWAY_NAME GATEWAY_NAMESPACE DOMAIN_SUFFIX

echo "[argocd] installing/upgrading via Helm..."
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

helm upgrade --install argocd argo/argo-cd \
  -n "${ARGOCD_NAMESPACE:-argocd}" --create-namespace \
  -f "$ROOT_DIR/manifests/argocd-values.yaml" \
  --wait --timeout 8m

kubectl -n "${ARGOCD_NAMESPACE:-argocd}" get pods

echo "[argocd] exposing UI at http://argocd.${DOMAIN_SUFFIX}/ via the shared Gateway..."
envsubst < "$ROOT_DIR/manifests/argocd-httproute.yaml.tpl" | kubectl apply -f -
