#!/usr/bin/env bash
#
# Tail the service logs of the device.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${DEV_ENV_FILE:-$ROOT_DIR/scripts/dev.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Create it from scripts/dev.env.example" >&2
  exit 1
fi

# shellcheck disable=SC1090,SC1091
source "$ENV_FILE"

: "${PI_HOST:?PI_HOST is required}"
: "${PI_USER:?PI_USER is required}"
PI_PORT="${PI_PORT:-22}"
WIFI_SERVICE="${WIFI_SERVICE:-wifi_setup.service}"
KIOSK_SERVICE="${KIOSK_SERVICE:-kiosk.service}"

command -v ssh >/dev/null 2>&1 || {
  echo "Missing command: ssh" >&2
  exit 1
}

echo "==> Streaming logs from $PI_USER@$PI_HOST:$PI_PORT (Ctrl+C to stop)"
exec ssh -t \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=accept-new \
  -p "$PI_PORT" "$PI_USER@$PI_HOST" \
  "sudo journalctl -f -u '$WIFI_SERVICE' -u '$KIOSK_SERVICE' -u wpa_supplicant@wlan0.service"
