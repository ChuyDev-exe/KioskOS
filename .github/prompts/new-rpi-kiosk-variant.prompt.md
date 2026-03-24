---
name: New RPi Kiosk Variant
description: Bootstrap a new Raspberry Pi kiosk OS project from scratch. Adapts the KioskOS architecture (rpi-image-gen master + mmdebstrap + systemd) for any app framework and display stack. Generates all project files including Dockerfile, build.sh, YAML config, layers, and Copilot agent/skill.
---

# New Raspberry Pi Kiosk OS — Project Bootstrap

Use this prompt to create a **new Raspberry Pi kiosk OS project** based on the KioskOS architecture. You'll adapt it for a different application stack (Qt, Electron, native binary, Python/tkinter, etc.) and display server choice.

Before starting, ask the user for the values in the **Decision Matrix** below. Then generate all files listed in **Deliverables**.

---

## Decision Matrix — Ask the User First

Collect these values before generating any file. Use them everywhere as `{{VARIABLE}}` substitutions.

| Variable | Question to ask | Example values |
|----------|----------------|----------------|
| `PROJECT_NAME` | What is the project name? (lowercase, no spaces) | `factoryos`, `signageos`, `retailos` |
| `IMAGE_NAME` | What should the output `.img` be called? | `factory_os`, `signage_os` |
| `APP_NAME` | What is the main kiosk application called? | `factory-panel`, `signage-player` |
| `APP_BINARY` | What is the compiled binary/script filename? | `factory_panel`, `signage_player` |
| `APP_LANG` | What language/framework is the app? | `qt6`, `electron`, `python`, `go`, `rust`, `flutter` |
| `APP_BUILD_BASE` | What Docker base image for cross-compiling? | `debian:bookworm`, `node:20-bookworm` |
| `APP_CROSS_TARGET` | Cross-compilation target triple | `aarch64-unknown-linux-gnu`, `aarch64-linux-gnu` |
| `DISPLAY_SERVER` | Wayland or X11? | `wayland`, `x11` |
| `COMPOSITOR` | Compositor / display manager | `cage` (single-app Wayland), `labwc`, `openbox`, `matchbox` |
| `DISPLAY_ROTATION_TOOL` | Tool used to rotate display | `wlr-randr` (Wayland), `xrandr` (X11) |
| `DEVICE_USER` | Default OS username | `kiosk`, `operator`, `adagio` |
| `PI_TARGET` | Primary Raspberry Pi target | `pi3`, `pi4`, `pi5`, `zero2w` |
| `EXTRA_PACKAGES` | Any extra Debian packages needed | `libqt6widgets6`, `nodejs`, `python3` |
| `APP_ENV_VARS` | Environment variables the app needs at runtime | `DISPLAY=:0`, `QT_QPA_PLATFORM=wayland` |

---

## Architecture to Implement

The generated project must follow this pattern exactly:

```
{{PROJECT_NAME}}/
├── build.sh                          # Docker orchestration pipeline
├── Dockerfile                        # rpi-image-gen builder (master branch)
├── docker-compose.yml                # app-build + os-build services
├── app/                              # The kiosk application source
│   ├── Dockerfile.app                # Cross-compile the app for aarch64
│   └── src/                          # App source code
├── {{PROJECT_NAME}}_os/
│   ├── config/
│   │   └── {{IMAGE_NAME}}.yaml       # Main rpi-image-gen YAML config
│   ├── layer/
│   │   ├── {{APP_NAME}}-app.yaml     # Main app layer (packages + services + binary)
│   │   └── {{APP_NAME}}-wifi.yaml    # WiFi networking layer
│   └── image/mbr/simple_dual/
│       ├── kiosk-conf/
│       │   ├── kiosk.service.tpl     # cage/compositor systemd unit template
│       │   ├── app-launch.sh.tpl     # App launcher script template
│       │   └── wifi_setup.service    # WiFi setup service (if needed)
│       └── device/rootfs-overlay/
│           ├── usr/local/bin/        # Built binary goes here (by build.sh)
│           └── static/              # Static assets (if any)
└── deploy/
    └── {{IMAGE_NAME}}.img            # Output image
```

---

## Deliverables — Generate All These Files

### 1. `Dockerfile`

Builds the rpi-image-gen Docker image. **Must include** the pi3 IDP schema patch if `{{PI_TARGET}}` is `pi3`:

```dockerfile
FROM debian:bookworm AS base

RUN apt-get update && apt-get install --no-install-recommends -y \
      build-essential curl git ca-certificates sudo gpg gpg-agent \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --branch master --depth 1 https://github.com/raspberrypi/rpi-image-gen.git

ARG TARGETARCH
RUN /bin/bash -c '\
  case "${TARGETARCH}" in \
    arm64) rpi-image-gen/install_deps.sh ;; \
    amd64) \
      sed -i "s|\"\${binfmt_misc_required}\" == \"1\"|! -z \"\"|g" rpi-image-gen/scripts/dependencies_check && \
      apt-get update && apt-get install --no-install-recommends -y \
        qemu-user-static dirmngr slirp4netns quilt parted debootstrap \
        zerofree libcap2-bin libarchive-tools xxd file kmod bc pigz arch-test && \
      rpi-image-gen/install_deps.sh ;; \
  esac'

ENV USER imagegen
RUN useradd -u 4000 -ms /bin/bash "$USER" && echo "${USER}:${USER}" | chpasswd && adduser ${USER} sudo
USER ${USER}
WORKDIR /home/${USER}

RUN cp -r /rpi-image-gen ~/

# REQUIRED if PI_TARGET=pi3: patch IDP schema (pi3 missing from master's enum)
RUN python3 -c "\
import json; \
path = 'rpi-image-gen/layer/base/schemas/idp/v2/schema.json'; \
d = json.load(open(path)); \
enum = d['properties']['IGmeta']['properties']['IGconf_device_class']['enum']; \
'pi3' not in enum and enum.insert(0, 'pi3'); \
open(path, 'w').write(json.dumps(d, indent=4)) \
"
```

> **CRITICAL:** Do NOT remove the pi3 IDP schema patch if targeting Pi 3. The master branch's
> `post-image.sh` validates device class against a schema that omits pi3, failing the build.

---

### 2. `app/Dockerfile.app`

Cross-compiles the kiosk app for `aarch64`. Adapt for `{{APP_LANG}}`:

**Qt6 example:**
```dockerfile
FROM debian:bookworm AS builder
RUN apt-get update && apt-get install --no-install-recommends -y \
      gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cmake ninja-build \
      qt6-base-dev:arm64 qt6-wayland-dev:arm64   # adjust packages
WORKDIR /app
COPY . .
RUN cmake -DCMAKE_TOOLCHAIN_FILE=cmake/aarch64-toolchain.cmake -B build -G Ninja \
    && cmake --build build
```

**Rust example:**
```dockerfile
FROM rust:bookworm AS builder
RUN rustup target add aarch64-unknown-linux-gnu
RUN apt-get update && apt-get install --no-install-recommends -y gcc-aarch64-linux-gnu
WORKDIR /app
COPY . .
RUN cargo build --release --target aarch64-unknown-linux-gnu
```

**Go example:**
```dockerfile
FROM golang:1.23-bookworm AS builder
WORKDIR /app
COPY . .
RUN GOOS=linux GOARCH=arm64 go build -o {{APP_BINARY}} ./cmd/...
```

---

### 3. `docker-compose.yml`

```yaml
services:
  app-build:
    build:
      context: ./app
      dockerfile: Dockerfile.app
    stdin_open: true
    tty: true
    image: {{APP_NAME}}-build:latest
    volumes:
      - ./app:/app

  os-build:
    build: .
    privileged: true
    stdin_open: true
    tty: true
    image: {{IMAGE_NAME}}:latest
    volumes:
      - ./{{PROJECT_NAME}}_os:/home/imagegen/{{PROJECT_NAME}}_os
```

---

### 4. `build.sh`

```bash
#!/bin/bash
set -eu

BUILD_ID=${RANDOM}
APP_BUILD_SVC="app-build"
APP_BINARY_NAME="{{APP_BINARY}}"
OS_BUILD_SVC="os-build"
OS_BUILD_USER="imagegen"
OS_CUSTOMIZATIONS_DIR="{{PROJECT_NAME}}_os"
OS_IMAGE_NAME="{{IMAGE_NAME}}"
SAVE_SBOM=1

ensure_cleanup() {
  for SVC in "${APP_BUILD_SVC}-${BUILD_ID}" "${OS_BUILD_SVC}-${BUILD_ID}"; do
    CID=$(docker ps -a --filter "name=${SVC}" --format "{{.ID}}" | head -n 1)
    [ -n "${CID:-}" ] && docker kill "$CID" >/dev/null 2>&1 || true
    [ -n "${CID:-}" ] && docker rm "$CID"   >/dev/null 2>&1 || true
  done
}
trap ensure_cleanup EXIT

# ── Step 1: Build and extract the app binary ────────────────────────────────
docker compose build ${APP_BUILD_SVC}
docker compose run --name ${APP_BUILD_SVC}-${BUILD_ID} -d ${APP_BUILD_SVC}

docker compose exec ${APP_BUILD_SVC} bash -c \
  "# INSERT YOUR BUILD COMMAND HERE, e.g.:
   # cargo build --release --target aarch64-unknown-linux-gnu
   # cmake --build build
   # GOOS=linux GOARCH=arm64 go build ..."

CID=$(docker ps -a --filter "name=${APP_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1)

# Copy binary to rootfs-overlay
docker cp ${CID}:/app/path/to/${APP_BINARY_NAME} \
  ./${OS_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/usr/local/bin/${APP_BINARY_NAME}

# Copy static assets if any (remove if not needed)
rm -rf ./${OS_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/static
docker cp ${CID}:/app/static \
  ./${OS_CUSTOMIZATIONS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/static || true

# ── Step 2: Build the RPi OS image ──────────────────────────────────────────
echo "Building OS image..."
docker compose build ${OS_BUILD_SVC}
docker compose run --name ${OS_BUILD_SVC}-${BUILD_ID} -d ${OS_BUILD_SVC}

docker compose exec ${OS_BUILD_SVC} bash -c \
  "cd /home/${OS_BUILD_USER} && ./rpi-image-gen/rpi-image-gen build \
   -S /home/${OS_BUILD_USER}/${OS_CUSTOMIZATIONS_DIR} \
   -c {{IMAGE_NAME}}.yaml"

CID=$(docker ps -a --filter "name=${OS_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1)

IMG_PATH=$(docker exec ${CID} find /home/${OS_BUILD_USER}/work -name "${OS_IMAGE_NAME}.img" 2>/dev/null | head -1)
docker cp ${CID}:"${IMG_PATH}" ./deploy/${OS_IMAGE_NAME}.img

if [[ "${SAVE_SBOM}" == "1" ]]; then
  SBOM_PATH=$(docker exec ${CID} find /home/${OS_BUILD_USER}/work -name "${OS_IMAGE_NAME}.sbom" 2>/dev/null | head -1)
  [[ -n "${SBOM_PATH:-}" ]] && docker cp ${CID}:"${SBOM_PATH}" ./deploy/${OS_IMAGE_NAME}.sbom || true
fi

echo "Done → deploy/${OS_IMAGE_NAME}.img"
```

---

### 5. `{{PROJECT_NAME}}_os/config/{{IMAGE_NAME}}.yaml`

```yaml
# {{PROJECT_NAME}} — main build config
# Edit app settings here, then run ./build.sh

device:
  layer: {{PI_TARGET}}
  user1: {{DEVICE_USER}}
  # Generate with: openssl passwd -6 'yourpassword'
  # NEVER use user1pass — device-base layer rejects simple passwords
  user1passhash: "$6$CHANGEME$hash..."

image:
  layer: image-rpios
  boot_part_size: 125%
  root_part_size: 125%
  name: {{IMAGE_NAME}}

layer:
  base: bookworm-minbase
  app: {{APP_NAME}}-app

app:
  # Add your custom variables here — accessible as $IGconf_app_* in layer hooks
  rotation: "normal"   # normal | 90 | 180 | 270
  # example: target_url: https://your-app-url.com/
```

---

### 6. `{{PROJECT_NAME}}_os/layer/{{APP_NAME}}-wifi.yaml`

```yaml
# METABEGIN
# X-Env-Layer-Name: {{APP_NAME}}-wifi
# X-Env-Layer-Category: app
# X-Env-Layer-Desc: WiFi networking — brcm80211 firmware, wpa_supplicant, dhclient
# X-Env-Layer-Version: 1.0.0
# X-Env-Layer-Requires: systemd-net-min
# METAEND
---
mmdebstrap:
  packages:
    - firmware-brcm80211
    - rfkill
    - wpasupplicant
    - isc-dhcp-client
    - wireless-tools
    - iw
  install-recommends: false
  customize-hooks:
    - |-
      mkdir -p "$1/etc/systemd/network"
      {
        echo '[Match]'
        echo 'Name=wlan0'
        echo ''
        echo '[Network]'
        echo 'DHCP=yes'
        echo 'IPv6AcceptRA=yes'
      } > "$1/etc/systemd/network/25-wireless.network"
```

---

### 7. `{{PROJECT_NAME}}_os/layer/{{APP_NAME}}-app.yaml`

This is the main layer. Adapt the packages and customize-hook for the chosen display stack.

```yaml
# METABEGIN
# X-Env-Layer-Name: {{APP_NAME}}-app
# X-Env-Layer-Category: app
# X-Env-Layer-Desc: {{PROJECT_NAME}} — {{APP_LANG}} kiosk app via {{COMPOSITOR}}/{{DISPLAY_SERVER}}
# X-Env-Layer-Version: 1.0.0
# X-Env-Layer-Requires: rpi-user-credentials,{{APP_NAME}}-wifi
# X-Env-VarPrefix: app
# X-Env-Var-rotation: normal
# X-Env-Var-rotation-Desc: Screen rotation (normal, 90, 180, 270)
# X-Env-Var-rotation-Valid: keywords:normal,90,180,270
# X-Env-Var-rotation-Set: y
# METAEND
---
mmdebstrap:
  packages:
    # --- Display server ---
    # Wayland + cage (single-app compositor, recommended):
    - cage
    - wlr-randr
    # X11 alternative (use instead of cage/wlr-randr if DISPLAY_SERVER=x11):
    # - xserver-xorg-core
    # - openbox      # or matchbox-window-manager for kiosk
    # - x11-xserver-utils   # for xrandr

    # --- App framework packages (uncomment what applies) ---
    # Qt6 Wayland:
    # - libqt6widgets6
    # - libqt6waylandclient6
    # - qt6-wayland
    # Python + tkinter:
    # - python3
    # - python3-tk
    # - python3-pil
    # Node/Electron (install via npm in hook below instead):
    # - nodejs

    # --- System ---
    - plymouth
    - plymouth-themes

    # INSERT: {{EXTRA_PACKAGES}}

  install-recommends: false
  customize-hooks:
    - |-
      set -eu

      CONFD="$SRCROOT/image/mbr/simple_dual/kiosk-conf"
      OVERLAY="$SRCROOT/image/mbr/simple_dual/device/rootfs-overlay"

      mkdir -p "$1/usr/local/bin"
      mkdir -p "$1/etc/systemd/system"
      mkdir -p "$1/etc/wpa_supplicant"

      # ── App binary ────────────────────────────────────────────────────────
      install -m 755 \
          "$OVERLAY/usr/local/bin/{{APP_BINARY}}" \
          "$1/usr/local/bin/{{APP_BINARY}}"

      # ── Static assets (remove if not needed) ──────────────────────────────
      cp -r "$OVERLAY/static/." "$1/static/" || true

      # ── app-launch.sh (from template) ─────────────────────────────────────
      sed "s|<APP_ROTATION>|${IGconf_app_rotation:-normal}|g" \
          "$CONFD/app-launch.sh.tpl" \
          > "$1/usr/local/bin/app-launch.sh"
      chmod +x "$1/usr/local/bin/app-launch.sh"

      # ── kiosk.service (from template) ─────────────────────────────────────
      sed \
          -e "s|<KIOSK_USER>|${IGconf_device_user1}|g" \
          -e "s|<KIOSK_RUNDIR>|/home/${IGconf_device_user1}|g" \
          -e "s|<KIOSK_APP>|/usr/local/bin/app-launch.sh|g" \
          "$CONFD/kiosk.service.tpl" \
          > "$1/etc/systemd/system/kiosk.service"

      # ── Boot config ───────────────────────────────────────────────────────
      install -m 644 \
          "$SRCROOT/device/{{PI_TARGET}}/device/rootfs-overlay/boot/firmware/config.txt" \
          "$1/boot/firmware/config.txt" || true

      # ── Enable systemd units ──────────────────────────────────────────────
      systemctl --root="$1" enable wpa_supplicant@wlan0.service
      systemctl --root="$1" enable kiosk.service
      systemctl --root="$1" mask getty@tty1.service
```

---

### 8. `{{PROJECT_NAME}}_os/image/mbr/simple_dual/kiosk-conf/app-launch.sh.tpl`

Adapt for the display stack. Examples:

**Wayland + cage + Qt6:**
```bash
#!/bin/bash
# Apply screen rotation
wlr-randr --output HDMI-A-1 --transform <APP_ROTATION> 2>/dev/null || true
# Launch Qt app via cage (single-app Wayland compositor)
exec cage -- /usr/local/bin/{{APP_BINARY}}
```

**Wayland + cage + environment variables:**
```bash
#!/bin/bash
export QT_QPA_PLATFORM=wayland
export XDG_RUNTIME_DIR=/run/user/$(id -u)
wlr-randr --output HDMI-A-1 --transform <APP_ROTATION> 2>/dev/null || true
exec cage -- env QT_QPA_PLATFORM=wayland /usr/local/bin/{{APP_BINARY}}
```

**X11 + openbox:**
```bash
#!/bin/bash
export DISPLAY=:0
xrandr --output HDMI-1 --rotate <APP_ROTATION> 2>/dev/null || true
exec /usr/local/bin/{{APP_BINARY}}
```

---

### 9. `{{PROJECT_NAME}}_os/image/mbr/simple_dual/kiosk-conf/kiosk.service.tpl`

```ini
[Unit]
Description={{PROJECT_NAME}} Kiosk Session
After=graphical.target
Wants=graphical.target

[Service]
User=<KIOSK_USER>
WorkingDirectory=<KIOSK_RUNDIR>
ExecStart=<KIOSK_APP>
Restart=always
RestartSec=3
Environment=XDG_RUNTIME_DIR=/run/user/1000

[Install]
WantedBy=graphical.target
```

---

### 10. `.github/agents/{{PROJECT_NAME}}.agent.md`

Generate a Copilot agent file tailored to this project:

```markdown
---
name: {{PROJECT_NAME}} Dev
description: Expert agent for {{PROJECT_NAME}} — Raspberry Pi kiosk image running {{APP_LANG}} app via {{COMPOSITOR}}/{{DISPLAY_SERVER}}. Use for build, debug, deploy, and feature tasks.
tools: ['editFiles', 'runCommand', 'search', 'problems', 'fetch', 'codebase']
---

You are an expert developer for the **{{PROJECT_NAME}}** project.

## Stack
- **App**: {{APP_LANG}} binary (`{{APP_BINARY}}`) running via {{COMPOSITOR}} on {{DISPLAY_SERVER}}
- **Display rotation**: {{DISPLAY_ROTATION_TOOL}}
- **OS image**: rpi-image-gen (master) + mmdebstrap, Debian Bookworm
- **Target hardware**: Raspberry Pi {{PI_TARGET}}
- **Cross-compilation**: Docker + {{APP_CROSS_TARGET}}
- **Init system**: systemd

## Key File Paths

### In repo
| Path | Purpose |
|------|---------|
| `{{PROJECT_NAME}}_os/config/{{IMAGE_NAME}}.yaml` | Main build config (device, layers, app vars) |
| `{{PROJECT_NAME}}_os/layer/{{APP_NAME}}-app.yaml` | Main image layer (packages + binary install) |
| `{{PROJECT_NAME}}_os/layer/{{APP_NAME}}-wifi.yaml` | WiFi layer |
| `{{PROJECT_NAME}}_os/image/mbr/simple_dual/kiosk-conf/` | systemd templates |
| `app/src/` | {{APP_LANG}} app source |
| `build.sh` | Full Docker build pipeline |

### On device (runtime)
| Path | Purpose |
|------|---------|
| `/usr/local/bin/{{APP_BINARY}}` | Kiosk app binary |
| `/usr/local/bin/app-launch.sh` | Display setup + app launcher |
| `/etc/systemd/system/kiosk.service` | Main kiosk session |
| `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` | WiFi credentials |

## rpi-image-gen Build API
```bash
rpi-image-gen build -S /home/imagegen/{{PROJECT_NAME}}_os -c {{IMAGE_NAME}}.yaml
```
- `$SRCROOT` in layer hooks = the `-S` directory
- `$IGconf_app_*` = custom variables from the `app:` section of the YAML config
- `$1` in hooks = chroot filesystem root

## Critical Rules
1. **`user1passhash`** only — never `user1pass` (fails strict regex in `device-base` layer)
2. **Keep the pi3 IDP schema patch** in `Dockerfile` if targeting Pi 3
3. **No `Requires=nonexistent.service`** in any `.service` or `.tpl` file
4. **`systemctl --root="$1" enable`** — use `--root` flag in chroot hooks, not bare `systemctl enable`
5. **Display env vars** (`QT_QPA_PLATFORM`, `DISPLAY`, `XDG_RUNTIME_DIR`) go in `app-launch.sh`, not the service file
6. **Template placeholders** use `<PLACEHOLDER>` format replaced by `sed` in layer hooks

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `[FAIL] IGconf_device_user1pass=... (invalid value)` | Plain password rejected | Use `user1passhash` + `openssl passwd -6` |
| `'pi3' is not one of [...]` at post-image | Missing from IDP schema | Keep Python patch in `Dockerfile` |
| App won't start, no display output | `XDG_RUNTIME_DIR` not set or wrong user | Set in service `Environment=` or launcher script |
| `{{DISPLAY_ROTATION_TOOL}}: command not found` | Package not in layer | Add `wlr-randr` or `x11-xserver-utils` to layer packages |
| WiFi not persisting | `wpa_supplicant@wlan0` not enabled | `systemctl --root="$1" enable wpa_supplicant@wlan0.service` in hook |
| Layer not found | Wrong name in config | Layer YAML `X-Env-Layer-Name` must match config `layer: app:` value |

## Build & Debug Commands
```bash
# Full build
./build.sh

# On-device logs
journalctl -u kiosk.service -f
journalctl -u wpa_supplicant@wlan0.service -f

# Flash (macOS)
diskutil unmountDisk /dev/diskN
sudo dd if=deploy/{{IMAGE_NAME}}.img of=/dev/rdiskN bs=4m status=progress
```
```

---

### 11. `.github/skills/{{PROJECT_NAME}}/SKILL.md`

Generate a Copilot skill file tailored to this project:

```markdown
---
name: {{PROJECT_NAME}}
description: {{PROJECT_NAME}} development skill — Raspberry Pi kiosk OS running {{APP_LANG}} via {{COMPOSITOR}}/{{DISPLAY_SERVER}}. Covers rpi-image-gen YAML layer system, Docker cross-compilation for {{APP_CROSS_TARGET}}, systemd services, WiFi setup, display configuration, and image deployment.
---

# {{PROJECT_NAME}} Skill

## When to Load
- Building the RPi image (`./build.sh`)
- App display or rotation issues
- WiFi configuration
- Adding/modifying image layers
- Cross-compiling the {{APP_LANG}} app
- Debugging on device with `journalctl`
- Flashing to SD card

## Core Workflows

### Build the image
```bash
./build.sh
# Output: deploy/{{IMAGE_NAME}}.img
```

### Change app settings
Edit `{{PROJECT_NAME}}_os/config/{{IMAGE_NAME}}.yaml`:
```yaml
app:
  rotation: "90"   # normal | 90 | 180 | 270
```
Rebuild with `./build.sh`.

### Change OS user password
```bash
openssl passwd -6 'newpassword'
```
Update `user1passhash` in `{{IMAGE_NAME}}.yaml`. **Never use `user1pass`.**

### Add a new image layer
1. Create `{{PROJECT_NAME}}_os/layer/my-layer.yaml` with `# METABEGIN / # METAEND` header
2. Add `extra: my-layer` under `layer:` in `{{IMAGE_NAME}}.yaml`
3. Variables from config become `$IGconf_<section>_<key>` in hooks

### Debug on device
```bash
journalctl -u kiosk.service -f
journalctl -u wpa_supplicant@wlan0.service -f
```

### Flash to SD (macOS)
```bash
diskutil unmountDisk /dev/diskN
sudo dd if=deploy/{{IMAGE_NAME}}.img of=/dev/rdiskN bs=4m status=progress
```

## Critical Rules — Never Break

| Rule | Why |
|------|-----|
| Use `user1passhash`, not `user1pass` | Strict regex validation in `device-base` layer |
| Keep pi3 IDP schema patch in `Dockerfile` | `pi3` missing from master's schema enum |
| Use `systemctl --root="$1"` in hooks | Bare `systemctl enable` fails in chroot |
| No `Requires=<nonexistent>.service` | Causes unit activation failure at boot |
| Display env vars in `app-launch.sh` | Not in the `.service` file (wrong scope) |
| Template vars use `<PLACEHOLDER>` + `sed` | Never hardcode values directly in `.tpl` files |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `[FAIL] IGconf_device_user1pass=...` | Plain password rejected | `user1passhash` + `openssl passwd -6` |
| `'pi3' is not one of [...]` | IDP schema missing pi3 | Restore Python patch in `Dockerfile` |
| Black screen / no display | Wrong `QT_QPA_PLATFORM` or compositor | Check `app-launch.sh`, verify compositor installed |
| App crashes immediately | Missing runtime libraries | Add to layer packages, check `journalctl` |
| WiFi not persisting | Unit not enabled in hook | `systemctl --root="$1" enable wpa_supplicant@wlan0.service` |
| Layer not found at build | Name mismatch | `X-Env-Layer-Name` in YAML must match config `layer: app:` |
```

---

## Display Stack Quick Reference

When choosing packages and launcher commands, use this table:

| Stack | Compositor pkg | Rotation tool | Launcher pattern | App env var |
|-------|---------------|---------------|-----------------|-------------|
| Qt6 Wayland | `cage` | `wlr-randr` | `cage -- env QT_QPA_PLATFORM=wayland /usr/local/bin/app` | `QT_QPA_PLATFORM=wayland` |
| Qt5 Wayland | `cage` | `wlr-randr` | `cage -- env QT_QPA_PLATFORM=wayland /usr/local/bin/app` | `QT_QPA_PLATFORM=wayland` |
| Qt5 X11 | `openbox` | `xrandr` | `startx /usr/local/bin/app` | `DISPLAY=:0` |
| GTK/Python | `cage` | `wlr-randr` | `cage -- python3 /usr/local/bin/app.py` | `GDK_BACKEND=wayland` |
| Electron | `cage` | `wlr-randr` | `cage -- /usr/local/bin/app --no-sandbox` | `ELECTRON_OZONE_PLATFORM_HINT=wayland` |
| SDL2 | `cage` | `wlr-randr` | `cage -- /usr/local/bin/app` | `SDL_VIDEODRIVER=wayland` |
| Flutter | `cage` | `wlr-randr` | `cage -- /usr/local/bin/app` | `FLUTTER_ENGINE=wayland` |
| OpenGL/EGL native | `cage` | `wlr-randr` | `cage -- /usr/local/bin/app` | `WLR_LIBINPUT_NO_DEVICES=1` |

---

## Known rpi-image-gen Master Branch Constraints

These issues exist in the master branch as of early 2026 and require workarounds:

1. **`pi3` missing from IDP v2 schema** — `post-image.sh` validates device class against `layer/base/schemas/idp/v2/schema.json`. The enum only contains `['zero2w', 'pi4', 'cm4', 'pi5', 'cm5']`. **Fix**: patch the JSON in `Dockerfile` after `cp -r /rpi-image-gen ~/`.

2. **`user1pass` strict regex** — `device-base` layer rejects simple passwords. Regex requires uppercase + lowercase + digit + special char + 8+ chars. **Fix**: always use `user1passhash` with a SHA-512 hash.

3. **`systemctl enable` in chroot** — Must always use `systemctl --root="$1" enable`, never bare `systemctl enable`, inside `customize-hooks`.

4. **Layer search path** — rpi-image-gen resolves layer names by searching `<srcdir>/layer/` then its own layer dirs. Your custom layer YAML files must be in `{{PROJECT_NAME}}_os/layer/`.
