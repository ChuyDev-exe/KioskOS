#!/usr/bin/env bash
#
# The check expressions below are evaluated inside the build container, so
# they must stay literal.
# shellcheck disable=SC2016
#
# Verify the contents of the generated image.
#
#   ./scripts/verify-image.sh
#
# It inspects the ext4 filesystem produced by rpi-image-gen with debugfs,
# inside the build container, so no root privileges or loop mounts are
# needed. Run it right after ./build.sh.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FAILURES=0

# One container for every check (starting one per check took most of the
# run time).
CONTAINER="adagi_os-verify-$$"
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker compose run --name "$CONTAINER" -d adagi_os >/dev/null

# The work volume persists between builds and may hold older images: always
# inspect the most recent root filesystem.
ROOTFS=$(docker exec "$CONTAINER" bash -c \
  "ls -t /home/imagegen/work/image-*/root.ext4 2>/dev/null | head -1")
if [ -z "$ROOTFS" ]; then
  echo "ERROR: no root.ext4 found in the build volume. Run ./build.sh first." >&2
  exit 1
fi
echo "==> Inspecting $ROOTFS"

check() {
  local description="$1"
  local expression="$2"
  local expected="$3" # "present" | "absent"

  if docker exec -e ROOTFS="$ROOTFS" "$CONTAINER" bash -c "$expression" >/dev/null 2>&1; then
    found=yes
  else
    found=no
  fi

  case "$expected" in
    present)
      if [ "$found" = "yes" ]; then
        printf 'OK    %s\n' "$description"
      else
        printf 'FAIL  %s (not found)\n' "$description" >&2
        FAILURES=$((FAILURES + 1))
      fi
      ;;
    absent)
      if [ "$found" = "no" ]; then
        printf 'OK    %s\n' "$description"
      else
        printf 'FAIL  %s (unexpectedly present)\n' "$description" >&2
        FAILURES=$((FAILURES + 1))
      fi
      ;;
  esac
}

echo "==> Verifying the image contents"

check "the frontend assets are installed" \
  'debugfs -R "cat /static/index.html" "$ROOTFS" 2>/dev/null | grep -q "<!doctype html>"' present
check "the Tailwind bundle is installed" \
  'debugfs -R "ls /static" "$ROOTFS" 2>/dev/null | grep -q tailwind-precompiled.css' present
check "the service binary is installed" \
  'debugfs -R "stat /usr/local/bin/wifi_setup_service" "$ROOTFS" 2>/dev/null | grep -q "Size:"' present
check "the kiosk service unit is installed" \
  'debugfs -R "ls /etc/systemd/system" "$ROOTFS" 2>/dev/null | grep -q "kiosk.service"' present
check "the wifi setup unit is installed" \
  'debugfs -R "ls /etc/systemd/system" "$ROOTFS" 2>/dev/null | grep -q "wifi_setup.service"' present
check "the frontend is minified" \
  '[ "$(debugfs -R "cat /static/script.js" "$ROOTFS" 2>/dev/null | wc -l)" -le 2 ]' present
check "no frontend build inputs in the image" \
  'debugfs -R "ls /static" "$ROOTFS" 2>/dev/null | grep -qE "input\.css|tailwind\.config\.js"' absent
check "the browser (WPE WebKit / cog) is installed" \
  'debugfs -R "stat /usr/bin/cog" "$ROOTFS" 2>/dev/null | grep -q "Size:"' present
check "the on-screen keyboard is installed" \
  'debugfs -R "stat /usr/bin/wvkbd-mobintl" "$ROOTFS" 2>/dev/null | grep -q "Size:"' present
check "TLS support for WebKit (glib-networking) is installed" \
  'debugfs -R "ls /usr/lib/aarch64-linux-gnu/gio/modules" "$ROOTFS" 2>/dev/null | grep -q libgiognutls' present
check "no Firefox in the image" \
  'debugfs -R "ls /usr/lib/firefox-esr" "$ROOTFS" 2>/dev/null | grep -q application.ini' absent
check "no nodejs in the image" \
  'debugfs -R "ls /usr/bin/node" "$ROOTFS" 2>/dev/null | grep -q node' absent
check "the apt lists were cleaned up" \
  '! debugfs -R "ls /var/lib/apt/lists" "$ROOTFS" 2>/dev/null | grep -q "^[0-9]"' present
check "the kiosk session starts after the manager service" \
  'debugfs -R "cat /etc/systemd/system/kiosk.service" "$ROOTFS" 2>/dev/null | grep -q "^After=.*wifi_setup.service"' present
check "the launcher restarts the browser" \
  'debugfs -R "cat /usr/local/bin/kiosk-launch.sh" "$ROOTFS" 2>/dev/null | grep -q "webprocess-failure=restart"' present
check "the touch bridge (absolute mouse → touchscreen) is installed" \
  'debugfs -R "cat /etc/udev/rules.d/99-kiosk-touch-bridge.rules" "$ROOTFS" 2>/dev/null | grep -q "kiosk-touch-bridge@"' present
check "the input diagnostics tool is installed" \
  'debugfs -R "stat /usr/local/bin/kiosk-input-diag" "$ROOTFS" 2>/dev/null | grep -q "Size:"' present
check "the documentation was removed" \
  '! debugfs -R "ls /usr/share/doc" "$ROOTFS" 2>/dev/null | grep -q "^[0-9]"' present

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d image check(s) failed.\n' "$FAILURES" >&2
  exit 1
fi

printf '\nAll image checks passed.\n'
