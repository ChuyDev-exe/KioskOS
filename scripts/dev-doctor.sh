#!/usr/bin/env bash
#
# Validate the local development environment and the connection to the
# target Raspberry Pi.
#
#   ./scripts/dev-doctor.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${DEV_ENV_FILE:-$ROOT_DIR/scripts/dev.env}"

ok() {
  printf 'OK    %s\n' "$1"
}

warn() {
  printf 'WARN  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
  ok "Found command: $1"
}

# Never block on a password prompt or an unreachable host.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

check_remote_cmd() {
  local cmd="$1"
  local label="$2"
  if ssh "${SSH_OPTS[@]}" -p "$PI_PORT" "$PI_USER@$PI_HOST" "command -v $cmd >/dev/null 2>&1"; then
    ok "Remote command available: $label"
  else
    warn "Remote command missing: $label"
  fi
}

# ── Local tooling ───────────────────────────────────────────────────────────
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

if docker info >/dev/null 2>&1; then
  ok "docker daemon reachable"
else
  fail "docker daemon is not running"
fi

# Rust toolchain: needed for the native cross-compile fast path.
if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1090,SC1091
  source "$HOME/.cargo/env"
fi
if command -v cargo >/dev/null 2>&1; then
  ok "Found command: cargo ($(cargo --version 2>/dev/null | head -1))"
  if command -v cargo-zigbuild >/dev/null 2>&1 && command -v zig >/dev/null 2>&1; then
    ok "Native aarch64 cross-compile available (cargo-zigbuild + zig)"
  elif rustup target list --installed 2>/dev/null | grep -qx aarch64-unknown-linux-gnu &&
    command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    ok "Native aarch64 cross-compile available (cargo + cross toolchain)"
  else
    warn "No native aarch64 toolchain: builds will use Docker (install zig + cargo-zigbuild for the fast path)"
  fi
else
  warn "cargo not found: only the Docker build path will work"
fi

# Frontend tooling: the Tailwind bundle is regenerated when a source changes.
if command -v npm >/dev/null 2>&1; then
  ok "Found command: npm"
  if [ -d "$ROOT_DIR/manager-os/node_modules" ]; then
    ok "Frontend dependencies installed (manager-os/node_modules)"
  else
    warn "Frontend dependencies missing: run 'cd manager-os && npm install'"
  fi
else
  warn "npm not found: the Tailwind bundle cannot be regenerated (run 'cd manager-os && npm install')"
fi

# ── Repository ──────────────────────────────────────────────────────────────
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

if [[ -f "$ROOT_DIR/scripts/dev.env.example" ]]; then
  ok "Found env example (scripts/dev.env.example)"
else
  warn "Missing scripts/dev.env.example"
fi

# ── Device ──────────────────────────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
  ok "Found env file: $ENV_FILE"
else
  fail "Missing $ENV_FILE (copy scripts/dev.env.example)"
fi

# shellcheck disable=SC1090,SC1091
source "$ENV_FILE"

: "${PI_HOST:?PI_HOST is required in scripts/dev.env}"
: "${PI_USER:?PI_USER is required in scripts/dev.env}"
PI_PORT="${PI_PORT:-22}"

DEVICE_REACHABLE=0
if ssh "${SSH_OPTS[@]}" -p "$PI_PORT" "$PI_USER@$PI_HOST" 'echo connected' >/dev/null 2>&1; then
  ok "SSH connectivity to $PI_USER@$PI_HOST:$PI_PORT"
  DEVICE_REACHABLE=1
else
  warn "SSH connectivity failed. You may need to accept the host key or configure auth."
fi

if [ "$DEVICE_REACHABLE" = "1" ]; then
  check_remote_cmd systemctl systemctl
  check_remote_cmd rsync rsync
  check_remote_cmd journalctl journalctl
  check_remote_cmd modprobe modprobe

  if ssh "${SSH_OPTS[@]}" -p "$PI_PORT" "$PI_USER@$PI_HOST" 'test -d /lib/modules/$(uname -r)/build' >/dev/null 2>&1; then
    ok "Kernel headers present on Raspberry Pi"
  else
    warn "Kernel headers missing on Raspberry Pi (/lib/modules/$(uname -r)/build)"
  fi
else
  warn "Skipping the remote checks: the device is not reachable"
fi

printf '\nDoctor check completed.\n'
