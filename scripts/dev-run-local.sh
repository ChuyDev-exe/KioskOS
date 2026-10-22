#!/usr/bin/env bash
#
# Run the manager service locally (debug mode).
#
#   ./scripts/dev-run-local.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/manager-os"

# rustup does not always add ~/.cargo/bin to the PATH of a login shell.
if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1090,SC1091
  source "$HOME/.cargo/env"
fi

if ! command -v cargo >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: `cargo` not found in PATH.

Install the Rust toolchain (recommended):

  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  source "$HOME/.cargo/env"

Or build and run the service inside Docker (see scripts/dev-build-service.sh).
EOF
  exit 1
fi

export STATIC_PATH="${STATIC_PATH:-$ROOT_DIR/manager-os/static}"
BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"
BIND_PORT="${BIND_PORT:-8080}"

if [ ! -d "$STATIC_PATH" ]; then
  echo "ERROR: static directory not found: $STATIC_PATH" >&2
  exit 1
fi

# Fail early with a clear message instead of an "Address already in use".
if command -v nc >/dev/null 2>&1 && nc -z "$BIND_ADDRESS" "$BIND_PORT" >/dev/null 2>&1; then
  echo "ERROR: $BIND_ADDRESS:$BIND_PORT is already in use." >&2
  echo "       Stop the other instance or set BIND_PORT=<other port>." >&2
  exit 1
fi

# Rebuild the Tailwind bundle when a source changed (no-op otherwise).
if command -v npm >/dev/null 2>&1 && [ -d "$ROOT_DIR/manager-os/node_modules" ]; then
  (cd "$ROOT_DIR/manager-os" && npm run --silent css) ||
    echo "WARN  Tailwind rebuild failed, using the committed bundle" >&2
elif command -v npx >/dev/null 2>&1; then
  (cd "$ROOT_DIR/manager-os/static" && npx --yes tailwindcss@3.4.17 -i input.css -o tailwind-precompiled.css) ||
    echo "WARN  Tailwind rebuild failed, using the committed bundle" >&2
fi

echo "==> Running manager-os locally with STATIC_PATH=$STATIC_PATH"
echo "==> Open http://${BIND_ADDRESS}:${BIND_PORT}/ (Ctrl+C to stop)"
exec cargo run
