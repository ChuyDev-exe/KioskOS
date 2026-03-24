---
name: Migrate RPi Kiosk to rpi-image-gen New API
description: Migrates an existing Raspberry Pi kiosk project from the old rpi-image-gen API (build.sh -D, .cfg, .options, bdebstrap hooks) to the new API (rpi-image-gen build -S, YAML config, YAML layers). Adapts for Qt-based apps instead of browser/server stacks. Incorporates all hard-won fixes from production builds.
---

# Migrate Existing RPi Kiosk Project — rpi-image-gen New API + Qt

Use this prompt when you have an **existing** Raspberry Pi kiosk project that uses the **old rpi-image-gen API** and you want to migrate it to the new YAML-based API. Also applies all production fixes discovered during migration.

---

## Step 0 — Collect Info From the User

Ask these questions before touching any file:

| Variable | Question | Example |
|----------|----------|---------|
| `RPI_BRANCH` | What branch of rpi-image-gen does this project use? | `v2.0`, `stable`, `my-fork-branch` |
| `PI_TARGET` | What Raspberry Pi model is the primary target? | `pi3`, `pi4`, `pi5`, `zero2w` |
| `DEVICE_USER` | What is the OS username? | `kiosk`, `adagio`, `operator` |
| `IMAGE_NAME` | What is the image output name (no spaces)? | `factory_os`, `panel_os` |
| `OS_DIR` | What is the OS customizations directory? | `kiosk_os`, `panel_os` |
| `APP_NAME` | What is the app layer name (no spaces, kebab-case)? | `qt-panel`, `factory-app` |
| `APP_BINARY` | What is the compiled Qt binary filename? | `panel`, `factory_app` |
| `APP_BUILD_SVC` | What is the Docker Compose service name for the app build? | `app-build`, `qt-build` |
| `QT_VERSION` | Qt version used? | `qt6`, `qt5` |
| `QT_BACKEND` | Display backend? | `wayland` (recommended), `eglfs`, `xcb` |
| `SCREEN_ROTATION` | Default screen rotation? | `normal`, `90`, `180`, `270` |

---

## Step 1 — Audit the Existing Project

Before making changes, read and understand these files in the existing project:

1. `Dockerfile` — How is rpi-image-gen cloned? Pinned SHA or branch?
2. `build.sh` — What is the old build command? (`build.sh -D`? `rpi-image-gen build`?)
3. `*.cfg` or `*.options` — Old config files to be replaced by YAML
4. `bdebstrap/customize-*` scripts — Old hooks to be replaced by layer YAML
5. `docker-compose.yml` — Service names and volume mounts
6. Any existing `.tpl` service templates in `kiosk-conf/`

Check: **Does the target branch already use the new YAML API?**
- New API: the `rpi-image-gen` binary accepts `build -S <dir> -c <config.yaml>`
- Old API: a `build.sh` script accepted `-D <dir> -c <profile> -o <options>`

Run inside the container to check:
```bash
docker run --rm <image>:latest bash -c "~/rpi-image-gen/rpi-image-gen --help 2>&1 | head -20"
```

---

## Step 2 — Update `Dockerfile`

### 2a. Change from pinned SHA to branch clone

**Old pattern (remove this):**
```dockerfile
RUN git clone https://github.com/raspberrypi/rpi-image-gen.git
RUN cd rpi-image-gen && git checkout <SHA>
# or:
RUN git clone --no-checkout https://... && git -C rpi-image-gen checkout <SHA>
```

**New pattern:**
```dockerfile
RUN git clone --branch {{RPI_BRANCH}} --depth 1 https://github.com/raspberrypi/rpi-image-gen.git
```

### 2b. Add IDP schema patch (REQUIRED for Pi 3)

If `{{PI_TARGET}}` is `pi3`, add this **after** `RUN /bin/bash -c 'cp -r /rpi-image-gen ~/'`:

```dockerfile
RUN /bin/bash -c 'cp -r /rpi-image-gen ~/'

# Patch IDP v2 schema — pi3 exists as a device layer but was omitted from the schema enum.
# Without this, post-image.sh fails with: 'pi3' is not one of ['zero2w','pi4','cm4','pi5','cm5']
RUN python3 -c "\
import json; \
path = 'rpi-image-gen/layer/base/schemas/idp/v2/schema.json'; \
d = json.load(open(path)); \
enum = d['properties']['IGmeta']['properties']['IGconf_device_class']['enum']; \
'pi3' not in enum and enum.insert(0, 'pi3'); \
open(path, 'w').write(json.dumps(d, indent=4)) \
"
```

> ⚠️ **NEVER remove this patch.** The master branch's `post-image.sh` validates `IGconf_device_class`
> against this schema. Pi 3 is missing from the enum despite having a working device layer.

### 2c. amd64 cross-build support

Ensure the architecture block handles both `arm64` and `amd64`:
```dockerfile
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
```

---

## Step 3 — Create `{{OS_DIR}}/config/{{IMAGE_NAME}}.yaml`

This **replaces** the old `*.cfg` + `*.options` + `profile/` files entirely.

```yaml
# {{IMAGE_NAME}} — main build configuration
# Edit this file to change app settings, device, or credentials.
# Rebuild with: ./build.sh

device:
  layer: {{PI_TARGET}}
  user1: {{DEVICE_USER}}
  # IMPORTANT: Never use user1pass — device-base layer rejects simple passwords
  # with a strict regex (requires uppercase + lowercase + digit + special char + 8+ chars).
  # Generate hash with: openssl passwd -6 'yourpassword'
  user1passhash: "$6$CHANGEME$replaceWithOpenSSLOutput"

image:
  layer: image-rpios
  boot_part_size: 125%
  root_part_size: 125%
  name: {{IMAGE_NAME}}

layer:
  base: bookworm-minbase
  app: {{APP_NAME}}

app:
  # Custom variables — accessible in layer hooks as $IGconf_app_*
  rotation: "{{SCREEN_ROTATION}}"
```

Generate the real hash immediately:
```bash
openssl passwd -6 'your-actual-password'
# Paste output into user1passhash above
```

---

## Step 4 — Create `{{OS_DIR}}/layer/{{APP_NAME}}-wifi.yaml`

This **replaces** any old WiFi-related `meta/wifi-networking.yaml` or bdebstrap hook section.

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

## Step 5 — Create `{{OS_DIR}}/layer/{{APP_NAME}}.yaml`

This **replaces** all old `bdebstrap/customize-*` scripts. It installs Qt packages, the compiled binary, systemd services, and enables units.

```yaml
# METABEGIN
# X-Env-Layer-Name: {{APP_NAME}}
# X-Env-Layer-Category: app
# X-Env-Layer-Desc: {{IMAGE_NAME}} — Qt kiosk app via cage/Wayland
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
    # Wayland compositor (single-app, recommended for kiosk)
    - cage
    - wlr-randr

    # Qt6 packages (adjust for your Qt version and modules needed)
    # Qt6 Wayland:
    - libqt6core6
    - libqt6gui6
    - libqt6widgets6
    - libqt6waylandclient6
    - qt6-wayland
    # Qt5 Wayland alternative (use instead of Qt6 lines above):
    # - libqt5core5a
    # - libqt5gui5
    # - libqt5widgets5
    # - libqt5waylandclient5

    # Qt6 EGLFS (framebuffer, no compositor — simpler but less flexible):
    # - libqt6opengl6
    # Instead of cage + wlr-randr, no compositor is needed for EGLFS

    # System
    - plymouth
    - plymouth-themes

  install-recommends: false
  customize-hooks:
    - |-
      set -eu

      CONFD="$SRCROOT/image/mbr/simple_dual/kiosk-conf"
      OVERLAY="$SRCROOT/image/mbr/simple_dual/device/rootfs-overlay"

      # ── Directories ───────────────────────────────────────────────────────
      mkdir -p "$1/usr/local/bin"
      mkdir -p "$1/etc/systemd/system"
      mkdir -p "$1/etc/wpa_supplicant"
      mkdir -p "$1/boot/firmware"

      # ── Qt app binary (cross-compiled aarch64, placed by build.sh) ────────
      install -m 755 \
          "$OVERLAY/usr/local/bin/{{APP_BINARY}}" \
          "$1/usr/local/bin/{{APP_BINARY}}"

      # ── unblock-wifi.service ──────────────────────────────────────────────
      install -m 644 "$CONFD/unblock-wifi.service" \
          "$1/etc/systemd/system/unblock-wifi.service"

      # ── wpa_supplicant@wlan0.service ──────────────────────────────────────
      install -m 644 \
          "$OVERLAY/etc/systemd/system/wpa_supplicant@wlan0.service" \
          "$1/etc/systemd/system/wpa_supplicant@wlan0.service"

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
      # ALWAYS use --root="$1" inside hooks — bare systemctl enable fails in chroot
      systemctl --root="$1" enable wpa_supplicant@wlan0.service
      systemctl --root="$1" enable kiosk.service
      systemctl --root="$1" enable unblock-wifi.service

      # ── Mask getty on tty1 (prevent login prompt on boot) ─────────────────
      systemctl --root="$1" mask getty@tty1.service
```

---

## Step 6 — Create `kiosk-conf/app-launch.sh.tpl`

Choose the template based on `{{QT_BACKEND}}`:

### Option A: Wayland + cage (recommended)
```bash
#!/bin/bash
set -e

# Apply screen rotation via wlr-randr
ROTATION="<APP_ROTATION>"
if [ -n "$ROTATION" ] && [ "$ROTATION" != "normal" ]; then
    wlr-randr --output HDMI-A-1 --transform "$ROTATION" 2>/dev/null || true
    wlr-randr --output HDMI-A-2 --transform "$ROTATION" 2>/dev/null || true
    wlr-randr --output DSI-1    --transform "$ROTATION" 2>/dev/null || true
fi

# Launch Qt app via cage (single-app Wayland compositor)
# cage manages XDG_RUNTIME_DIR automatically
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
exec cage -- /usr/local/bin/{{APP_BINARY}}
```

### Option B: EGLFS (no compositor, direct framebuffer — simpler for fullscreen)
```bash
#!/bin/bash
set -e

# EGLFS handles rotation via environment variable
export QT_QPA_PLATFORM=eglfs
export QT_QPA_EGLFS_PHYSICAL_WIDTH=0
export QT_QPA_EGLFS_PHYSICAL_HEIGHT=0

ROTATION="<APP_ROTATION>"
case "$ROTATION" in
    90)  export QT_QPA_EGLFS_ROTATION=90  ;;
    180) export QT_QPA_EGLFS_ROTATION=180 ;;
    270) export QT_QPA_EGLFS_ROTATION=270 ;;
esac

exec /usr/local/bin/{{APP_BINARY}}
```

### Option C: X11 + openbox
```bash
#!/bin/bash
set -e

export DISPLAY=:0

ROTATION="<APP_ROTATION>"
if [ -n "$ROTATION" ] && [ "$ROTATION" != "normal" ]; then
    xrandr --output HDMI-1 --rotate "$ROTATION" 2>/dev/null || true
fi

exec /usr/local/bin/{{APP_BINARY}}
```

---

## Step 7 — Create `kiosk-conf/kiosk.service.tpl`

```ini
[Unit]
Description=Qt Kiosk Session
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

> ⚠️ **Do NOT add `Requires=<anything>.service`** unless that service is guaranteed to exist
> on the image. This was a production bug: `Requires=wifi.service` caused startup failure
> because that service doesn't exist.

---

## Step 8 — Update `build.sh`

**Old pattern (replace this):**
```bash
# Old API — DO NOT USE
docker compose exec ${RPI_BUILD_SVC} bash -c \
  "~/rpi-image-gen/build.sh -D /path/to/dir -c profile -o options.file"
```

**New pattern:**
```bash
#!/bin/bash
set -eu

BUILD_ID=${RANDOM}
APP_BUILD_SVC="{{APP_BUILD_SVC}}"
APP_BINARY_NAME="{{APP_BINARY}}"
OS_BUILD_SVC="os-build"
OS_BUILD_USER="imagegen"
OS_DIR="{{OS_DIR}}"
IMAGE_NAME="{{IMAGE_NAME}}"
SAVE_SBOM=1

ensure_cleanup() {
  for SVC in "${APP_BUILD_SVC}-${BUILD_ID}" "${OS_BUILD_SVC}-${BUILD_ID}"; do
    CID=$(docker ps -a --filter "name=${SVC}" --format "{{.ID}}" | head -n 1)
    [ -n "${CID:-}" ] && docker kill "$CID" >/dev/null 2>&1 || true
    [ -n "${CID:-}" ] && docker rm  "$CID" >/dev/null 2>&1 || true
  done
  echo "Cleanup complete."
}
trap ensure_cleanup EXIT

# ── Step 1: Cross-compile Qt app for aarch64 ──────────────────────────────
docker compose build ${APP_BUILD_SVC}
docker compose run --name ${APP_BUILD_SVC}-${BUILD_ID} -d ${APP_BUILD_SVC}

# <<< INSERT YOUR Qt build command here, e.g.:
# docker compose exec ${APP_BUILD_SVC} bash -c \
#   "cmake -B build -DCMAKE_TOOLCHAIN_FILE=cmake/aarch64-toolchain.cmake && cmake --build build"
# >>>

CID=$(docker ps -a --filter "name=${APP_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1)

# Copy binary to rootfs-overlay (picked up by layer hook via $OVERLAY)
docker cp ${CID}:/app/build/${APP_BINARY_NAME} \
  ./${OS_DIR}/image/mbr/simple_dual/device/rootfs-overlay/usr/local/bin/${APP_BINARY_NAME}

# ── Step 2: Build OS image ─────────────────────────────────────────────────
echo "🔨 Building OS image..."
docker compose build ${OS_BUILD_SVC}
docker compose run --name ${OS_BUILD_SVC}-${BUILD_ID} -d ${OS_BUILD_SVC}

# New rpi-image-gen API: "build -S <srcdir> -c <config.yaml>"
# $SRCROOT inside hooks = the -S path = /home/imagegen/{{OS_DIR}}
docker compose exec ${OS_BUILD_SVC} bash -c \
  "cd /home/${OS_BUILD_USER} && ./rpi-image-gen/rpi-image-gen build \
   -S /home/${OS_BUILD_USER}/${OS_DIR} \
   -c {{IMAGE_NAME}}.yaml"

CID=$(docker ps -a --filter "name=${OS_BUILD_SVC}-${BUILD_ID}" --format "{{.ID}}" | head -n 1)

# Use find — output path changed between rpi-image-gen versions
IMG_PATH=$(docker exec ${CID} find /home/${OS_BUILD_USER}/work \
  -name "${IMAGE_NAME}.img" 2>/dev/null | head -1)
docker cp ${CID}:"${IMG_PATH}" ./deploy/${IMAGE_NAME}.img

if [[ "${SAVE_SBOM}" == "1" ]]; then
  SBOM_PATH=$(docker exec ${CID} find /home/${OS_BUILD_USER}/work \
    -name "${IMAGE_NAME}.sbom" 2>/dev/null | head -1)
  [[ -n "${SBOM_PATH:-}" ]] && \
    docker cp ${CID}:"${SBOM_PATH}" ./deploy/${IMAGE_NAME}.sbom || true
fi

echo "✅ Done → deploy/${IMAGE_NAME}.img"
```

---

## Step 9 — Update `docker-compose.yml`

```yaml
services:
  {{APP_BUILD_SVC}}:
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
      # Mount OS customizations dir so rpi-image-gen can read config + layers
      - ./{{OS_DIR}}:/home/imagegen/{{OS_DIR}}
```

---

## Step 10 — Generate `.github/agents/` and `.github/skills/`

Create two files for the project:

### `.github/agents/{{IMAGE_NAME}}.agent.md`

```markdown
---
name: {{IMAGE_NAME}} Dev
description: Expert agent for {{IMAGE_NAME}} — Raspberry Pi {{PI_TARGET}} kiosk running a Qt app via cage/Wayland. Use for build, debug, deploy, and layer modification tasks.
tools: ['editFiles', 'runCommand', 'search', 'problems', 'fetch', 'codebase']
---

You are an expert developer for the **{{IMAGE_NAME}}** project.

## Stack
- **App**: Qt ({{QT_VERSION}}) binary `{{APP_BINARY}}` running via cage/Wayland
- **Display rotation**: wlr-randr (Wayland) or QT_QPA_EGLFS_ROTATION (EGLFS)
- **OS image**: rpi-image-gen (branch: {{RPI_BRANCH}}) + mmdebstrap, Debian Bookworm
- **Target**: Raspberry Pi {{PI_TARGET}}
- **Cross-compilation**: Docker aarch64-linux-gnu

## Key File Paths

### In repo
| Path | Purpose |
|------|---------|
| `{{OS_DIR}}/config/{{IMAGE_NAME}}.yaml` | Main build config |
| `{{OS_DIR}}/layer/{{APP_NAME}}.yaml` | Main image layer |
| `{{OS_DIR}}/layer/{{APP_NAME}}-wifi.yaml` | WiFi layer |
| `{{OS_DIR}}/image/mbr/simple_dual/kiosk-conf/app-launch.sh.tpl` | Qt launcher template |
| `{{OS_DIR}}/image/mbr/simple_dual/kiosk-conf/kiosk.service.tpl` | systemd session template |
| `app/` | Qt app source code |

### On device (runtime)
| Path | Purpose |
|------|---------|
| `/usr/local/bin/{{APP_BINARY}}` | Qt app binary |
| `/usr/local/bin/app-launch.sh` | Display setup + app launcher |
| `/etc/systemd/system/kiosk.service` | Kiosk session |
| `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` | WiFi credentials |

## rpi-image-gen API (branch: {{RPI_BRANCH}})
```bash
# Build command inside container:
rpi-image-gen build -S /home/imagegen/{{OS_DIR}} -c {{IMAGE_NAME}}.yaml
```
- `$SRCROOT` in layer hooks = the `-S` path
- `$IGconf_app_rotation` = from `app.rotation` in YAML config
- `$1` in hooks = chroot filesystem root

## Critical Rules
1. **`user1passhash`** only — `user1pass` fails strict regex in `device-base` layer
2. **Keep pi3 IDP schema Python patch** in `Dockerfile` (pi3 missing from schema enum in rpi-image-gen)
3. **`systemctl --root="$1" enable`** — always use `--root` flag inside layer hooks
4. **No `Requires=X.service`** unless that service is guaranteed on the image
5. **Qt env vars** (`QT_QPA_PLATFORM`, `QT_WAYLAND_DISABLE_WINDOWDECORATION`) go in `app-launch.sh.tpl`, not `kiosk.service.tpl`
6. **Layer `X-Env-Layer-Name`** must exactly match the value in `layer: app:` in the YAML config

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `[FAIL] IGconf_device_user1pass=... (invalid value)` | Plain password rejected | `user1passhash` + `openssl passwd -6` |
| `'pi3' is not one of [...]` | IDP schema missing pi3 | Keep Python patch in `Dockerfile` |
| Qt app: black screen / no output | Wrong `QT_QPA_PLATFORM` | Set `QT_QPA_PLATFORM=wayland` in `app-launch.sh.tpl` |
| Qt app: no Wayland socket | `XDG_RUNTIME_DIR` missing or wrong | cage sets it automatically; for EGLFS it's not needed |
| Layer not found at build | Name mismatch | `X-Env-Layer-Name` must match `layer: app:` value |
| WiFi not persisting after reboot | Unit not enabled in hook | `systemctl --root="$1" enable wpa_supplicant@wlan0.service` |

## Build Commands
```bash
./build.sh                    # Full image build
journalctl -u kiosk.service -f
journalctl -u wpa_supplicant@wlan0.service -f
diskutil unmountDisk /dev/diskN
sudo dd if=deploy/{{IMAGE_NAME}}.img of=/dev/rdiskN bs=4m status=progress
```
```

### `.github/skills/{{IMAGE_NAME}}/SKILL.md`

```markdown
---
name: {{IMAGE_NAME}}
description: {{IMAGE_NAME}} development skill — Raspberry Pi {{PI_TARGET}} kiosk running Qt via cage/Wayland. Covers rpi-image-gen YAML layer system (branch {{RPI_BRANCH}}), Docker aarch64 cross-compilation, systemd services, WiFi setup, Qt display configuration, and image deployment.
---

# {{IMAGE_NAME}} Skill

## When to Load
- Building the image (`./build.sh`)
- Qt display/rotation not working
- WiFi not connecting or persisting
- Adding/changing image layers
- Cross-compiling the Qt app
- Debugging on device with `journalctl`

## Core Workflows

### Build image
```bash
./build.sh   # → deploy/{{IMAGE_NAME}}.img
```

### Change app settings (rotation, etc.)
Edit `{{OS_DIR}}/config/{{IMAGE_NAME}}.yaml` under `app:`, then rebuild.

### Change OS password
```bash
openssl passwd -6 'newpassword'
# → paste output into user1passhash in {{IMAGE_NAME}}.yaml
```
**Never use `user1pass`** — fails strict regex in `device-base` layer.

### Add a package to the image
Add to `packages:` in `{{OS_DIR}}/layer/{{APP_NAME}}.yaml`, rebuild.

### Add a new layer
1. Create `{{OS_DIR}}/layer/my-layer.yaml` with `# METABEGIN / # METAEND` header
2. Add `extra: my-layer` under `layer:` in `{{IMAGE_NAME}}.yaml`
3. Variables declared in layer header become `$IGconf_<prefix>_<key>` in hooks

### Debug Qt display issues on device
```bash
journalctl -u kiosk.service -f        # see cage/Qt output
cat /usr/local/bin/app-launch.sh      # check env vars and launch command
# Try manually:
sudo -u {{DEVICE_USER}} cage -- /usr/local/bin/{{APP_BINARY}}
```

### Flash to SD (macOS)
```bash
diskutil unmountDisk /dev/diskN
sudo dd if=deploy/{{IMAGE_NAME}}.img of=/dev/rdiskN bs=4m status=progress
```

## Critical Rules

| Rule | Why |
|------|-----|
| Use `user1passhash`, not `user1pass` | Strict regex in `device-base` |
| Keep pi3 IDP schema patch in `Dockerfile` | pi3 missing from master's schema enum |
| `systemctl --root="$1"` in hooks | Bare `systemctl enable` fails in chroot |
| No `Requires=<nonexistent>.service` | Causes unit activation failure at boot |
| Qt env vars in `app-launch.sh.tpl` | Wrong scope if placed in `.service` file |
| `X-Env-Layer-Name` must match config `layer: app:` | Layer resolution by name |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `[FAIL] IGconf_device_user1pass=...` | Plain password | `user1passhash` + `openssl passwd -6` |
| `'pi3' is not one of [...]` | IDP schema | Python patch in `Dockerfile` |
| Black screen / no Qt output | Wrong platform plugin | `QT_QPA_PLATFORM=wayland` in `app-launch.sh.tpl` |
| Qt crashes: "no screens connected" | cage not running or wrong user | Check `journalctl -u kiosk.service`, verify cage is in packages |
| WiFi not persisting | Unit not enabled | `systemctl --root="$1" enable wpa_supplicant@wlan0.service` |
| Layer not found | Name mismatch | `X-Env-Layer-Name` must equal config `layer: app:` value |
```

---

## Checklist — Verify Before Building

Go through this list after generating all files:

- [ ] `Dockerfile`: uses `--branch {{RPI_BRANCH}} --depth 1`, NOT a pinned SHA
- [ ] `Dockerfile`: pi3 IDP schema Python patch present (if `{{PI_TARGET}}` is `pi3`)
- [ ] `{{IMAGE_NAME}}.yaml`: uses `user1passhash` with a real `openssl passwd -6` hash
- [ ] `{{IMAGE_NAME}}.yaml`: `layer: app:` value exactly matches `X-Env-Layer-Name` in the layer YAML
- [ ] `{{APP_NAME}}.yaml`: all `systemctl` calls use `--root="$1"`
- [ ] `{{APP_NAME}}.yaml`: no `Requires=wifi.service` or any other nonexistent service in `.tpl` files
- [ ] `kiosk.service.tpl`: no `Requires=` entries that reference services not in the image
- [ ] `app-launch.sh.tpl`: `QT_QPA_PLATFORM` set correctly for chosen backend
- [ ] `build.sh`: uses `rpi-image-gen build -S ... -c {{IMAGE_NAME}}.yaml` (not old `build.sh -D`)
- [ ] `build.sh`: image path discovered via `find` (output path varies between rpi-image-gen versions)
- [ ] `docker-compose.yml`: OS service volume mounts `./{{OS_DIR}}` to `/home/imagegen/{{OS_DIR}}`
- [ ] Qt binary is placed in `rootfs-overlay/usr/local/bin/{{APP_BINARY}}` by `build.sh` before OS build

---

## Qt-Specific Notes

### Wayland backend (cage) — recommended for kiosk
- `cage` is a single-app Wayland compositor — perfect for kiosk, auto-exits when app exits
- Set `QT_QPA_PLATFORM=wayland` and `QT_WAYLAND_DISABLE_WINDOWDECORATION=1` in launcher
- Rotation: use `wlr-randr` before launching cage
- Package needed: `cage`, `wlr-randr`, `libqt6waylandclient6` (or `libqt5waylandclient5`)

### EGLFS backend — direct framebuffer, no compositor
- Simpler, lower overhead, ideal if you don't need multi-window
- No `cage` or `wlr-randr` needed — remove them from packages
- Rotation via `QT_QPA_EGLFS_ROTATION=90` env var
- Package needed: `libqt6opengl6` (or equivalent)

### Touch input
- Both cage/Wayland and EGLFS support touch input natively via libinput
- Add `libqt6waylandclient6` or ensure Qt was compiled with libinput support
