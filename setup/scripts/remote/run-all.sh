#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for step in 00-k3s.sh 01-envoy-gateway.sh dnsmasq.sh 02-argocd.sh 03-postgres.sh 04-appset.sh; do
  echo ""
  echo "=== Running $step ==="
  bash "$SCRIPT_DIR/$step"
done

echo ""
echo "=== Install complete ==="
