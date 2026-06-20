#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${DEV_ENV_FILE:-$ROOT_DIR/scripts/dev.env}"

ok() {
  printf 'OK  %s\n' "$1"
}

warn() {
  printf 'WARN %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
  ok "Found command: $1"
}

check_remote_cmd() {
  local cmd="$1"
  local label="$2"
  if ssh -p "$PI_PORT" "$PI_USER@$PI_HOST" "command -v $cmd >/dev/null 2>&1"; then
    ok "Remote command available: $label"
  else
    warn "Remote command missing: $label"
  fi
}

require_cmd docker
require_cmd ssh
require_cmd scp
require_cmd rsync
require_cmd curl

if docker compose version >/dev/null 2>&1; then
  ok "docker compose available"
else
  fail "docker compose not available"
fi

[[ -f "$ENV_FILE" ]] || fail "Missing $ENV_FILE (copy scripts/dev.env.example)"
ok "Found env file: $ENV_FILE"

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${PI_HOST:?PI_HOST is required in scripts/dev.env}"
: "${PI_USER:?PI_USER is required in scripts/dev.env}"
PI_PORT="${PI_PORT:-22}"

if ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$PI_PORT" "$PI_USER@$PI_HOST" 'echo connected' >/dev/null 2>&1; then
  ok "SSH connectivity to $PI_USER@$PI_HOST:$PI_PORT"
else
  warn "SSH batch connectivity failed. You may need to accept host key or configure auth."
fi

check_remote_cmd systemctl systemctl
check_remote_cmd rsync rsync
check_remote_cmd journalctl journalctl
check_remote_cmd modprobe modprobe

if ssh -o ConnectTimeout=5 -p "$PI_PORT" "$PI_USER@$PI_HOST" 'test -d /lib/modules/$(uname -r)/build' >/dev/null 2>&1; then
  ok "Kernel headers present on Raspberry Pi"
else
  warn "Kernel headers missing on Raspberry Pi (/lib/modules/$(uname -r)/build)"
fi

if [[ -f "$ROOT_DIR/kiosk_os/adagi_os.options" ]]; then
  ok "Found options file"
else
  fail "Missing kiosk_os/adagi_os.options"
fi

if [[ -f "$ROOT_DIR/kiosk_os/config/adagi_os.yaml" ]]; then
  ok "Found build config yaml"
else
  fail "Missing kiosk_os/config/adagi_os.yaml"
fi

printf '\nDoctor check completed.\n'
