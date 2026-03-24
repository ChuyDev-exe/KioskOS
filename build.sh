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
  local homepage_url_escaped rotation_escaped wifi_ssid_escaped wifi_psk_escaped
  local ssh_enable_escaped ssh_authorized_key_escaped
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

  wifi_ssid_escaped=$(escape_sed_replacement "$wifi_ssid")
  sed -i.bak -E "s|^([[:space:]]*wifi_ssid:).*|\1 \"${wifi_ssid_escaped}\"|" "$CONFIG_FILE"

  wifi_psk_escaped=$(escape_sed_replacement "$wifi_psk")
  sed -i.bak -E "s|^([[:space:]]*wifi_psk:).*|\1 \"${wifi_psk_escaped}\"|" "$CONFIG_FILE"

  ssh_enable_escaped=$(escape_sed_replacement "$ssh_enable")
  sed -i.bak -E "s|^([[:space:]]*ssh_enable:).*|\1 \"${ssh_enable_escaped}\"|" "$CONFIG_FILE"

  ssh_authorized_key_escaped=$(escape_sed_replacement "$ssh_authorized_key")
  sed -i.bak -E "s|^([[:space:]]*ssh_authorized_key:).*|\1 \"${ssh_authorized_key_escaped}\"|" "$CONFIG_FILE"

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

  BINARY_BUILD_SVC_CONTAINER_ID=$(docker ps -a --filter "name=${BINARY_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1)
  if [ -n "${BINARY_BUILD_SVC_CONTAINER_ID:-}" ]; then
    echo "Killing container ${BINARY_BUILD_SVC_CONTAINER_ID}"
    docker kill "${BINARY_BUILD_SVC_CONTAINER_ID}" >/dev/null 2>&1 || true
    docker rm "${BINARY_BUILD_SVC_CONTAINER_ID}" >/dev/null 2>&1 || true
  fi
  echo "Cleanup complete."
}

# Set the trap to execute the ensure_cleanup function on EXIT
trap ensure_cleanup EXIT

sync_config_from_options

docker compose build ${BINARY_BUILD_SVC}

docker compose run --name ${BINARY_BUILD_SVC}-${BUILD_ID} -d ${BINARY_BUILD_SVC} \
  && docker compose exec ${BINARY_BUILD_SVC} bash -c "cargo build --release --target aarch64-unknown-linux-gnu" \
  && CID=$(docker ps -a --filter "name=${BINARY_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1) \
  && docker cp ${CID}:/app/target/aarch64-unknown-linux-gnu/release/${BINARY_NAME} ./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/usr/local/bin/${BINARY_NAME} \
  && rm -rf ./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/static \
  && docker cp ${CID}:/app/static ./${RPI_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/static

# Build a customer raspberry pi image
# with the wifi setup service included
#
echo "🔨 Building Docker image with rpi-image-gen to create ${RPI_BUILD_SVC}..."
docker compose build ${RPI_BUILD_SVC}

echo "🚀 Running image generation in container..."
docker compose run --name ${RPI_BUILD_SVC}-${BUILD_ID} -d ${RPI_BUILD_SVC} \
  && docker compose exec ${RPI_BUILD_SVC} bash -c \
     "cd /home/${RPI_BUILD_USER} && ./rpi-image-gen/rpi-image-gen build \
      -S /home/${RPI_BUILD_USER}/${RPI_CUSTOMIZATIONS_DIR} \
      -c adagi_os.yaml" \
  && CID=$(docker ps -a --filter "name=${RPI_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1) \
  && IMG_PATH=$(docker exec ${CID} find /home/${RPI_BUILD_USER}/work -name "${RPI_IMAGE_NAME}.img" 2>/dev/null | head -1) \
  && docker cp ${CID}:"${IMG_PATH}" ./deploy/${RPI_IMAGE_NAME}.img

if [[ "${SAVE_SBOM}" == "1" ]]; then
  SBOM_PATH=$(docker exec ${CID} find /home/${RPI_BUILD_USER}/work -name "${RPI_IMAGE_NAME}.sbom" 2>/dev/null | head -1)
  [[ -n "${SBOM_PATH:-}" ]] && docker cp ${CID}:"${SBOM_PATH}" ./deploy/${RPI_IMAGE_NAME}.sbom || true
fi

echo "🚀 Completed -> ${RPI_CUSTOMIZATIONS_DIR}/deploy/${RPI_IMAGE_NAME}.img"