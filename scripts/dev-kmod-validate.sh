#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <module-name>"
  exit 1
fi

MODULE_NAME="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${DEV_ENV_FILE:-$ROOT_DIR/scripts/dev.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Create it from scripts/dev.env.example"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${PI_HOST:?PI_HOST is required}"
: "${PI_USER:?PI_USER is required}"
PI_PORT="${PI_PORT:-22}"

ssh -p "$PI_PORT" "$PI_USER@$PI_HOST" "
  set -e
  KREL=\$(uname -r)
  echo 'Kernel release:' \$KREL
  echo '--- modinfo ---'
  modinfo '${MODULE_NAME}' || true
  echo '--- lsmod ---'
  lsmod | grep -E '^${MODULE_NAME}\\b' || echo 'module not currently loaded'
  echo '--- dmesg (last 120 lines) ---'
  dmesg | tail -n 120
"
