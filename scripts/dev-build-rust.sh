#!/usr/bin/env bash
#
# Fast native cross-compile of the service for aarch64.
#
# Strategies, in order of speed:
#   1. cargo-zigbuild  - zig provides the cross linker, no container needed
#   2. cargo + aarch64-unknown-linux-gnu target, when a cross linker exists
#   3. Docker (scripts/dev-build-service.sh)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BINARY_NAME="wifi_setup_service"
TARGET="aarch64-unknown-linux-gnu"
OUT_DIR="${ROOT_DIR}/manager-os/target/${TARGET}/release"
OVERLAY_DIR="${ROOT_DIR}/kiosk_os/image/mbr/simple_dual/device/rootfs-overlay/usr/local/bin"

# rustup does not always add ~/.cargo/bin to the PATH of a login shell.
if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1090,SC1091
  source "$HOME/.cargo/env"
fi

install_binary() {
  mkdir -p "$OUT_DIR" "$OVERLAY_DIR"
  cp "${OUT_DIR}/${BINARY_NAME}" "${OVERLAY_DIR}/${BINARY_NAME}"
  chmod +x "${OVERLAY_DIR}/${BINARY_NAME}"
  echo "==> Done: ${OVERLAY_DIR}/${BINARY_NAME}"
}

if command -v cargo-zigbuild >/dev/null 2>&1 && command -v zig >/dev/null 2>&1; then
  echo "==> Cross-compiling ${BINARY_NAME} (${TARGET}) via cargo-zigbuild"
  (cd manager-os && cargo zigbuild --release --target "$TARGET")
  install_binary
  exit 0
fi

if command -v cargo >/dev/null 2>&1 &&
  rustup target list --installed 2>/dev/null | grep -qx "$TARGET" &&
  command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  echo "==> Cross-compiling ${BINARY_NAME} (${TARGET}) via cargo"
  (cd manager-os && cargo build --release --target "$TARGET")
  install_binary
  exit 0
fi

echo "==> No native aarch64 toolchain available, falling back to Docker" >&2
echo "    (install zig + cargo-zigbuild for the fast path: brew install zig && cargo install cargo-zigbuild)" >&2
exec "${ROOT_DIR}/scripts/dev-build-service.sh"
