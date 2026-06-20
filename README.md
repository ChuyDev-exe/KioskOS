# KioskOS

A purpose-built, self-updating **Raspberry Pi kiosk operating system**. Flash it once and the device boots straight into a locked-down, full-screen browser kiosk with an on-screen keyboard, guided Wi‑Fi onboarding, and a built-in management service.

KioskOS produces a single bootable image (`adagi_os.img`) using [rpi-image-gen](https://github.com/raspberrypi/rpi-image-gen), with a fast development workflow that lets you iterate on a live Pi without re-flashing.

> Supported hardware: Raspberry Pi **3 / 4 / 5**. Base OS: Debian **Bookworm** (64‑bit).

---

## Features

- **Zero-touch kiosk** — boots into a full-screen Firefox ESR session under a Wayland compositor, no desktop, no login prompt.
- **Guided Wi‑Fi setup** — if there is no connection, the device serves a touch-friendly setup wizard ([manager-os](manager-os/)) so an operator can scan, select, and join a network on-screen.
- **On-screen keyboard** — native Wayland virtual keyboard for text entry on touchscreens (no browser extension required).
- **Pre-provisioning** — Wi‑Fi credentials, SSH access, kiosk URL, and screen rotation can all be baked into the image for unattended first boot.
- **Screen rotation & touch calibration** — `0 / 90 / 180 / 270`, applied to both display and touch input.
- **Branded boot** — Plymouth splash screen, no console noise.
- **A/B image layout** — dual-partition scheme (`mbr/simple_dual`) ready for safe over-the-air updates and rollback.
- **Fast dev loop** — cross-compile and sync changes to a running Pi in seconds instead of re-flashing.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ Raspberry Pi (KioskOS image)                             │
│                                                          │
│  systemd                                                 │
│   ├── wifi_setup.service   → manager-os (Rust/actix-web) │
│   │       HTTP :8080  ·  Wi-Fi wizard + control API      │
│   ├── kiosk.service        → Wayland session             │
│   │       compositor + Firefox ESR (--kiosk) + OSK       │
│   └── wpa_supplicant@wlan0 → network                     │
└──────────────────────────────────────────────────────────┘
```

- **manager-os** — a small Rust ([actix-web](https://actix.rs/)) service that detects connectivity, serves the setup UI, scans/joins Wi‑Fi, and launches the kiosk. Listens on `:8080`.
- **kiosk session** — a minimal Wayland compositor running Firefox ESR full-screen, pointed at the configured homepage (or the local setup wizard when offline).
- **Image layer** — [kiosk_os/](kiosk_os/) contains the rpi-image-gen layer, systemd units, boot config, and device overlays that assemble the OS.

---

## Repository layout

| Path | Purpose |
|------|---------|
| [build.sh](build.sh) | Builds the final `adagi_os.img` (Docker + rpi-image-gen). |
| [manager-os/](manager-os/) | Rust Wi‑Fi/management service and static web UI. |
| [manager-os/src/main.rs](manager-os/src/main.rs) | HTTP service entry point. |
| [manager-os/static/](manager-os/static/) | Setup wizard frontend (HTML/CSS/JS). |
| [kiosk_os/adagi_os.options](kiosk_os/adagi_os.options) | **Primary configuration file** (source of truth). |
| [kiosk_os/config/adagi_os.yaml](kiosk_os/config/adagi_os.yaml) | Generated build config (synced from `.options`). |
| [kiosk_os/layer/adagi-kiosk.yaml](kiosk_os/layer/adagi-kiosk.yaml) | Image layer: packages, systemd units, kiosk setup. |
| [kiosk_os/device/](kiosk_os/device/) | Per-model boot config (`pi3`, `pi4`, `pi5`). |
| [scripts/](scripts/) | Fast development workflow (build, sync, logs, doctor). |
| [Improvements.md](Improvements.md) | Engineering backlog & roadmap. |

---

## Requirements

**Build host (macOS or Linux):**
- Docker + Docker Compose
- ~10 GB free disk space

**Development Pi (optional, for the fast loop):**
- A working Pi reachable over SSH
- `rsync`, `sudo`, `systemd` on the device

---

## Quick start

### 1. Configure

Edit [kiosk_os/adagi_os.options](kiosk_os/adagi_os.options) — this is the single source of truth:

```ini
DEVICE_USER1=kiosk
DEVICE_USER1PASS=kiosk_manager

kiosk_homepage_url=https://your-kiosk-app.example.com/
kiosk_rotation=90

# Optional: preconfigure Wi-Fi for first boot
kiosk_wifi_ssid=
kiosk_wifi_psk=

# SSH on first boot (1=enabled, 0=disabled)
kiosk_ssh_enable=1
kiosk_ssh_authorized_key=ssh-ed25519 AAAA... you@host
```

| Option | Description | Values |
|--------|-------------|--------|
| `kiosk_homepage_url` | URL loaded once online | any URL |
| `kiosk_rotation` | Screen + touch rotation | `0`, `90`, `180`, `270` |
| `kiosk_wifi_ssid` / `kiosk_wifi_psk` | Optional pre-set Wi‑Fi | string |
| `kiosk_ssh_enable` | Enable SSH at first boot | `0`, `1` |
| `kiosk_ssh_authorized_key` | Public key for the kiosk user | OpenSSH pubkey |

Values are automatically synced into [config/adagi_os.yaml](kiosk_os/config/adagi_os.yaml) when you build.

### 2. Build the image

```bash
./build.sh
```

Output:
- `deploy/adagi_os.img` — flashable image
- `deploy/adagi_os.sbom` — software bill of materials (if enabled)

### 3. Flash & boot

Flash `deploy/adagi_os.img` to an SD card (e.g. with Raspberry Pi Imager or `dd`), insert it, and power on the Pi. After 30–90 seconds the device is online and, if enabled, reachable over SSH:

```bash
ssh kiosk@<pi-ip>
```

If no Wi‑Fi is configured, the kiosk shows the on-screen setup wizard to join a network.

---

## Fast development workflow

Avoid re-flashing on every change. With a development Pi configured in `scripts/dev.env`:

```bash
cp scripts/dev.env.example scripts/dev.env   # set PI_HOST / PI_USER / PI_PORT
./scripts/dev-doctor.sh                       # validate environment + connectivity
```

Then iterate:

```bash
./scripts/dev-sync-all.sh      # cross-compile + deploy service & UI, restart kiosk
./scripts/dev-logs.sh          # live logs from the device
```

`dev-sync-all.sh` cross-compiles `wifi_setup_service` for `aarch64`, copies the binary and static assets to the Pi, installs them, and restarts the service — typically in seconds.

| Script | Purpose |
|--------|---------|
| [dev-sync-all.sh](scripts/dev-sync-all.sh) | Build + deploy + restart (the everyday command). |
| [dev-build-rust.sh](scripts/dev-build-rust.sh) | Cross-compile the service only. |
| [dev-logs.sh](scripts/dev-logs.sh) | Tail device logs. |
| [dev-doctor.sh](scripts/dev-doctor.sh) | Diagnose local + Pi setup. |

---

## Management API (manager-os)

The service on `:8080` powers the setup wizard and kiosk control.

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/` | Setup wizard (offline) or redirect to kiosk homepage (online). |
| `GET` | `/check_wifi` | Returns `{ connected: bool }`. |
| `GET` | `/scan_wifi` | Lists nearby SSIDs. |
| `POST` | `/set_wifi` | Saves credentials and joins a network. |
| `GET` | `/start_kiosk` | Restarts the kiosk session. |

Quick check against a device:

```bash
curl -s http://<pi-ip>:8080/check_wifi
curl -s http://<pi-ip>:8080/scan_wifi
```

---

## Configuration & rotation

[kiosk_os/adagi_os.options](kiosk_os/adagi_os.options) is the authoritative configuration. During `./build.sh` its values are synced into [config/adagi_os.yaml](kiosk_os/config/adagi_os.yaml), including the kiosk URL, rotation, optional Wi‑Fi, and SSH settings. Treat `.options` as the file you edit; the YAML is generated.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| SSH `Permission denied` | Verify user/key in `scripts/dev.env`. |
| Service won't start | `./scripts/dev-logs.sh` or `systemctl status wifi_setup.service`. |
| No kiosk on screen | `systemctl status kiosk.service`; confirm the display is detected. |
| Wi‑Fi won't join | Confirm country/credentials; inspect `journalctl -u wpa_supplicant@wlan0`. |

---

## Roadmap

Active engineering backlog — including OTA auto-updates, CI/CD, security hardening, and UI/UX work — is tracked in [Improvements.md](Improvements.md).

---

## License

See repository for license details.
