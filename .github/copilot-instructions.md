# KioskOS — Copilot Agent Instructions

## Project Overview

KioskOS is a custom Raspberry Pi Linux image that boots directly into a fullscreen kiosk browser. It includes:
- A **Rust HTTP server** (`manager-os/`) that serves a WiFi setup wizard on port 8080
- A **custom Debian image** (`kiosk_os/`) built with `rpi-image-gen` + `bdebstrap`
- A **Docker-based build pipeline** (`build.sh`, `Dockerfile`, `docker-compose.yml`)

The system supports **Raspberry Pi 3, 4, and 5**. The primary target is **Pi 3** (device config in `kiosk_os/device/pi3/`).

---

## Repository Structure

```
KioskOS/
├── build.sh                          # Main build script (Docker-based)
├── Dockerfile                        # rpi-image-gen image builder
├── docker-compose.yml                # Orchestrates manager-os + adagi_os builds
│
├── manager-os/                       # Rust WiFi setup service
│   ├── Cargo.toml                    # actix-web 4, serde, actix-files
│   ├── Dockerfile.manager            # Cross-compiles for aarch64-unknown-linux-gnu
│   ├── src/main.rs                   # HTTP server (port 8080)
│   └── static/                       # Frontend assets (served at /static/)
│       ├── index.html                # Multi-step WiFi setup wizard
│       ├── script.js                 # AJAX logic, WiFi status polling, stepper
│       ├── style.css                 # Tailwind + custom animations
│       └── tailwind.js               # Tailwind CDN bundle
│
├── kiosk_os/                         # Raspberry Pi image customizations
│   ├── adagi_os.options              # Build options (user, password, homepage URL, rotation)
│   ├── config/adagi_os.cfg           # rpi-image-gen profile config
│   ├── device/
│   │   ├── pi3/device/rootfs-overlay/boot/firmware/  # Pi 3 boot config (config.txt, cmdline.txt)
│   │   ├── pi4/device/rootfs-overlay/boot/firmware/  # Pi 4 boot config
│   │   └── pi5/device/rootfs-overlay/boot/firmware/  # Pi 5 boot config
│   ├── image/mbr/simple_dual/
│   │   ├── bdebstrap/
│   │   │   ├── customize-kiosk       # Main image customization hook (installs services, scripts)
│   │   │   ├── customize-splash      # Plymouth splash screen hook
│   │   │   └── customize05-pkgs      # Package installation hook
│   │   ├── kiosk-conf/
│   │   │   ├── kiosk-launch.sh.tpl   # Firefox launcher (template, DO NOT change logic here)
│   │   │   ├── kiosk.service.tpl     # cage Wayland session service template
│   │   │   ├── wifi_setup.service.tpl # systemd service for the Rust server
│   │   │   └── unblock-wifi.service  # rfkill unblock at boot
│   │   └── device/rootfs-overlay/
│   │       ├── etc/systemd/system/wpa_supplicant@wlan0.service
│   │       ├── static/               # Built static files (copied by build.sh)
│   │       └── usr/local/bin/wifi_setup_service  # Built Rust binary (copied by build.sh)
│   └── meta/
│       ├── customizations.yaml       # Debian packages (plymouth, cage, firefox-esr, wlr-randr)
│       └── wifi-networking.yaml      # Network stack packages
│
└── deploy/
    └── adagi_os.img                  # Final flashable image
```

---

## Technology Stack

| Component | Technology |
|-----------|-----------|
| OS Image Builder | `rpi-image-gen` + `bdebstrap` (Debian Bookworm) |
| Wayland compositor | `cage` (single-app kiosk compositor) |
| Browser | `firefox-esr` |
| Screen rotation | `wlr-randr` |
| WiFi auth | `wpa_supplicant` (template: `wpa_supplicant@wlan0.service`) |
| DHCP | `dhclient` |
| Backend | Rust, actix-web 4, actix-files 0.6, serde/serde_json |
| Frontend | Vanilla JS, Tailwind CSS, Fetch API |
| Cross-compilation | Docker + `aarch64-unknown-linux-gnu` Rust target |
| Init system | systemd |

---

## Key Configuration Variables (`adagi_os.options`)

```ini
DEVICE_USER1=adagio           # Primary kiosk OS user
DEVICE_USER1PASS=adagio       # User password
kiosk_homepage_url=https://www.berel.com/   # URL loaded in kiosk mode
kiosk_rotation=90             # Screen rotation (normal, 90, 180, 270)
```

These are injected as `$IGconf_*` variables in bdebstrap hooks and `<PLACEHOLDER>` tokens in `.tpl` files.

---

## Runtime Architecture (On Device)

```
Boot
 └── systemd
      ├── unblock-wifi.service     → rfkill unblock wifi (one-shot)
      ├── wpa_supplicant@wlan0     → WiFi auth from /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
      ├── wifi_setup.service       → Rust server on port 8080
      │    └── STATIC_PATH=/static
      │    └── KIOSK_HOMEPAGE_URL=<from options>
      └── kiosk.service            → cage → kiosk-launch.sh
           ├── if wlan0 up + inet  → firefox-esr localhost:8080 --kiosk
           └── else                → firefox-esr localhost:8080 --start-maximized
```

---

## Rust Server Endpoints (`manager-os/src/main.rs`)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | If WiFi connected → redirect HTML; else → serve `/static/index.html` |
| POST | `/set_wifi` | Write `wpa_supplicant-wlan0.conf`, restart wpa_supplicant, run dhclient. Returns JSON `{"success": bool}` |
| GET | `/check_wifi` | 3-level check: interface up → has IP → ping 8.8.8.8. Returns `{"connected": bool}` |
| GET | `/start_kiosk` | `systemctl restart kiosk.service`, returns redirect HTML |
| GET | `/static/*` | Static file serving from `$STATIC_PATH` |

### `check_wifi_connection()` logic (Rust)
1. Read `/sys/class/net/wlan0/operstate` == "up"
2. `ip addr show wlan0` contains `inet ` (not 127.0.0.1)
3. `ping -c 1 -W 5 8.8.8.8` succeeds

---

## Frontend Behavior (`static/script.js`)

- **Multi-step wizard**: 3 sections (`.Sec-form`), step persisted in `localStorage`
- **WiFi polling**: `checkWiFiStatus()` every 3 seconds via `GET /check_wifi`
- **Button states**:
  - Red (`bg-red-600`): No internet
  - Green (`bg-green-600`): Internet connected
- **Start Kiosk button**: Hidden until `/check_wifi` returns `{connected: true}`
- **Form submission**: AJAX `fetch()` to `POST /set_wifi`, never redirects
- **Progressive retry**: After successful config, polls every 2s for up to 40s (20 attempts)
- **Network scan**: `Load_network` button triggers network scan (populate `#network-select`)
- **Password toggle**: `#pwd-btn` toggles visibility of `#pwd`

---

## Build Pipeline (`build.sh`)

1. `docker compose build manager-os` → builds Rust cross-compiler image
2. `cargo build --release --target aarch64-unknown-linux-gnu` → compiles binary
3. `docker cp` binary → `kiosk_os/.../rootfs-overlay/usr/local/bin/wifi_setup_service`
4. `docker cp` static/ → `kiosk_os/.../rootfs-overlay/static/`
5. `docker compose build adagi_os` → builds rpi-image-gen image
6. `rpi-image-gen/build.sh` → runs bdebstrap → generates `.img`
7. `docker cp` → `deploy/adagi_os.img`

---

## Important Rules & Constraints

1. **Do NOT modify `kiosk-launch.sh.tpl` logic** — all WiFi/kiosk mode logic lives in Rust (`main.rs`)
2. **Static files path** is `/static` on the device (not `/usr/local/share/wifi_setup_service/static`)
3. **WiFi config file** is `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` (not `wpa_supplicant.conf`)
4. **Primary target** is Raspberry Pi 3 — Pi 4/5 configs exist but Pi 3 is the focus
5. **No page redirects** on form submission — always use AJAX + JSON responses
6. **`wpa_supplicant@wlan0.service`** must be enabled via `customize-kiosk` hook for WiFi to persist on reboot
7. All template substitution uses `sed` with `<PLACEHOLDER>` format in `.tpl` files

---

## Common Debugging

| Symptom | Cause | Fix |
|---------|-------|-----|
| WiFi not persisting after reboot | `wpa_supplicant@wlan0` not enabled | Check `customize-kiosk` enables it |
| Button stays red after config | Network takes 5-15s to establish | Progressive retry (40s timeout) in `script.js` |
| `Error reading index.html from /static/index.html` | `STATIC_PATH` not set | Set `STATIC_PATH=/path/to/static` env var |
| Firefox in `--start-maximized` instead of `--kiosk` | WiFi not up at kiosk start | Ensure `check_wifi()` in bash returns 0 |
| No internet but WiFi connected | Ping test not passing | Check routing, DNS; `ping 8.8.8.8` manually |

---

## Development Workflow

### Local run (without device)
```bash
cd manager-os
STATIC_PATH=$(pwd)/static cargo run
# Server at http://localhost:8080
```

### Full image build
```bash
./build.sh
# Output: deploy/adagi_os.img
```

### Flash to SD card
```bash
dd if=deploy/adagi_os.img of=/dev/sdX bs=4M status=progress
```

### Check logs on device
```bash
journalctl -u wifi_setup.service -f
journalctl -u kiosk.service -f
journalctl -u wpa_supplicant@wlan0.service -f
```
