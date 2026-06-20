#!/bin/bash

set -eu

BUILD_ID=${RANDOM}
BINARY_BUILD_SVC="manager-os"
BINARY_NAME="wifi_setup_service"
RPI_BUILD_SVC="adagi_os"
RPI_BUILD_USER="imagegen"
RPI_CUSTOMIZATIONS_DIR="kiosk_os"
RPI_IMAGE_NAME="adagi_os"
SAVE_SBOM=1
OPTIONS_FILE="./${RPI_CUSTOMIZATIONS_DIR}/adagi_os.options"
CONFIG_FILE="./${RPI_CUSTOMIZATIONS_DIR}/config/adagi_os.yaml"

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[&|]/\\&/g'
}

set_or_delete_quoted_yaml_key() {
  local key="$1"
  local value="$2"
  local escaped

  if [ -n "$value" ]; then
    escaped=$(escape_sed_replacement "$value")
    if grep -q -E "^[[:space:]]*${key}:" "$CONFIG_FILE"; then
      sed -i.bak -E "s|^([[:space:]]*${key}:).*|\\1 \"${escaped}\"|" "$CONFIG_FILE"
    else
      sed -i.bak -E "/^[[:space:]]*rotation:/a\\
  ${key}: \"${escaped}\"" "$CONFIG_FILE"
    fi
  else
    sed -i.bak -E "/^[[:space:]]*${key}:/d" "$CONFIG_FILE"
  fi
}

validate_option_values() {
  local rotation="$1"
  local ssh_enable="$2"

  case "$rotation" in
    0|normal|90|180|270) ;;
    *)
      echo "Invalid kiosk_rotation: '$rotation'. Allowed values: 0, normal, 90, 180, 270" >&2
      exit 1
      ;;
  esac

  case "$ssh_enable" in
    0|1|true|false) ;;
    *)
      echo "Invalid kiosk_ssh_enable: '$ssh_enable'. Allowed values: 0, 1, true, false" >&2
      exit 1
      ;;
  esac
}

sync_config_from_options() {
  if [ ! -f "$OPTIONS_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    return
  fi

  local homepage_url rotation wifi_ssid wifi_psk ssh_enable ssh_authorized_key
  local homepage_url_escaped rotation_escaped ssh_enable_escaped
  homepage_url=$(awk -F= '/^kiosk_homepage_url=/{print substr($0, index($0, "=") + 1)}' "$OPTIONS_FILE" | tail -n 1)
  rotation=$(awk -F= '/^kiosk_rotation=/{print substr($0, index($0, "=") + 1)}' "$OPTIONS_FILE" | tail -n 1)
  wifi_ssid=$(awk -F= '/^kiosk_wifi_ssid=/{print substr($0, index($0, "=") + 1)}' "$OPTIONS_FILE" | tail -n 1)
  wifi_psk=$(awk -F= '/^kiosk_wifi_psk=/{print substr($0, index($0, "=") + 1)}' "$OPTIONS_FILE" | tail -n 1)
  ssh_enable=$(awk -F= '/^kiosk_ssh_enable=/{print substr($0, index($0, "=") + 1)}' "$OPTIONS_FILE" | tail -n 1)
  ssh_authorized_key=$(awk -F= '/^kiosk_ssh_authorized_key=/{print substr($0, index($0, "=") + 1)}' "$OPTIONS_FILE" | tail -n 1)

  validate_option_values "$rotation" "$ssh_enable"

  homepage_url_escaped=$(escape_sed_replacement "$homepage_url")
  sed -i.bak -E "s|^([[:space:]]*homepage_url:).*|\1 ${homepage_url_escaped}|" "$CONFIG_FILE"

  rotation_escaped=$(escape_sed_replacement "$rotation")
  sed -i.bak -E "s|^([[:space:]]*rotation:).*|\1 \"${rotation_escaped}\"|" "$CONFIG_FILE"

  set_or_delete_quoted_yaml_key "wifi_ssid" "$wifi_ssid"
  set_or_delete_quoted_yaml_key "wifi_psk" "$wifi_psk"

  ssh_enable_escaped=$(escape_sed_replacement "$ssh_enable")
  sed -i.bak -E "s|^([[:space:]]*ssh_enable:).*|\1 \"${ssh_enable_escaped}\"|" "$CONFIG_FILE"

  set_or_delete_quoted_yaml_key "ssh_authorized_key" "$ssh_authorized_key"

  rm -f "$CONFIG_FILE.bak"
}

ensure_cleanup() {
  echo "Cleanup containers..."
  RPI_BUILD_SVC_CONTAINER_ID=$(docker ps -a --filter "name=${RPI_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1)
  if [ -n "${RPI_BUILD_SVC_CONTAINER_ID:-}" ]; then
    echo "Killing container ${RPI_BUILD_SVC_CONTAINER_ID}"
    docker kill "${RPI_BUILD_SVC_CONTAINER_ID}" >/dev/null 2>&1 || true
    docker rm "${RPI_BUILD_SVC_CONTAINER_ID}" >/dev/null 2>&1 || true
  fi
  echo "Cleanup complete."
}

# Set the trap to execute the ensure_cleanup function on EXIT
trap ensure_cleanup EXIT

sync_config_from_options

# Precompile Tailwind CSS (skip if npx unavailable)
if command -v npx &>/dev/null; then
  if [ -f ./manager-os/static/tailwind.config.js ]; then
    echo "🎨 Precompiling Tailwind CSS..."
    (cd manager-os/static && npx --yes tailwindcss -i input.css -o tailwind-precompiled.css 2>/dev/null) || true
  fi
fi

# Build binario Rust y base rpi-image-gen en paralelo
BIN_BUILD_NEEDED=0
if [ ! -f ./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/usr/local/bin/${BINARY_NAME} ] || \
     [ $(find ./manager-os/src -type f -newer ./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/usr/local/bin/${BINARY_NAME} | wc -l) -gt 0 ]; then
  BIN_BUILD_NEEDED=1
fi

STATIC_BUILD_NEEDED=0
STATIC_DEST="./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/static"
if [ ! -d "$STATIC_DEST" ] || \
     [ $(find ./manager-os/static -type f \( -name "*.html" -o -name "*.css" -o -name "*.js" \) \
        -newer "$STATIC_DEST" 2>/dev/null | wc -l) -gt 0 ]; then
  STATIC_BUILD_NEEDED=1
fi

echo "🔨 Compilando binario Rust y base rpi-image-gen en paralelo..."

# ── Rust binary build ───────────────────────────────────────────────────────
if [ "$BIN_BUILD_NEEDED" = "1" ]; then
  USE_ZIGBUILD=0
  if command -v cargo-zigbuild &>/dev/null; then
    if cargo zigbuild --version &>/dev/null; then
      USE_ZIGBUILD=1
    fi
  fi

  if [ "$USE_ZIGBUILD" = "1" ]; then
    echo "   → cargo-zigbuild detected — native cross-compile (fast path)"
    (
      cd manager-os
      cargo zigbuild --release --target aarch64-unknown-linux-gnu
      cd "$OLDPWD"
      cp "./manager-os/target/aarch64-unknown-linux-gnu/release/${BINARY_NAME}" \
         "./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/usr/local/bin/${BINARY_NAME}"
    ) &
  else
    (
      docker compose build ${BINARY_BUILD_SVC}
      CID=$(docker create ${BINARY_BUILD_SVC}:latest)
      docker cp ${CID}:/wifi_setup_service \
          "./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/usr/local/bin/${BINARY_NAME}"
      docker rm ${CID} >/dev/null 2>&1 || true
    ) &
  fi
else
  echo "✅ Binario Rust ya está actualizado. Skipping build."
fi

# ── Static files ────────────────────────────────────────────────────────────
if [ "$STATIC_BUILD_NEEDED" = "1" ]; then
  (
    rm -rf "./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/static"
    mkdir -p "./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/static"
    cp -a manager-os/static/. "./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/static/"
  ) &
fi
(
  docker compose build ${RPI_BUILD_SVC}
) &
wait
echo "✅ Builds paralelos terminados."

echo "🚀 Running image generation in container..."
docker compose run --name ${RPI_BUILD_SVC}-${BUILD_ID} -d ${RPI_BUILD_SVC} \
  && docker compose exec ${RPI_BUILD_SVC} bash -c \
     "cd /home/${RPI_BUILD_USER} && ./rpi-image-gen/rpi-image-gen build \
      -S /home/${RPI_BUILD_USER}/${RPI_CUSTOMIZATIONS_DIR} \
      -c adagi_os.yaml" \
  && CID=$(docker ps -a --filter "name=${RPI_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1) \
  && IMG_PATH=$(docker exec ${CID} find /home/${RPI_BUILD_USER}/work -name "${RPI_IMAGE_NAME}.img" 2>/dev/null | head -1) \
  && docker cp ${CID}:"${IMG_PATH}" ./deploy/${RPI_IMAGE_NAME}.img

if [[ "${SAVE_SBOM}" == "1" ]] && [[ -n "${CID:-}" ]]; then
  SBOM_PATH=$(docker exec ${CID} find /home/${RPI_BUILD_USER}/work -name "${RPI_IMAGE_NAME}.sbom" 2>/dev/null | head -1)
  [[ -n "${SBOM_PATH:-}" ]] && docker cp ${CID}:"${SBOM_PATH}" ./deploy/${RPI_IMAGE_NAME}.sbom || true
fi

echo "🚀 Completed -> ${RPI_CUSTOMIZATIONS_DIR}/deploy/${RPI_IMAGE_NAME}.img"