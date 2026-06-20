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
REMOTE_TMP_APP="${REMOTE_TMP_APP:-/tmp/kiosk-dev}"
WIFI_SERVICE="${WIFI_SERVICE:-wifi_setup.service}"

BIN_LOCAL="$ROOT_DIR/manager-os/target/aarch64-unknown-linux-gnu/release/wifi_setup_service"
STATIC_LOCAL="$ROOT_DIR/manager-os/static"

if [[ ! -f "$BIN_LOCAL" ]]; then
  echo "Binary not found: $BIN_LOCAL"
  echo "Run scripts/dev-build-service.sh first"
  exit 1
fi

if [[ ! -d "$STATIC_LOCAL" ]]; then
  echo "Static dir not found: $STATIC_LOCAL"
  exit 1
fi

echo "==> Preparing remote temp dir"
ssh -p "$PI_PORT" "$PI_USER@$PI_HOST" "mkdir -p '$REMOTE_TMP_APP/static'"

echo "==> Uploading binary"
scp -P "$PI_PORT" "$BIN_LOCAL" "$PI_USER@$PI_HOST:$REMOTE_TMP_APP/wifi_setup_service"

echo "==> Uploading static assets"
rsync -az --delete -e "ssh -p $PI_PORT" "$STATIC_LOCAL/" "$PI_USER@$PI_HOST:$REMOTE_TMP_APP/static/"

echo "==> Installing on Raspberry Pi and restarting $WIFI_SERVICE"
ssh -p "$PI_PORT" "$PI_USER@$PI_HOST" "
  set -e
  sudo install -m 0755 '$REMOTE_TMP_APP/wifi_setup_service' /usr/local/bin/wifi_setup_service
  sudo mkdir -p /static
  sudo rm -rf /static/*
  sudo cp -a '$REMOTE_TMP_APP/static/.' /static/
  sudo systemctl restart '$WIFI_SERVICE'
  sudo systemctl --no-pager --full status '$WIFI_SERVICE' | head -n 25
"

echo "==> Done"
