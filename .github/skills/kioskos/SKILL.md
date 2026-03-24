---
name: kioskos
description: KioskOS development skill — use for building the Raspberry Pi kiosk image, debugging WiFi connectivity, adding Rust endpoints, modifying the setup wizard UI, configuring screen rotation, or deploying to a device. Covers the full stack: Rust actix-web server, Debian image generation with rpi-image-gen (master) + mmdebstrap, YAML layer system, Docker cross-compilation, systemd services, and vanilla JS frontend.
---

# KioskOS Skill

Use this skill to work on the **KioskOS** project — a custom Raspberry Pi Linux image that boots into a fullscreen kiosk browser with a Rust-powered WiFi setup wizard.

## When to Load This Skill

Load this skill when the user asks about any of:
- Building or rebuilding the RPi image (`./build.sh`)
- WiFi configuration not working or not persisting
- The Rust HTTP server (`manager-os/src/main.rs`)
- The WiFi wizard frontend (`manager-os/static/`)
- systemd services on the device
- Screen rotation or kiosk URL configuration
- Adding or modifying a rpi-image-gen layer
- Cross-compiling for `aarch64-unknown-linux-gnu`
- Flashing the image to an SD card
- Debugging on the device with `journalctl`

---

## Core Workflows

### 1. Build the full image

```bash
cd /path/to/KioskOS
./build.sh
# Output: deploy/adagi_os.img
```

This pipeline:
1. Cross-compiles the Rust binary via Docker (`aarch64-unknown-linux-gnu`)
2. Copies binary → `kiosk_os/image/mbr/simple_dual/device/rootfs-overlay/usr/local/bin/wifi_setup_service`
3. Copies `static/` → `kiosk_os/image/mbr/simple_dual/device/rootfs-overlay/static/`
4. Runs `rpi-image-gen build -S /home/imagegen/kiosk_os -c adagi_os.yaml` inside Docker
5. Extracts `adagi_os.img` → `deploy/adagi_os.img`

### 2. Run the server locally (no device needed)

```bash
cd manager-os
STATIC_PATH=$(pwd)/static cargo run
# Visit http://localhost:8080
```

### 3. Change kiosk URL or screen rotation

Edit `kiosk_os/config/adagi_os.yaml`:
```yaml
kiosk:
  homepage_url: https://your-new-url.com/
  rotation: "90"   # normal | 90 | 180 | 270
```
Then rebuild with `./build.sh`.

### 4. Change OS user password

Generate a SHA-512 hash and update `kiosk_os/config/adagi_os.yaml`:
```bash
openssl passwd -6 'yournewpassword'
```
```yaml
device:
  user1: adagio
  user1passhash: "$6$salt$hash..."
```
> **NEVER use `user1pass`** — the `device-base` layer validates it with a strict regex
> (requires uppercase, lowercase, digit, special char, 8+ chars). Use `user1passhash` always.

### 5. Add a new image layer

Create `kiosk_os/layer/my-layer.yaml` following this structure:
```yaml
# METABEGIN
# X-Layer-Name: my-layer
# X-Layer-Requires: rpi-user-credentials
# X-Env-Var-my_setting: description
# X-Env-Var-my_setting-Set: y
# METAEND
---
mmdebstrap:
  packages:
    - my-package
  customize-hooks:
    - |
      # $SRCROOT = kiosk_os/ directory (the -S path)
      # $1 = filesystem chroot root
      # $IGconf_my_setting = variable from config YAML
      cp "$SRCROOT/path/to/file" "$1/etc/destination"
```

Then reference it in `kiosk_os/config/adagi_os.yaml`:
```yaml
layer:
  base: bookworm-minbase
  app: adagi-kiosk
  extra: my-layer
```

### 6. Add a new Rust endpoint

In `manager-os/src/main.rs`:
```rust
async fn my_endpoint() -> impl Responder {
    let result = web::block(|| {
        Command::new("systemctl")
            .args(&["restart", "my.service"])
            .output()
    }).await;
    HttpResponse::Ok().json(serde_json::json!({"success": true}))
}
// Register in main():
.route("/my_route", web::get().to(my_endpoint))
```
Always return JSON — **never redirect** from API endpoints.

### 7. Debug WiFi on device

```bash
journalctl -u wifi_setup.service -f          # Rust server logs
journalctl -u wpa_supplicant@wlan0.service -f # WiFi auth logs
journalctl -u kiosk.service -f               # Firefox/cage logs

# Manual connectivity check:
cat /sys/class/net/wlan0/operstate           # → "up"
ip addr show wlan0                           # → shows inet 192.168.x.x
ping -c 1 8.8.8.8                            # → succeeds
cat /etc/wpa_supplicant/wpa_supplicant-wlan0.conf  # → verify creds written
```

### 8. Fix WiFi not persisting after reboot

The `adagi-kiosk.yaml` layer hook must enable the unit:
```sh
systemctl --root="$1" enable wpa_supplicant@wlan0.service
```
Config must be written to `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` (NOT `wpa_supplicant.conf`).

### 9. Flash to SD card (macOS)

```bash
diskutil list                           # find your SD card, e.g. /dev/disk4
diskutil unmountDisk /dev/disk4
sudo dd if=deploy/adagi_os.img of=/dev/rdisk4 bs=4m status=progress
diskutil eject /dev/disk4
```

---

## Architecture Reference

### Repo structure (key paths)
```
KioskOS/
├── build.sh                                     # Docker orchestration pipeline
├── Dockerfile                                   # rpi-image-gen builder (master branch + pi3 schema patch)
├── docker-compose.yml                           # manager-os + adagi_os services
├── manager-os/
│   ├── src/main.rs                              # Rust HTTP server (actix-web 4)
│   └── static/                                 # Frontend (index.html, script.js, style.css)
├── kiosk_os/
│   ├── config/adagi_os.yaml                    # ← MAIN CONFIG (device, image, layers, kiosk vars)
│   ├── layer/
│   │   ├── adagi-kiosk.yaml                    # ← MAIN LAYER (packages + services + binary install)
│   │   └── adagi-wifi.yaml                     # WiFi networking layer
│   └── image/mbr/simple_dual/
│       ├── kiosk-conf/*.tpl                     # systemd service templates (sed <PLACEHOLDER>)
│       └── device/rootfs-overlay/
│           ├── usr/local/bin/wifi_setup_service  # Built Rust binary (placed by build.sh)
│           └── static/                          # Frontend assets (placed by build.sh)
└── deploy/adagi_os.img                          # ← OUTPUT IMAGE
```

### systemd boot order
```
unblock-wifi.service  →  rfkill unblock wifi
wpa_supplicant@wlan0  →  authenticate with wpa_supplicant-wlan0.conf
wifi_setup.service    →  Rust server on :8080 (STATIC_PATH=/static)
kiosk.service         →  cage → kiosk-launch.sh → Firefox
                            WiFi up?  → --kiosk mode
                            No WiFi?  → --start-maximized mode
```

### Rust server connectivity check (3 levels)
1. `/sys/class/net/wlan0/operstate` == `"up"`
2. `ip addr show wlan0` has `inet ` (not 127.0.0.1)
3. `ping -c 1 -W 5 8.8.8.8` succeeds

### Frontend connection flow
1. Page loads → `checkWiFiStatus()` immediately + every 3s
2. Submit form → `fetch POST /set_wifi` → JSON `{"success": bool}`
3. On `success: true` → progressive retry (20 × 2s = 40s max)
4. On `connected: true` → green button + Start Kiosk appears
5. Start Kiosk → `GET /start_kiosk` → `systemctl restart kiosk.service`

---

## Critical Rules — Never Break These

| Rule | Why |
|------|-----|
| **DO NOT** change logic in `kiosk-launch.sh.tpl` | All WiFi/kiosk logic lives in `main.rs` |
| **Use `user1passhash`**, not `user1pass` | `device-base` layer has strict password regex |
| **Keep the IDP schema patch** in `Dockerfile` | `pi3` is missing from master's `idp/v2/schema.json` — removing the patch breaks the build |
| **Static path on device is `/static`** | Never `/usr/local/share/...` |
| **WiFi config**: `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` | Must match `%I` = `wlan0` template |
| **No page redirects** from API endpoints | Always AJAX + `{"success": bool}` JSON |
| **No `Requires=wifi.service`** in any service template | That service does not exist |
| **Primary target is Raspberry Pi 3** | Pi 4/5 exist but Pi 3 is the focus |

---

## Troubleshooting Quick Reference

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `[FAIL] IGconf_device_user1pass=... (invalid value)` | Strict regex in `device-base` | Switch to `user1passhash` + `openssl passwd -6` |
| `'pi3' is not one of [...]` at post-image | IDP schema missing pi3 | Restore Python patch in `Dockerfile` after `cp -r /rpi-image-gen ~/` |
| `layer 'adagi-kiosk' not found` | Layer file missing/misnamed | Confirm `kiosk_os/layer/adagi-kiosk.yaml` exists |
| `Requires=wifi.service` error | Nonexistent service referenced | Remove that line from `wifi_setup.service.tpl` |
| Button stays red after config | WiFi takes 5-15s to come up | Progressive retry (40s) already in `script.js` |
| `Error reading index.html from /static/...` | `STATIC_PATH` not set locally | `STATIC_PATH=$(pwd)/static cargo run` |
| WiFi not persisting after reboot | `wpa_supplicant@wlan0` not enabled | Check `adagi-kiosk.yaml` runs `systemctl --root="$1" enable wpa_supplicant@wlan0.service` |
| Firefox `--start-maximized` instead of `--kiosk` | WiFi not up when kiosk starts | Verify `check_wifi()` in `kiosk-launch.sh` returns 0 |
