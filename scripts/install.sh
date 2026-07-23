#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "Missing .env - copy .env.example to .env and fill in the values first." >&2
  exit 1
fi

# shellcheck disable=SC1091
source .env
SSH_HOST="${SSH_HOST:-ubuntu}"

echo "==> Syncing project to ${SSH_HOST}:~/self-en"
rsync -az --delete --exclude '.git' "$ROOT_DIR"/ "${SSH_HOST}:~/self-en/"

echo "==> Running remote install on ${SSH_HOST}"
ssh -t "${SSH_HOST}" "bash ~/self-en/scripts/remote/run-all.sh"

echo "==> Done. See README.md for verification steps."
