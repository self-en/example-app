#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"

if ! command -v dnsmasq >/dev/null 2>&1; then
  echo "[dnsmasq] installing..."
  sudo apt-get update -y
  sudo apt-get install -y dnsmasq
fi

NODE_IP="$(hostname -I | awk '{print $1}')"

echo "[dnsmasq] configuring *.${DOMAIN_SUFFIX} -> ${NODE_IP}"
sudo tee /etc/dnsmasq.d/self-en.conf > /dev/null <<EOF
# Managed by self-en automation - do not edit by hand
address=/${DOMAIN_SUFFIX}/${NODE_IP}
listen-address=${NODE_IP}
bind-interfaces
EOF

sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

echo "[dnsmasq] done. Node IP: ${NODE_IP}"
echo "[dnsmasq] on a Mac client, run:"
echo "  sudo mkdir -p /etc/resolver && printf 'nameserver %s\n' '${NODE_IP}' | sudo tee /etc/resolver/${DOMAIN_SUFFIX}"
