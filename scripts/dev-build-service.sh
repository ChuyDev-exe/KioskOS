#!/usr/bin/env bash
#
# Build the aarch64 service binary with Docker.
#
# This is the portable path: it works on any host with Docker and does not
# need a Rust toolchain. The manager-os image is a multi-stage build whose
# final stage only carries the stripped binary, so it is extracted with
# `docker create` + `docker cp`.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BINARY_NAME="wifi_setup_service"
BUILD_SVC="manager-os"
TARGET="aarch64-unknown-linux-gnu"
OUT_DIR="${ROOT_DIR}/manager-os/target/${TARGET}/release"
OVERLAY_DIR="${ROOT_DIR}/kiosk_os/image/mbr/simple_dual/device/rootfs-overlay/usr/local/bin"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is required to build the aarch64 binary" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose is required (v2)" >&2
  exit 1
fi

echo "==> Building the ${BUILD_SVC} image (aarch64 cross build)"
docker compose build "${BUILD_SVC}"

echo "==> Extracting ${BINARY_NAME} from the image"
CID=""
cleanup() {
  if [ -n "$CID" ]; then
    docker rm -f "$CID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

CID=$(docker create "${BUILD_SVC}:latest")
mkdir -p "$OUT_DIR"
docker cp "${CID}:/wifi_setup_service" "${OUT_DIR}/${BINARY_NAME}"
chmod +x "${OUT_DIR}/${BINARY_NAME}"

echo "==> Installing the binary into the image overlay"
mkdir -p "$OVERLAY_DIR"
cp "${OUT_DIR}/${BINARY_NAME}" "${OVERLAY_DIR}/${BINARY_NAME}"
chmod +x "${OVERLAY_DIR}/${BINARY_NAME}"

echo "==> Done: ${OUT_DIR}/${BINARY_NAME}"
