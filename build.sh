#!/bin/bash
#
# Build the KioskOS image.
#
#   ./build.sh
#
# Environment:
#   KIOSK_REUSE_DOCKER_IMAGES=1  reuse existing adagi_os/manager-os Docker
#                                images instead of rebuilding them when the
#                                Dockerfile looks newer (CI sets it: a git
#                                checkout makes every Dockerfile "newer").

set -eu

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

BUILD_ID=${RANDOM}
BINARY_BUILD_SVC="manager-os"
BINARY_NAME="wifi_setup_service"
RPI_BUILD_SVC="adagi_os"
RPI_BUILD_USER="imagegen"
RPI_CUSTOMIZATIONS_DIR="kiosk_os"
RPI_IMAGE_NAME="adagi_os"
RPI_CONTAINER="${RPI_BUILD_SVC}-${BUILD_ID}"
SAVE_SBOM=1
OPTIONS_FILE="./${RPI_CUSTOMIZATIONS_DIR}/adagi_os.options"
LOCAL_OPTIONS_FILE="./${RPI_CUSTOMIZATIONS_DIR}/adagi_os.local.options"
BASE_CONFIG_FILE="./${RPI_CUSTOMIZATIONS_DIR}/config/adagi_os.yaml"
# Generated from the base config + options (ignored by git: it may contain
# the Wi-Fi password). This is the file rpi-image-gen builds.
CONFIG_NAME="adagi_os.generated.yaml"
CONFIG_FILE="./${RPI_CUSTOMIZATIONS_DIR}/config/${CONFIG_NAME}"
OVERLAY_DIR="./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay"
BINARY_DEST="${OVERLAY_DIR}/usr/local/bin/${BINARY_NAME}"
STATIC_DEST="${OVERLAY_DIR}/static"
STATIC_DIR="./manager-os/static"
# Minified production frontend (manager-os/scripts/build-frontend.mjs).
FRONTEND_DIST="./manager-os/dist/static"
# Which variant the overlay currently holds ("minified" or "source").
STATIC_MODE_FILE="./manager-os/dist/.overlay-static-mode"
TAILWIND_OUT="${STATIC_DIR}/tailwind-precompiled.css"
TAILWIND_SOURCES=(
  "${STATIC_DIR}/index.html"
  "${STATIC_DIR}/script.js"
  "${STATIC_DIR}/style.css"
  "${STATIC_DIR}/input.css"
  "${STATIC_DIR}/tailwind.config.js"
)

# ── Tailwind ────────────────────────────────────────────────────────────────

# Rebuild the Tailwind bundle only when one of its sources changed.
# Keeps `npx tailwindcss` (a ~30 MB download) out of the normal build path.
tailwind_needs_build() {
  [ -f "$TAILWIND_OUT" ] || return 0
  local src
  for src in "${TAILWIND_SOURCES[@]}"; do
    [ -f "$src" ] || continue
    [ "$src" -nt "$TAILWIND_OUT" ] && return 0
  done
  return 1
}

build_tailwind() {
  local -a runner=()
  if [ -x "${ROOT_DIR}/manager-os/node_modules/.bin/tailwindcss" ]; then
    runner=("${ROOT_DIR}/manager-os/node_modules/.bin/tailwindcss")
  elif command -v npx >/dev/null 2>&1; then
    runner=(npx --yes tailwindcss@3.4.17)
  else
    echo "WARN  Tailwind CLI not available, keeping the committed CSS bundle" >&2
    return 0
  fi

  echo "==> Precompiling Tailwind CSS"
  if ! (cd "$STATIC_DIR" && "${runner[@]}" -i input.css -o tailwind-precompiled.css); then
    echo "WARN  Tailwind build failed, keeping the committed CSS bundle" >&2
  fi
}

# ── Options → generated config ──────────────────────────────────────────────

# Last value of KEY across the tracked options file and the private local one
# (the local file wins). Prints nothing when the key is not set anywhere.
read_option() {
  local key="$1" value="" file
  for file in "$OPTIONS_FILE" "$LOCAL_OPTIONS_FILE"; do
    [ -f "$file" ] || continue
    if grep -q "^${key}=" "$file"; then
      value=$(awk -v k="$key" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$file")
    fi
  done
  printf '%s' "$value"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

# Escapes a value for a YAML double-quoted scalar.
yaml_double_quoted() {
  local v="$1"
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  printf '"%s"' "$v"
}

# Sets KEY to a quoted VALUE in the kiosk section, adding it when missing;
# an empty VALUE removes the key.
set_kiosk_key() {
  local key="$1" value="$2" replacement
  if [ -z "$value" ]; then
    sed -i.bak -E "/^[[:space:]]+${key}:/d" "$CONFIG_FILE"
    return
  fi
  replacement=$(escape_sed_replacement "$(yaml_double_quoted "$value")")
  if grep -q -E "^[[:space:]]+${key}:" "$CONFIG_FILE"; then
    sed -i.bak -E "s|^([[:space:]]+${key}:).*|\\1 ${replacement}|" "$CONFIG_FILE"
  else
    sed -i.bak -E "/^kiosk:/a\\
  ${key}: ${replacement}" "$CONFIG_FILE"
  fi
}

fail_option() {
  echo "Invalid option: $1" >&2
  exit 1
}

validate_options() {
  local homepage_url="$1" rotation="$2" ssh_enable="$3" country="$4" ssid="$5" psk="$6"
  local touch_bridge="$7" usbhid_quirks="$8"

  case "$touch_bridge" in
    auto | force | off) ;;
    *) fail_option "kiosk_touch_bridge '$touch_bridge'. Allowed values: auto, force, off" ;;
  esac

  # usbhid.quirks: comma separated 0xVENDOR:0xPRODUCT:0xQUIRKS entries.
  if [ -n "$usbhid_quirks" ] &&
    ! [[ "$usbhid_quirks" =~ ^0x[0-9A-Fa-f]{4}:0x[0-9A-Fa-f]{4}:0x[0-9A-Fa-f]{1,8}(,0x[0-9A-Fa-f]{4}:0x[0-9A-Fa-f]{4}:0x[0-9A-Fa-f]{1,8})*$ ]]; then
    fail_option "kiosk_usbhid_quirks '$usbhid_quirks' must look like 0x1234:0x5678:0x40 (comma separated)"
  fi

  case "$homepage_url" in
    http://* | https://*) ;;
    *) fail_option "kiosk_homepage_url must start with http:// or https:// (got '$homepage_url')" ;;
  esac

  case "$rotation" in
    0 | normal | 90 | 180 | 270) ;;
    *) fail_option "kiosk_rotation '$rotation'. Allowed values: 0, normal, 90, 180, 270" ;;
  esac

  case "$ssh_enable" in
    0 | 1 | true | false) ;;
    *) fail_option "kiosk_ssh_enable '$ssh_enable'. Allowed values: 0, 1, true, false" ;;
  esac

  [[ "$country" =~ ^[A-Z]{2}$ ]] ||
    fail_option "kiosk_wifi_country '$country' must be a two-letter code (e.g. MX, US)"

  local ssid_bytes
  ssid_bytes=$(printf '%s' "$ssid" | wc -c | tr -d ' ')
  [ "$ssid_bytes" -le 32 ] || fail_option "kiosk_wifi_ssid is longer than 32 bytes"

  if [ -n "$psk" ]; then
    [ -n "$ssid" ] || fail_option "kiosk_wifi_psk is set but kiosk_wifi_ssid is empty"
    if ! LC_ALL=C bash -c '[[ "$1" =~ ^[0-9A-Fa-f]{64}$ || "$1" =~ ^[[:print:]]{8,63}$ ]]' _ "$psk"; then
      fail_option "kiosk_wifi_psk must be 8-63 printable ASCII characters or 64 hex digits"
    fi
  fi
}

generate_config() {
  if [ ! -f "$BASE_CONFIG_FILE" ]; then
    echo "Missing $BASE_CONFIG_FILE" >&2
    exit 1
  fi
  cp "$BASE_CONFIG_FILE" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"

  local homepage_url rotation wifi_country wifi_ssid wifi_psk ssh_enable ssh_authorized_key passhash
  local touch_bridge usbhid_quirks
  homepage_url=$(read_option kiosk_homepage_url)
  rotation=$(read_option kiosk_rotation)
  wifi_country=$(read_option kiosk_wifi_country | tr '[:lower:]' '[:upper:]')
  wifi_ssid=$(read_option kiosk_wifi_ssid)
  wifi_psk=$(read_option kiosk_wifi_psk)
  ssh_enable=$(read_option kiosk_ssh_enable)
  ssh_authorized_key=$(read_option kiosk_ssh_authorized_key)
  passhash=$(read_option device_user1passhash)
  touch_bridge=$(read_option kiosk_touch_bridge)
  usbhid_quirks=$(read_option kiosk_usbhid_quirks)

  validate_options "${homepage_url:-https://}" "${rotation:-normal}" "${ssh_enable:-1}" \
    "${wifi_country:-US}" "$wifi_ssid" "$wifi_psk" "${touch_bridge:-auto}" "$usbhid_quirks"

  [ -n "$homepage_url" ] && set_kiosk_key homepage_url "$homepage_url"
  [ -n "$rotation" ] && set_kiosk_key rotation "$rotation"
  [ -n "$wifi_country" ] && set_kiosk_key wifi_country "$wifi_country"
  [ -n "$ssh_enable" ] && set_kiosk_key ssh_enable "$ssh_enable"
  set_kiosk_key wifi_ssid "$wifi_ssid"
  set_kiosk_key wifi_psk "$wifi_psk"
  set_kiosk_key ssh_authorized_key "$ssh_authorized_key"
  [ -n "$touch_bridge" ] && set_kiosk_key touch_bridge "$touch_bridge"
  set_kiosk_key usbhid_quirks "$usbhid_quirks"

  if [ -n "$passhash" ]; then
    local replacement
    replacement=$(escape_sed_replacement "$(yaml_double_quoted "$passhash")")
    sed -i.bak -E "s|^([[:space:]]+user1passhash:).*|\\1 ${replacement}|" "$CONFIG_FILE"
  fi

  rm -f "$CONFIG_FILE.bak"
  echo "==> Generated ${CONFIG_FILE}"
}

# ── Docker image helpers ────────────────────────────────────────────────────

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

docker_image_created_epoch() {
  local ts
  ts=$(docker image inspect "$1" --format '{{.Created}}' 2>/dev/null) || return 1
  date -u -d "$ts" +%s 2>/dev/null ||
    date -u -j -f "%Y-%m-%dT%H:%M:%S.%fZ" "$ts" +%s 2>/dev/null ||
    date -u -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null
}

# Rebuild a docker image only when it is missing or older than its Dockerfile.
docker_image_needs_build() {
  local image="$1"
  local dockerfile="$2"

  docker image inspect "$image" >/dev/null 2>&1 || return 0
  [ "${KIOSK_REUSE_DOCKER_IMAGES:-0}" = "1" ] && return 1

  local created_epoch dockerfile_epoch
  created_epoch=$(docker_image_created_epoch "$image")
  dockerfile_epoch=$(file_mtime "$dockerfile")

  if [ -z "$created_epoch" ] || [ "$dockerfile_epoch" -eq 0 ]; then
    return 0
  fi

  [ "$dockerfile_epoch" -gt "$created_epoch" ]
}

# ── Parallel jobs ───────────────────────────────────────────────────────────

# A bare `wait` always returns 0, so a failed background build used to go
# unnoticed and the image was assembled with a stale binary. Track the PIDs
# and fail the build when any job fails.
JOB_PIDS=()
JOB_NAMES=()

start_job() {
  local name="$1"
  shift
  "$@" &
  JOB_PIDS+=("$!")
  JOB_NAMES+=("$name")
}

wait_jobs() {
  local failed=0 i
  for i in "${!JOB_PIDS[@]}"; do
    if ! wait "${JOB_PIDS[$i]}"; then
      echo "ERROR: ${JOB_NAMES[$i]} failed" >&2
      failed=1
    fi
  done
  JOB_PIDS=()
  JOB_NAMES=()
  [ "$failed" -eq 0 ]
}

binary_needs_build() {
  [ -f "$BINARY_DEST" ] || return 0
  [ -n "$(find ./manager-os/src ./manager-os/Cargo.toml ./manager-os/Cargo.lock \
    -type f -newer "$BINARY_DEST" 2>/dev/null)" ]
}

# Node.js tooling for the minified frontend. Installs it (npm ci, pinned by
# package-lock.json) when node/npm exist but node_modules is missing, e.g. on
# a fresh clone or a CI runner.
ensure_frontend_tooling() {
  command -v node >/dev/null 2>&1 || return 1
  if [ ! -x ./manager-os/node_modules/.bin/esbuild ] ||
    [ ! -d ./manager-os/node_modules/html-minifier-terser ]; then
    command -v npm >/dev/null 2>&1 || return 1
    echo "==> Installing the frontend tooling (npm ci)"
    (cd manager-os && npm ci --no-audit --no-fund) || return 1
  fi
}

static_needs_build() {
  local mode="$1"
  [ -d "$STATIC_DEST" ] || return 0
  [ "$(cat "$STATIC_MODE_FILE" 2>/dev/null)" = "$mode" ] || return 0
  [ -n "$(find "$STATIC_DIR" ./manager-os/scripts/build-frontend.mjs ./manager-os/package-lock.json \
    -type f -newer "$STATIC_DEST" 2>/dev/null)" ]
}

build_binary_zig() {
  (cd manager-os && cargo zigbuild --release --target aarch64-unknown-linux-gnu)
  install -m 755 "./manager-os/target/aarch64-unknown-linux-gnu/release/${BINARY_NAME}" "$BINARY_DEST"
}

build_binary_docker() {
  if docker_image_needs_build "${BINARY_BUILD_SVC}:latest" "./manager-os/Dockerfile.manager"; then
    docker compose build "${BINARY_BUILD_SVC}"
  else
    echo "✅ ${BINARY_BUILD_SVC}:latest está actualizado. Skipping build."
  fi
  local cid
  cid=$(docker create "${BINARY_BUILD_SVC}:latest")
  if ! docker cp "${cid}:/wifi_setup_service" "$BINARY_DEST"; then
    docker rm "$cid" >/dev/null 2>&1 || true
    return 1
  fi
  docker rm "$cid" >/dev/null 2>&1 || true
  chmod 755 "$BINARY_DEST"
}

# Installs the frontend into the image overlay: the minified build when the
# Node.js tooling is available, the readable sources otherwise.
build_static() {
  local mode="$1" src="$STATIC_DIR"
  if [ "$mode" = "minified" ]; then
    echo "==> Minifying the frontend (esbuild + html-minifier-terser)"
    (cd manager-os && node scripts/build-frontend.mjs)
    src="$FRONTEND_DIST"
  fi
  rm -rf "$STATIC_DEST"
  mkdir -p "$STATIC_DEST" "$(dirname "$STATIC_MODE_FILE")"
  cp -a "${src}/." "$STATIC_DEST/"
  # Build inputs are never shipped to the device.
  rm -f "$STATIC_DEST/input.css" "$STATIC_DEST/tailwind.config.js"
  echo "$mode" >"$STATIC_MODE_FILE"
}

build_imagegen_docker() {
  if docker_image_needs_build "${RPI_BUILD_SVC}:latest" "./Dockerfile"; then
    docker compose build "${RPI_BUILD_SVC}"
  else
    echo "✅ ${RPI_BUILD_SVC}:latest está actualizado. Skipping build."
  fi
}

# ── Cleanup ─────────────────────────────────────────────────────────────────

ensure_cleanup() {
  echo "Cleanup containers..."
  if docker container inspect "$RPI_CONTAINER" >/dev/null 2>&1; then
    echo "Removing container ${RPI_CONTAINER}"
    docker rm -f "$RPI_CONTAINER" >/dev/null 2>&1 || true
  fi
  echo "Cleanup complete."
}

trap ensure_cleanup EXIT

# ── Build ───────────────────────────────────────────────────────────────────

generate_config

STATIC_MODE="source"
if ensure_frontend_tooling; then
  STATIC_MODE="minified"
else
  echo "WARN  Node.js/npm not available: the image will ship the unminified frontend" >&2
fi

if tailwind_needs_build; then
  build_tailwind
else
  echo "==> Tailwind CSS bundle is up to date, skipping"
fi

mkdir -p "$(dirname "$BINARY_DEST")" ./deploy

echo "🔨 Compilando binario Rust y base rpi-image-gen en paralelo..."

if binary_needs_build; then
  if command -v cargo-zigbuild >/dev/null 2>&1 && cargo zigbuild --version >/dev/null 2>&1; then
    echo "   → cargo-zigbuild detected — native cross-compile (fast path)"
    start_job "Rust binary (cargo-zigbuild)" build_binary_zig
  else
    start_job "Rust binary (Docker)" build_binary_docker
  fi
else
  echo "✅ Binario Rust ya está actualizado. Skipping build."
fi

if static_needs_build "$STATIC_MODE"; then
  start_job "frontend (${STATIC_MODE})" build_static "$STATIC_MODE"
else
  echo "✅ Frontend (${STATIC_MODE}) ya está actualizado. Skipping build."
fi
start_job "rpi-image-gen Docker image" build_imagegen_docker

wait_jobs || exit 1
echo "✅ Builds paralelos terminados."

echo "🚀 Running image generation in container..."
# NOTE: the cached filesystem inside the work volume is owned by root (apt
# runs as root in the chroot), so discarding it needs sudo. The password is
# the container build user's one, set in the root Dockerfile.
docker compose run --name "$RPI_CONTAINER" -d "$RPI_BUILD_SVC" >/dev/null
docker exec "$RPI_CONTAINER" bash -c \
  "set -e
   WORK=/home/${RPI_BUILD_USER}/work
   mkdir -p \"\$WORK/cache/apt\"
   cd /home/${RPI_BUILD_USER}
   CONFIG_HASH=\$( { cat kiosk_os/layer/*.yaml kiosk_os/meta/*.yaml kiosk_os/profile/* 2>/dev/null; \
     awk '/^kiosk:/{exit}{print}' kiosk_os/config/${CONFIG_NAME}; } | sha256sum | cut -d' ' -f1 )
   STAMP=\"\$WORK/.layer-config-hash\"
   if [ -f \"\$STAMP\" ] && [ \"\$(cat \"\$STAMP\")\" != \"\$CONFIG_HASH\" ]; then
     echo 'Layer configuration changed, discarding the cached filesystem'
     echo imagegen | sudo -S rm -rf \"\$WORK\"/chroot-*
   elif [ ! -f \"\$STAMP\" ] && ls \"\$WORK\"/chroot-* >/dev/null 2>&1; then
     echo 'No configuration fingerprint found, discarding the cached filesystem'
     echo imagegen | sudo -S rm -rf \"\$WORK\"/chroot-*
   fi
   echo \"\$CONFIG_HASH\" > \"\$STAMP\"
   touch /tmp/build-start
   ./rpi-image-gen/rpi-image-gen build \
     -S /home/${RPI_BUILD_USER}/${RPI_CUSTOMIZATIONS_DIR} \
     -c ${CONFIG_NAME}"

# The work volume persists between builds: only accept files written by this
# build, never a stale image from an earlier run.
newest_artifact() {
  docker exec "$RPI_CONTAINER" bash -c \
    "find /home/${RPI_BUILD_USER}/work -name '$1' -type f -newer /tmp/build-start -printf '%T@ %p\n' 2>/dev/null |
       sort -nr | head -1 | cut -d' ' -f2-"
}

IMG_PATH=$(newest_artifact "${RPI_IMAGE_NAME}.img")
if [ -z "$IMG_PATH" ]; then
  echo "ERROR: the build did not produce ${RPI_IMAGE_NAME}.img" >&2
  exit 1
fi
docker cp "${RPI_CONTAINER}:${IMG_PATH}" "./deploy/${RPI_IMAGE_NAME}.img"

if [ "${SAVE_SBOM}" = "1" ]; then
  SBOM_PATH=$(newest_artifact "${RPI_IMAGE_NAME}.sbom")
  if [ -n "$SBOM_PATH" ]; then
    docker cp "${RPI_CONTAINER}:${SBOM_PATH}" "./deploy/${RPI_IMAGE_NAME}.sbom"
  fi
fi

echo "🚀 Completed -> ./deploy/${RPI_IMAGE_NAME}.img"
