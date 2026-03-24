#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

require_cmd curl

probe() {
  local path="$1"
  local url="${BASE_URL%/}$path"
  echo "==> GET $url"
  curl -fsS "$url"
  echo
}

probe "/check_wifi"
probe "/scan_wifi"

echo "Smoke HTTP completed against $BASE_URL"
