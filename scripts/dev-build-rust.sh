#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BINARY_NAME="wifi_setup_service"
TARGET="aarch64-unknown-linux-gnu"
OUT_DIR="${ROOT_DIR}/manager-os/target/${TARGET}/release"
DEST_DIR="${ROOT_DIR}/kiosk_os/image/mbr/simple_dual/device/rootfs-overlay"

if ! command -v cargo-zigbuild &>/dev/null; then
  echo "==> cargo-zigbuild not found. Install with: cargo install cargo-zigbuild"
  echo "    (requires zig: brew install zig)"
  exit 1
fi

echo "==> Cross-compiling ${BINARY_NAME} (${TARGET}) via cargo-zigbuild"
cd manager-os
cargo zigbuild --release --target "$TARGET"
cd "$ROOT_DIR"

echo "==> Installing binary to rootfs-overlay"
cp "${OUT_DIR}/${BINARY_NAME}" "${DEST_DIR}/usr/local/bin/${BINARY_NAME}"

echo "==> Syncing static files to rootfs-overlay"
rm -rf "${DEST_DIR}/static"
mkdir -p "${DEST_DIR}/static"
cp -a manager-os/static/. "${DEST_DIR}/static/"

echo "==> Done: ${DEST_DIR}/usr/local/bin/${BINARY_NAME}"
