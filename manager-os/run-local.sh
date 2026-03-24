#!/usr/bin/env bash
set -euo pipefail

# run-local.sh — build and run the manager service locally (debug mode)
# Usage: ./run-local.sh
# Requires: Rust toolchain (cargo) installed; otherwise see suggestions below.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# If rustup was installed, load cargo environment for this shell session
if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1090
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

echo "Building (debug)..."
cargo build
echo "Starting (debug)..."
STATIC_PATH="$SCRIPT_DIR/static" cargo run

