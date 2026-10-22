#!/usr/bin/env bash
#
# Build the service and deploy it (binary + static assets) to the device.
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
REMOTE_TMP_APP="${REMOTE_TMP_APP:-/tmp/kiosk-dev}"
WIFI_SERVICE="${WIFI_SERVICE:-wifi_setup.service}"

BIN_LOCAL="$ROOT_DIR/manager-os/target/aarch64-unknown-linux-gnu/release/wifi_setup_service"
STATIC_LOCAL="$ROOT_DIR/manager-os/static"

# Never block on a password prompt or an unreachable host.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

for cmd in ssh scp rsync; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing command: $cmd" >&2
    exit 1
  }
done

if [[ ! -f "$BIN_LOCAL" ]]; then
  echo "Binary not found: $BIN_LOCAL" >&2
  echo "Run scripts/dev-build-service.sh first" >&2
  exit 1
fi

if [[ ! -d "$STATIC_LOCAL" ]]; then
  echo "Static dir not found: $STATIC_LOCAL" >&2
  exit 1
fi

# Deploy the same minified frontend the image ships, when Node.js is there.
if command -v npm >/dev/null 2>&1 && [ -d "$ROOT_DIR/manager-os/node_modules" ]; then
  echo "==> Building the minified frontend"
  if (cd "$ROOT_DIR/manager-os" && npm run --silent build); then
    STATIC_LOCAL="$ROOT_DIR/manager-os/dist/static"
  else
    echo "WARN  Frontend build failed, deploying the unminified sources" >&2
  fi
else
  echo "WARN  npm or manager-os/node_modules missing: deploying the unminified sources" >&2
fi

echo "==> Checking the device connection"
if ! ssh "${SSH_OPTS[@]}" -p "$PI_PORT" "$PI_USER@$PI_HOST" true; then
  echo "Cannot reach $PI_USER@$PI_HOST:$PI_PORT — check scripts/dev.env and the network" >&2
  exit 1
fi

echo "==> Preparing remote temp dir"
ssh "${SSH_OPTS[@]}" -p "$PI_PORT" "$PI_USER@$PI_HOST" "mkdir -p '$REMOTE_TMP_APP/static'"

echo "==> Uploading binary"
scp "${SSH_OPTS[@]}" -P "$PI_PORT" "$BIN_LOCAL" "$PI_USER@$PI_HOST:$REMOTE_TMP_APP/wifi_setup_service"

echo "==> Uploading static assets"
rsync -az --delete -e "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p $PI_PORT" \
  "$STATIC_LOCAL/" "$PI_USER@$PI_HOST:$REMOTE_TMP_APP/static/"

echo "==> Installing on Raspberry Pi and restarting $WIFI_SERVICE"
ssh "${SSH_OPTS[@]}" -p "$PI_PORT" "$PI_USER@$PI_HOST" "
  set -e
  sudo install -m 0755 '$REMOTE_TMP_APP/wifi_setup_service' /usr/local/bin/wifi_setup_service
  sudo mkdir -p /static
  sudo rm -rf /static/*
  sudo cp -a '$REMOTE_TMP_APP/static/.' /static/
  sudo systemctl restart '$WIFI_SERVICE'
  sudo systemctl --no-pager --full status '$WIFI_SERVICE' | head -n 25
"

echo "==> Done"
