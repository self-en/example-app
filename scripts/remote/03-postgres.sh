#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
export POSTGRES_NAMESPACE POSTGRES_CLUSTER_NAME

echo "[cnpg] installing/upgrading CloudNativePG operator via Helm..."
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null

helm upgrade --install cnpg cnpg/cloudnative-pg \
  -n cnpg-system --create-namespace \
  --wait --timeout 5m

echo "[cnpg] creating Postgres Cluster..."
kubectl create namespace "${POSTGRES_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
envsubst < "$ROOT_DIR/manifests/postgres-cluster.yaml" | kubectl apply -f -

echo "[cnpg] waiting for cluster to become Ready (can take a couple of minutes)..."
kubectl wait --timeout=5m -n "${POSTGRES_NAMESPACE}" "cluster/${POSTGRES_CLUSTER_NAME}" --for=condition=Ready || \
  echo "[cnpg] not Ready yet - check with: kubectl -n ${POSTGRES_NAMESPACE} get cluster,pods"

echo "[cnpg] connection secret: ${POSTGRES_CLUSTER_NAME}-app (keys: username, password, uri) in namespace ${POSTGRES_NAMESPACE}"
