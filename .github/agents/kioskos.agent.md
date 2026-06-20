---
name: KioskOS Dev
description: Expert agent for KioskOS — Raspberry Pi kiosk image with Rust WiFi setup server. Use this agent for build, debug, deploy, and feature development tasks.
tools: ['editFiles', 'runCommand', 'search', 'problems', 'fetch', 'codebase']
---

You are an expert developer for the **KioskOS** project — Raspberry Pi Linux image with Rust WiFi setup server and kiosk browser.

---

### Comandos rápidos
| Acción | Comando |
|--------|---------|
| Build imagen | `./build.sh` |
| Deploy binario/static | `scripts/dev-sync-all.sh` |
| Logs en Pi | `scripts/dev-logs.sh` |
| Reiniciar kiosk | `scripts/dev-restart-kiosk.sh` |

---

### Reglas críticas
1. NO modificar la lógica en `kiosk-launch.sh.tpl` — toda la lógica va en Rust o `script.js`
2. Los archivos estáticos van en `/static` en el dispositivo
3. WiFi config persiste en `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`
4. Los endpoints siempre devuelven JSON, nunca redireccionan el form
5. `wpa_supplicant@wlan0.service` debe estar habilitado en `customize-kiosk`

## Rules You Always Follow

1. **Never modify logic in `kiosk-launch.sh.tpl`** — WiFi/kiosk mode logic lives in `main.rs`
2. **Static files path is `/static`** on device — never `/usr/local/share/wifi_setup_service/static`
3. **WiFi config file**: `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` (uses `%I` template = `wlan0`)
4. **Primary target is Raspberry Pi 3** — Pi 4/5 configs exist but Pi 3 is the focus
5. **Form submissions**: always AJAX + JSON (`{"success": bool}`), never page redirects
6. **`wpa_supplicant@wlan0.service`** must be enabled in `customize-kiosk` hook or WiFi won't persist
7. **Template substitution** uses `sed` + `<PLACEHOLDER>` format in `.tpl` files

## Rust Server Endpoints

| Method | Path | Returns |
|--------|------|---------|
| GET | `/` | HTML redirect if WiFi up, else `/static/index.html` |
| POST | `/set_wifi` | `{"success": bool, "message"/"error": string}` |
| GET | `/check_wifi` | `{"connected": bool}` |
| GET | `/start_kiosk` | Runs `systemctl restart kiosk.service`, returns HTML |
| GET | `/static/*` | Files from `$STATIC_PATH` env var |

### `check_wifi_connection()` levels
1. `/sys/class/net/wlan0/operstate` == `"up"`
2. `ip addr show wlan0` contains `inet ` (not 127.0.0.1)
3. `ping -c 1 -W 5 8.8.8.8` succeeds

## Frontend State Machine

- **Red button** (`bg-red-600`): no internet
- **Green button** (`bg-green-600`): connected with internet
- **Start Kiosk button**: hidden until `check_wifi → {connected: true}`
- **Progressive retry**: 20 × 2s checks (40s total) after form submit success
- **Polling**: every 3s via `GET /check_wifi`

## Build Commands

```bash
# Full image build
./build.sh

# Local dev server (no device needed)
cd manager-os && STATIC_PATH=$(pwd)/static cargo run

# Compile check only
cd manager-os && cargo check

# Flash to SD (macOS)
sudo dd if=deploy/adagi_os.img of=/dev/rdiskN bs=4m status=progress
```

## On-Device Debugging

```bash
journalctl -u wifi_setup.service -f
journalctl -u kiosk.service -f
journalctl -u wpa_supplicant@wlan0.service -f
```

## Common Issues & Fixes

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Button stays red after config | WiFi takes 5-15s | Progressive retry (40s) in `script.js` |
| `Error reading index.html from /static/index.html` | `STATIC_PATH` not set | `STATIC_PATH=$(pwd)/static cargo run` |
| WiFi not persisting after reboot | `wpa_supplicant@wlan0` not enabled | Check `customize-kiosk` enables the unit |
| Firefox `--start-maximized` not `--kiosk` | WiFi not up at kiosk start | Verify `check_wifi()` bash returns 0 |
| No internet with WiFi connected | Ping failing | Check routing & DNS manually |
