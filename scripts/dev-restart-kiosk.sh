#!/usr/bin/env bash
set -euo pipefail

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
KIOSK_SERVICE="${KIOSK_SERVICE:-kiosk.service}"

ssh -p "$PI_PORT" "$PI_USER@$PI_HOST" "
  set -e
  sudo systemctl restart '$KIOSK_SERVICE'
  sudo systemctl --no-pager --full status '$KIOSK_SERVICE' | head -n 25
"
