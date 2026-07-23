#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "Missing .env - nothing to uninstall from (no target host configured)." >&2
  exit 1
fi

# shellcheck disable=SC1091
source .env
SSH_HOST="${SSH_HOST:-ubuntu}"

PURGE_FLAG=""
if [[ "${1:-}" == "--purge-k3s" ]]; then
  PURGE_FLAG="--purge-k3s"
  echo "WARNING: this will completely remove k3s (and all its data) from ${SSH_HOST}."
  read -r -p "Type 'yes' to confirm: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

echo "==> Syncing latest scripts to ${SSH_HOST}:~/self-en (in case they changed)"
rsync -az --delete --exclude '.git' "$ROOT_DIR"/ "${SSH_HOST}:~/self-en/"

echo "==> Running remote uninstall on ${SSH_HOST}"
ssh -t "${SSH_HOST}" "bash ~/self-en/scripts/remote/uninstall-all.sh ${PURGE_FLAG}"
