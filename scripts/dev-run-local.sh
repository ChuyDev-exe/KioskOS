#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/manager-os"

export STATIC_PATH="${STATIC_PATH:-$ROOT_DIR/manager-os/static}"

echo "==> Running manager-os locally with STATIC_PATH=$STATIC_PATH"
exec cargo run
