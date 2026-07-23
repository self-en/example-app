#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"

PURGE_K3S=false
[[ "${1:-}" == "--purge-k3s" ]] && PURGE_K3S=true

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[uninstall] kubectl not found - k3s was probably never installed, nothing to do."
  exit 0
fi

echo "[uninstall] deleting branch-previews ApplicationSet (cascades to generated Applications)..."
kubectl -n "${ARGOCD_NAMESPACE:-argocd}" delete applicationset branch-previews --ignore-not-found --timeout=120s

echo "[uninstall] waiting for generated Applications to finish pruning..."
for i in $(seq 1 30); do
  remaining=$(kubectl -n "${ARGOCD_NAMESPACE:-argocd}" get applications -l branch --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "$remaining" == "0" ]] && break
  sleep 2
done

echo "[uninstall] removing any leftover preview-* namespaces..."
kubectl get ns -o name 2>/dev/null | grep '^namespace/preview-' | xargs -r kubectl delete --wait=true --timeout=120s || true

echo "[uninstall] deleting Postgres Cluster + CloudNativePG operator..."
kubectl -n "${POSTGRES_NAMESPACE:-postgres}" delete cluster "${POSTGRES_CLUSTER_NAME:-postgres}" --ignore-not-found
helm uninstall cnpg -n cnpg-system >/dev/null 2>&1 || true
kubectl delete namespace "${POSTGRES_NAMESPACE:-postgres}" --ignore-not-found
kubectl delete namespace cnpg-system --ignore-not-found

echo "[uninstall] deleting Envoy Gateway..."
kubectl -n "${GATEWAY_NAMESPACE:-envoy-gateway-system}" delete gateway "${GATEWAY_NAME:-eg}" --ignore-not-found
kubectl delete gatewayclass envoy --ignore-not-found
helm uninstall eg -n "${GATEWAY_NAMESPACE:-envoy-gateway-system}" >/dev/null 2>&1 || true
kubectl delete namespace "${GATEWAY_NAMESPACE:-envoy-gateway-system}" --ignore-not-found

echo "[uninstall] deleting ArgoCD..."
helm uninstall argocd -n "${ARGOCD_NAMESPACE:-argocd}" >/dev/null 2>&1 || true
kubectl delete namespace "${ARGOCD_NAMESPACE:-argocd}" --ignore-not-found

echo "[uninstall] removing dnsmasq config..."
sudo rm -f /etc/dnsmasq.d/self-en.conf
sudo systemctl restart dnsmasq 2>/dev/null || true

if $PURGE_K3S; then
  echo "[uninstall] purging k3s entirely (--purge-k3s)..."
  sudo /usr/local/bin/k3s-uninstall.sh || true
else
  echo "[uninstall] k3s itself was left installed. Re-run with --purge-k3s to remove it completely."
fi

echo "[uninstall] done."
