#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <module-source-dir> <module-name>"
  echo "Example: $0 ./driver/my_module my_module"
  exit 1
fi

MODULE_SRC="$(cd "$1" && pwd)"
MODULE_NAME="$2"

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
REMOTE_TMP_KMOD="${REMOTE_TMP_KMOD:-/tmp/kmod-dev}"

echo "==> Uploading module source to Pi"
ssh -p "$PI_PORT" "$PI_USER@$PI_HOST" "mkdir -p '$REMOTE_TMP_KMOD/src'"
rsync -az --delete -e "ssh -p $PI_PORT" "$MODULE_SRC/" "$PI_USER@$PI_HOST:$REMOTE_TMP_KMOD/src/"

echo "==> Building and installing kernel module on Pi"
ssh -p "$PI_PORT" "$PI_USER@$PI_HOST" "
  set -e
  KREL=\$(uname -r)
  test -d /lib/modules/\$KREL/build || { echo 'Kernel headers missing. Install raspberrypi-kernel-headers'; exit 1; }
  make -C /lib/modules/\$KREL/build M='$REMOTE_TMP_KMOD/src' clean
  make -C /lib/modules/\$KREL/build M='$REMOTE_TMP_KMOD/src' modules
  sudo mkdir -p /lib/modules/\$KREL/extra
  sudo install -m 0644 '$REMOTE_TMP_KMOD/src/${MODULE_NAME}.ko' /lib/modules/\$KREL/extra/${MODULE_NAME}.ko
  sudo depmod -a \$KREL
  sudo modprobe -r '${MODULE_NAME}' 2>/dev/null || true
  sudo modprobe '${MODULE_NAME}'
  lsmod | grep -E '^${MODULE_NAME}\\b' || true
"

echo "==> Kernel module deployed and loaded: ${MODULE_NAME}"
