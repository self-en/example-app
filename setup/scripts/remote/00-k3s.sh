#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "[k3s] checking prerequisites..."
if ! command -v gettext-base >/dev/null 2>&1 && ! command -v envsubst >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y gettext-base
fi

if command -v k3s >/dev/null 2>&1; then
  echo "[k3s] already installed, skipping"
else
  echo "[k3s] installing (Traefik disabled, kubeconfig readable by the ubuntu user)..."
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_EXEC="server --disable=traefik --write-kubeconfig-mode=644" sh -s -
fi

echo "[k3s] waiting for node to be Ready..."
for i in $(seq 1 30); do
  if kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
    break
  fi
  sleep 2
done
kubectl get nodes

if command -v helm >/dev/null 2>&1; then
  echo "[helm] already installed, skipping"
else
  echo "[helm] installing..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm version
