#!/usr/bin/env bash
#
# Run the manager service locally (debug mode).
#
#   ./manager-os/run-local.sh
#
set -euo pipefail

# run-local.sh — build and run the manager service locally (debug mode)
# Usage: ./run-local.sh
# Requires: Rust toolchain (cargo) installed; otherwise see suggestions below.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# If rustup was installed, load cargo environment for this shell session
if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1090,SC1091
  source "$HOME/.cargo/env"
fi

if ! command -v cargo >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: `cargo` not found in PATH.
Install Rust toolchain (recommended):

  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  source "$HOME/.cargo/env"

Or run the service inside Docker (see README).
EOF
  exit 1
fi

BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"
BIND_PORT="${BIND_PORT:-8080}"

# Fail early with a clear message instead of an "Address already in use".
if command -v nc >/dev/null 2>&1 && nc -z "$BIND_ADDRESS" "$BIND_PORT" >/dev/null 2>&1; then
  echo "ERROR: $BIND_ADDRESS:$BIND_PORT is already in use." >&2
  echo "       Stop the other instance or set BIND_PORT=<other port>." >&2
  exit 1
fi

echo "Building (debug)..."
cargo build

echo "Rebuilding Tailwind CSS..."
if [ -d "$SCRIPT_DIR/node_modules" ]; then
  (cd "$SCRIPT_DIR" && npm run --silent css) || echo "Warning: Tailwind rebuild failed"
elif command -v npx >/dev/null 2>&1; then
  (cd "$SCRIPT_DIR/static" && npx --yes tailwindcss@3.4.17 -i input.css -o tailwind-precompiled.css) ||
    echo "Warning: Tailwind rebuild failed"
else
  echo "Warning: Tailwind CLI not available, using the committed bundle"
fi

echo "Starting (debug)..."
STATIC_PATH="$SCRIPT_DIR/static" BIND_ADDRESS="$BIND_ADDRESS" BIND_PORT="$BIND_PORT" cargo run
