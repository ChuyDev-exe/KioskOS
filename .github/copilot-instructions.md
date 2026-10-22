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
│       ├── index.html                # App shell: status bar + sidebar + views + dialogs
│       ├── script.js                 # Router, API client, WiFi flow, modals
│       ├── input.css                 # Tailwind source + component layer (@apply)
│       ├── style.css                 # Runtime CSS (dialog, scrollbars, layout vars)
│       ├── tailwind.config.js        # Minimal theme (colors, spacing, type scale)
│       └── tailwind-precompiled.css  # Generated bundle (do not edit)
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
│   │   │   ├── kiosk-launch.sh.tpl   # WPE WebKit (cog) launcher + restart loop (template)
│   │   │   ├── kiosk.service.tpl     # cage Wayland session service template
│   │   │   ├── wifi_setup.service.tpl # systemd service for the Rust server
│   │   │   └── unblock-wifi.service  # rfkill unblock at boot
│   │   └── device/rootfs-overlay/
│   │       ├── etc/systemd/system/wpa_supplicant@wlan0.service
│   │       ├── static/               # Built static files (copied by build.sh)
│   │       └── usr/local/bin/wifi_setup_service  # Built Rust binary (copied by build.sh)
│   └── meta/
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
| Wayland compositor | `labwc` (wlroots, wlr-layer-shell for the OSK) |
| Browser | WPE WebKit (`cog`, Wayland platform, maximized) |
| Screen rotation | `wlr-randr` |
| WiFi auth | `wpa_supplicant` (template: `wpa_supplicant@wlan0.service`) |
| DHCP | `dhclient` |
| Backend | Rust, actix-web 4, actix-files 0.6, serde/serde_json |
| Frontend | Vanilla JS, Tailwind CSS 3 (precompiled), Fetch API, inline SVG icons |
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
      └── kiosk.service            → labwc → kiosk-launch.sh
           └── cog http://localhost:8080 (restart loop; manager-os shows the
               wizard offline or redirects to the homepage online)
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

- **App shell**: status bar (connection, kiosk state, uptime, version, clock),
  sidebar with 3 views (`#estado`, `#red`, `#kiosco`) and native `<dialog>`
  modals (connect to a network, restart the kiosk)
- **Health polling**: `refreshHealth()` every 5 seconds via `GET /health`; it
  updates the status bar and the cards of the *Estado* view
- **Status dots**: green (`bg-ok`) connected, red (`bg-danger`) not connected,
  amber (`bg-warn`) pending
- **Views**: `Estado`, `Red` (scan + list + connect modal) and `Kiosco`
  (service state + restart). The current view is kept in the URL hash
- **WiFi flow**: `#btn-scan` → `GET /scan_wifi` → list → click a network →
  *Conectar a una red* modal → `POST /set_wifi` → polls `GET /check_wifi`
  every 2s for up to 40s (20 attempts)
- **Modals**: native `<dialog>` + `showModal()` (focus trap, Esc and backdrop
  for free). *Reiniciar el kiosco* navigates to `/start_kiosk`
- **Icons**: inline SVG sprite only (`#i-status`, `#i-wifi`, `#i-kiosk`,
  `#i-power`, `#i-refresh`, `#i-chevron`, `#i-check`, `#i-alert`, `#i-search`,
  `#i-close`). No emoji, no icon fonts, no raster assets
- **Values are rendered with `textContent`**, never `innerHTML`

---

## Build Pipeline (`build.sh`)

1. `sync_config_from_options` → `kiosk_os/config/adagi_os.yaml` (source of truth: `adagi_os.options`)
2. Tailwind: rebuilt only when a source changed (pinned local binary, `manager-os/package.json`)
3. Rust binary: `cargo zigbuild` → `cargo` → Docker (the image only carries the stripped binary)
4. Docker images: rebuilt only when their Dockerfile is newer than the image
5. rpi-image-gen: the workroot lives in the `image-work` volume, so the host tools and the APT
   download cache (`sys.apt_cachedir`) survive between builds. The cached filesystem is discarded
   when the layer fingerprint changes.
6. `scripts/verify-image.sh` asserts the contents of the result

### Development scripts
| Script | Purpose |
|--------|---------|
| `scripts/dev-doctor.sh` | Validates the toolchain and the device connection (5 s SSH timeout, never hangs) |
| `scripts/dev-build-rust.sh` | Native aarch64 cross-compile with fallbacks |
| `scripts/dev-build-service.sh` | Docker cross-compile (no Rust toolchain needed) |
| `scripts/dev-run-local.sh` | Runs the service locally with the static assets |
| `scripts/dev-sync-all.sh` | Build + deploy + restart on the device |
| `scripts/dev-sync-app.sh` | Deploy the binary and the static assets |
| `scripts/dev-logs.sh` | Stream the device logs |
| `scripts/verify-image.sh` | Verify the contents of the generated image |
| `scripts/dev.env.example` | Template for `scripts/dev.env` |

## Original Build Pipeline (`build.sh`)

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
| Keyboard covers the page | cog launched fullscreen | Keep `COG_PLATFORM_WL_VIEW_MAXIMIZE=1` (wvkbd reserves an exclusive zone) |
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

# POLÍTICA DE LIMPIEZA Y MINIMALISMO (actualizada)

- Eliminar cualquier archivo, script o doc que no aporte directamente al flujo de desarrollo rápido y funcional.
- Todo lo relacionado a kernel modules (kmod), pruebas legacy, variantes viejas, migraciones, ejemplos antiguos, etc., debe eliminarse si no es funcional ni esencial.
- Solo deben existir estos scripts en scripts/:
  - dev-sync-all.sh
  - dev-logs.sh
  - dev-restart-kiosk.sh
  - dev.env.example
- El folder .github/prompts solo debe contener kioskos.prompt.md
- El folder .github/skills solo debe contener kioskos/SKILL.md
- El folder .github/agents solo debe contener kioskos.agent.md
- Si aparecen archivos extra, deben ser eliminados inmediatamente.
