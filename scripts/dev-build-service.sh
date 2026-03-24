#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Building manager-os image"
docker compose build manager-os

echo "==> Cross-compiling wifi_setup_service (aarch64)"
docker compose run --rm manager-os bash -lc "cargo build --release --target aarch64-unknown-linux-gnu"

echo "==> Build completed: manager-os/target/aarch64-unknown-linux-gnu/release/wifi_setup_service"
