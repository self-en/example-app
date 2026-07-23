#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
export GATEWAY_NAME GATEWAY_NAMESPACE DOMAIN_SUFFIX

echo "[envoy-gateway] installing/upgrading via Helm..."
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION:-v1.8.3}" \
  -n envoy-gateway-system --create-namespace \
  --wait --timeout 5m

kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "[envoy-gateway] applying GatewayClass + Gateway..."
envsubst < "$ROOT_DIR/manifests/gatewayclass.yaml" | kubectl apply -f -
envsubst < "$ROOT_DIR/manifests/gateway.yaml" | kubectl apply -f -

echo "[envoy-gateway] waiting for Gateway to be programmed..."
kubectl wait --timeout=5m -n "${GATEWAY_NAMESPACE}" "gateway/${GATEWAY_NAME}" --for=condition=Programmed || true
kubectl -n "${GATEWAY_NAMESPACE}" get gateway,gatewayclass
