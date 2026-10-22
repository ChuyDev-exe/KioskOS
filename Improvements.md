# KioskOS — Improvements (AI task spec)

Terse, actionable backlog. Paths relative to repo root. Each item = problem → fix. Pi 3 is target HW (weak CPU, ~1GB RAM, SD storage).

## DONE — touch foils / IR frames detected as a mouse (2026-10-22)
- Touch bridge (`manager-os/src/touch_bridge.rs`, `wifi_setup_service touch-bridge /dev/input/eventN`):
  an absolute mouse (ABS_X/ABS_Y + BTN_LEFT, no REL, no BTN_TOUCH, no pen) is grabbed and re-emitted
  through uinput as a single-touch touchscreen (INPUT_PROP_DIRECT, BTN_TOUCH). Skips devices whose
  USB device already exposes a touchscreen (auto), lifts the finger on SYN_DROPPED/unplug. Linux-only
  dependency (`evdev`, pure Rust): macOS local development is unaffected.
- `99-kiosk-touch-bridge.rules` + `kiosk-touch-bridge@.service` (BindsTo the device, hotplug),
  `uinput` loaded at boot. Option `kiosk.touch_bridge` = auto | force | off.
- Rotation matrix also applied to tablets and absolute mice (it was touchscreen-only, so a foil in
  mouse mode got unrotated coordinates with `rotation: 90`).
- `kiosk.usbhid_quirks` → `usbhid.quirks=` in cmdline.txt (e.g. 0x40 HID_QUIRK_MULTI_INPUT).
- `kiosk-input-diag` + `evtest` + `usbutils` on the image for field diagnosis.
- PENDING: test on the real foil / IR frame (no uinput in the dev sandbox); OSK auto show/hide
  (wvkbd is always visible; showing it only on text focus needs an input-method-v2 helper).

## DONE — minified frontend (esbuild + html-minifier-terser) (2026-10-22)
- `manager-os/scripts/build-frontend.mjs` (`npm run build`): `static/` → `dist/static/`, same file
  names. esbuild minifies JS/CSS (target `safari16` ≈ WPE WebKit 2.38), html-minifier-terser the
  HTML (inline JS with double quotes only). Fails if `{{KIOSK_HOMEPAGE_URL}}` or the doctype is lost.
  59.5 KiB → 35.2 KiB (-41 %). Not Vite: no npm imports, the Rust service serves the files, and
  hashed/moved assets would break its templates and the `/static/...` paths.
- build.sh ships `dist/static` (runs `npm ci` when node_modules is missing; falls back to the
  sources without Node.js). Build inputs (`input.css`, `tailwind.config.js`) no longer reach the
  device. `dev-sync-app.sh` deploys the minified build; `run-local.sh` keeps serving `static/`.
- verify-image.sh asserts the minified frontend; CI (workflow patch) runs `npm run build:min`.

## DONE — critical, security, robustness, build/CI and UI fixes (2026-10-22)

### Wi-Fi (manager-os `src/main.rs` + `layer/adagi-kiosk.yaml`)
- wpa_supplicant does NOT process escapes inside `ssid="..."`/`psk="..."` (it reads up to the last
  quote). The old backslash escaping broke every SSID/password with `"` or `\` (verified with the
  real wpa_supplicant: `Mi "Red"\` was read as 12 bytes instead of 9). The SSID is now written
  hex-encoded and the passphrase verbatim, both in the service and in the first-boot hook.
- A failed connection restores the previous `wpa_supplicant-wlan0.conf` (a mistyped password used
  to drop a working network). Success = associated to the requested SSID + global IPv4.
- The config is written atomically with mode 0600 (temp + fsync + rename).
- Dead `nmcli` path removed (NetworkManager is not installed). `dhclient` only runs when
  systemd-networkd is inactive (networkd already does DHCP: two clients were fighting).
- A timesyncd failure no longer marks a successful connection as failed.
- Server-side validation (SSID ≤ 32 bytes, PSK 8-63 printable ASCII or 64 hex), 409 when a
  connection is already in progress, `/check_wifi` reports `phase` (idle/connecting/connected/failed)
  and the real error.
- `kiosk.wifi_country` (default US) replaces the hard-coded `country=US`.

### Security
- Host check (DNS rebinding) on every request when bound to loopback; mutating endpoints reject a
  foreign `Origin` (CSRF from the homepage running in the same browser). `/start_kiosk` is POST-only.
- `API_TOKEN`: the wizard keeps working (same-origin on loopback); other clients need the token
  (constant-time compare). Before, enabling it broke the wizard.
- Secrets out of git: `adagi_os.local.options` (ignored) overrides `adagi_os.options`; build.sh
  generates `config/adagi_os.generated.yaml` (ignored, 0600) and builds that. The tracked yaml and
  options no longer contain the Wi-Fi password; unused `DEVICE_USER1PASS` removed.
- Homepage URL injected into the redirect templates as an escaped JS string.
- PENDING: `device.user1passhash` and the old `DEVICE_USER1PASS=kiosk_manager` are in the git
  history → rotate the password (`device_user1passhash` in the local options).

### Robustness / performance
- Connectivity = TCP connect (homepage host, 1.1.1.1:443, 8.8.8.8:53, 2 s) instead of ICMP ping;
  one probe at a time (no stampede), cache invalidated after a connection attempt.
- systemd watchdog pinged only while the HTTP server answers `/livez` (abstract sockets supported).
- `/health` runs on the blocking pool and reports `internet` and the Wi-Fi phase; 2 actix workers.
- `iw scan` retries on EBUSY and brings the link up; results carry signal (dBm) and security,
  deduplicated per SSID and sorted by signal.

### Image
- Boot config chosen by `device.class` (pi3/pi4/pi5) instead of always the Pi 4 one; Pi 5 overlay
  lost its hard-coded rotation (`display_hdmi_rotate=3`, `fbcon=rotate:3`) and gained the watchdog.

### Build / CI
- build.sh: background jobs tracked by PID (a failed parallel build used to be ignored), binary
  rebuilt on Cargo.toml/Cargo.lock changes, `docker exec` on the named container, only artifacts
  newer than the build start are copied (no stale image from the persistent volume), option
  validation (URL, rotation, country, SSID/PSK), `KIOSK_REUSE_DOCKER_IMAGES=1` for CI.
- verify-image.sh: one container for all checks, newest rootfs, new launcher/unit checks.
- Dockerfile: rpi-image-gen pinned to `a67e556` (master changes its layout format often).
- docker-compose: unused manager-os bind mounts removed. `dev.env(.example)`: `PI_USER=adagio`.
- Workflows (applied by hand, `.github/workflows` is write-protected for remote tools):
  `setup-buildx-action` (gha cache needs it), cache step skipped when nothing changed,
  `KIOSK_REUSE_DOCKER_IMAGES=1`.

### UI
- Enter in the password field connects (the form used `method="dialog"` and closed instead).
- "Red oculta" (manual SSID), open networks skip the password, show/hide password, signal and
  lock per network, client-side validation, real error from the service, "no internet" state,
  focused field scrolled into view above the OSK, health polling paused while hidden.

### Still open
- Legacy old-API files are unused but kept: `image/mbr/simple_dual/bdebstrap/`, `config/adagi_os.cfg`.
- OTA: needs an A/B layout first (see the OTA section); `simple_dual` has a single root.

## DONE — browser: Firefox ESR → WPE WebKit / cog (2026-10-21)
- `adagi-kiosk.yaml`: `firefox-esr` replaced by `cog` (+ `glib-networking` for TLS, `fontconfig`,
  `fonts-dejavu-core`, `libegl-mesa0`, `libgl1-mesa-dri`, not pulled in without recommends).
  Firefox `user.js` / `policies.json` removed.
- `kiosk-launch.sh.tpl`: waits for the manager service, then runs `cog --platform=wl --scale=0.7
  --webprocess-failure=restart` in a restart loop (labwc does not exit when its autostart child dies,
  so a crashed browser used to leave a black screen). No more kiosk/maximized branching: manager-os
  already decides between wizard and homepage.
- Window is maximized (`COG_PLATFORM_WL_VIEW_MAXIMIZE=1`), not fullscreen: wvkbd sits in the
  layer-shell top layer with an exclusive zone, so the page is laid out above the keyboard.
- `labwc-autostart.sh.tpl`: `wvkbd --show` → `wvkbd-mobintl` (Debian binary name; `--show` does not
  exist and made wvkbd exit, so the OSK never started).
- `kiosk.service.tpl`: `After/Wants=wifi_setup.service`, `WantedBy=multi-user.target` (the old
  `After=multi-user.target` + `WantedBy=default.target` was an ordering cycle), `RestartSec=2`,
  `StartLimitIntervalSec=0`, HTTP cache in tmpfs (`RuntimeDirectory=kiosk-cache`).
- `adagi-kiosk.yaml`: homepage URL escaped for sed (`&`, `|`, `\`) and systemd (`%`).
- `script.js`: after a successful Wi-Fi connection the wizard navigates to `/` (→ homepage).
- `verify-image.sh`: checks cog, wvkbd-mobintl and glib-networking; asserts Firefox is absent.
- CAVEAT: Debian ships wpewebkit 2.38.6 in bookworm (2.48.3 in trixie) and does not issue security
  updates for it ("no DSA, ignored"), unlike firefox-esr. Only load trusted sites; consider trixie.

## DONE — build speed, image size, UI redesign (2026-10-21)

### Build speed: 9.5 min → 3.5 min (warm) / 2.5 min (UI only)
- `docker-compose.yml`: named volume `image-work` mounted at `/home/imagegen/work` → the
  rpi-image-gen workroot (host support packages) survives between builds. `pull_policy: missing`.
- `kiosk_os/config/adagi_os.yaml`: new `sys:` section → `apt_cachedir: /home/imagegen/work/cache/apt`
  (the .deb downloads are reused: 401 pkgs / 302 MB in the warm build) and `apt_get_purge: false`
  (with purge on, APT deletes the packages right after installing them and empties the cache).
- `build.sh`: creates the cache dir inside the container, computes a fingerprint of the layer
  files and discards the cached filesystem only when the layers change (sudo is needed: the
  chroot is owned by root). Docker images are only rebuilt when their Dockerfile is newer.
- `build.sh`: Tailwind is only rebuilt when a source changed and uses the pinned local binary
  (`manager-os/package.json`) instead of `npx --yes tailwindcss@3` (no download, no network).
- `Dockerfile.manager`: BuildKit cache mounts for the cargo registry and target dir; cargo-chef
  removed (the cache mounts do the same job).
- `release.yml`: `cache-to: mode=min` (GHA cache is ~4x smaller).

### Image size: 1.48 GB → 1.36 GB (-8%) and -230 MB of content
- The `.img` size is driven by `image.root_part_size`, not by the content: 100% == 1.1 GB and the
  content used to fill it completely. `root_part_size: 125% → 115%` (≈170 MB free in the writable
  root) is what actually shrinks the image.
- `kiosk_os/profile/adagi_os`: dropped the `nodejs` layer (node/npm are not used on the device).
- `kiosk_os/meta/customizations.yaml` deleted: it duplicated the user creation of `adagi-kiosk.yaml`
  and pulled `firefox` (transitional → firefox-esr) and `cage`.
- `kiosk_os/layer/adagi-kiosk.yaml`: cleanup hook removes the APT lists, `/usr/share/doc`,
  `/usr/share/man` and `/usr/share/info` from the image (-110 MB).
- `manager-os/Dockerfile.manager`: the binary is now stripped (1.3 MB instead of 8.1 MB) and the
  final image is 2.1 MB instead of 8.1 MB. The 8 MB binary is no longer tracked in git.
- Biggest remaining chunk: `firefox-esr` (272 MB) + the Mesa/LLVM stack (159 MB, mandatory for
  the GL/EGL stack) + `libicu72` (35 MB). Replacing Firefox with WPE WebKit would free ~400 MB.

### Bugs fixed along the way
- `manager-os/Dockerfile.manager`: the base tag `rust:1.86.1-bookworm` **does not exist**
  (`1.86.0-bookworm` does) → the Docker build of the service was broken. Also missing the
  aarch64 cross linker (`gcc-aarch64-linux-gnu`) and a `CMD` (needed by `docker create`).
- `Dockerfile`: the amd64 branch patched `rpi-image-gen/scripts/dependencies_check`, a file that
  no longer exists upstream (it moved to `lib/dependencies.sh`) → the sed failed and broke the
  build. Removed.
- `Dockerfile`: the apt lists were never removed after `install_deps.sh` (~80 MB).

### UI redesign (Tailwind kept, minimal theme)
- New app shell: status bar (connection, kiosk state, uptime, version, clock), sidebar with
  three views (Estado / Red / Kiosco, hash routing) and native `<dialog>` modals (connect to a
  network, restart the kiosk).
- Icons: inline SVG sprite only. No emoji, no icon fonts, no raster, **no external requests**
  (the Google Fonts import was a network dependency that broke the offline wizard).
- Fixed: duplicate DOM ids (`wifi-form`, `connect-btn`, `drive`), the step 3 form posting to
  `/set_wifi` without fields (400), the stepper race (`setTimeout` without cancel), the global
  `user-select: none`, and the five dead content tiles.

## DONE — scripts and GitHub pipeline (2026-10-21)

### Scripts (all of them verified end to end)
- `scripts/dev.env.example` created: it was referenced by the README, by
  `dev-doctor.sh` and by the agent docs but did not exist.
- `scripts/dev-build-rust.sh`: was not executable and failed with
  "permission denied". Now executable, sources `~/.cargo/env` and falls back
  to the Docker path when zig / the cross toolchain are not available.
- `scripts/dev-build-service.sh`: rewrote it. It used to run `cargo build`
  inside the manager-os image, which is impossible now that the final stage
  is `FROM scratch` (it only carries the binary). It now builds the image and
  extracts the binary with `docker create` + `docker cp`, installing it both
  in `manager-os/target/` and in the image overlay.
- `scripts/dev-run-local.sh` and `manager-os/run-local.sh`: they failed with
  `cargo: not found` when the shell had no `~/.cargo/bin` in the PATH. Both
  now source `~/.cargo/env`, check the toolchain, rebuild the Tailwind bundle
  and fail early with a clear message when the port is already in use.
- `scripts/dev-doctor.sh`: the SSH calls had no timeout, so the script hung
  for minutes on an unreachable device. Now uses `BatchMode` + a 5 s
  `ConnectTimeout`, skips the remote checks when the device is unreachable
  and also verifies the Rust toolchain and the frontend dependencies.
- `scripts/dev-sync-app.sh` / `dev-logs.sh`: same SSH timeout fix, plus a
  connectivity pre-check in the sync script.
- `scripts/verify-image.sh` (new): inspects the generated ext4 image with
  `debugfs` and asserts that the frontend, the binary, the systemd units and
  the browser are installed and that nodejs, the APT lists and the docs are
  not. Used by the CI and by the release workflow.
- The Rust service now reports "port already in use" with a hint instead of
  a raw `AddrInUse` error.

### Pipeline
- `cargo test` tested nothing (there were no tests). Added 5 unit tests for
  the wpa_supplicant escaping and the open-network case; they also pin the
  "escape exactly once" behaviour.
- `cargo audit` regenerated the lockfile, so it audited versions that were
  not the ones being built. Now uses `rustsec/audit-check` with the committed
  `Cargo.lock` (the lockfile is no longer ignored: a binary must be
  reproducible).
- The yamllint glob (`kiosk_os/**/*.yaml`) did not expand recursively in bash
  (no `globstar`), so `config/adagi_os.yaml` was never linted. Now uses
  `find`.
- New CI jobs: service smoke test (real endpoints), Tailwind bundle freshness
  (`npm run css` + `git diff`), no-external-assets check (the wizard must work
  offline) and the full image build, which only runs when the image files
  change.
- `nightly.yml` had no cache and threw the image away: it now caches the
  build image, verifies the image, uploads the artifacts and publishes the
  nightly channel when the R2 credentials are configured.
- `release.yml`: publishes the minisign signature and the public key in the
  OTA manifest, self-verifies the signature before publishing and uses
  `xz --check=crc32` (faster, the sha256 in the manifest already guarantees
  the integrity).

## BUGS (fix first)
- `kiosk_os/config/adagi_os.yaml`: `homepage_url: hhttps://...` → typo `hhttps`. Fix to `https`. 🟢
- `build.sh:115-125`: manager-os image build + full `cargo build --release` + `docker compose build adagi_os` run here, then AGAIN at `:127-151`. Everything compiles twice; `BIN_BUILD_NEEDED` always evaluates stale. Delete `:115-125` (first block). Keep only the parallel section. 🟢
- `kiosk_os/image/mbr/simple_dual/kiosk-conf/kiosk-launch.sh.tpl`: Firefox launched with Chromium flags `--no-first-run --ozone-platform=wayland --enable-features=OverlayScrollbar`. Firefox ignores/breaks on these. For Wayland use env `MOZ_ENABLE_WAYLAND=1` in `kiosk.service.tpl`; remove Chromium flags. Keep `--kiosk --profile`. 🟢
- `kiosk_os/layer/adagi-kiosk.yaml`: `- openssh-server` over-indented in `mmdebstrap.packages` list. Align with siblings. 🟢
- `kiosk_os/layer/adagi-kiosk.yaml`: zoom conflict — `user.js` sets `devPixelsPerPx=0.5`/`full-zoom=0.5`; `policies.json` locks `0.7`. Policy wins, user.js is dead. Keep one source (policies.json), set both keys to same value. 🟢

## ON-SCREEN KEYBOARD — URGENT (squeekboard hidden in fullscreen kiosk)
Symptom: OSK works in maximized/setup window but NOT when Firefox is `--kiosk` (true fullscreen). Tapping a field shows nothing.
ROOT CAUSE: `cage` (`kiosk.service.tpl: ExecStart=/usr/bin/cage -- ...`) does not composite `wlr-layer-shell` overlay surfaces above a fullscreen xdg surface. squeekboard is a layer-shell overlay → Firefox fullscreen draws over it. cage is single-window by design; this won't be fixed in cage config.
FIX (do this — replace compositor):
- Swap `cage` → `labwc` (minimal stacking WM, full `wlr-layer-shell` + `input-method-v2`, renders OSK overlay above fullscreen). `sway` is the fallback if labwc misbehaves. 🟢
- Add `labwc` to `adagi-kiosk.yaml` packages; remove `cage`. 🟢
- `kiosk.service.tpl`: `ExecStart=/usr/bin/labwc`. Configure labwc autostart file to launch `squeekboard &` then the kiosk browser; set rotation via `wlr-randr` in same autostart. 🟢
- labwc `rc.xml`: force kiosk window to fill output but DO NOT let it grab exclusive fullscreen above overlay layer — use maximized + no decorations (`<windowRules>`), OR keep fullscreen and rely on labwc placing OSK on `overlay` layer (labwc does this correctly, cage does not). 🟢
- Stop browser-side fullscreen stealing the OSK layer: remove `document.documentElement.requestFullscreen()` from `manager-os/src/main.rs` `index()` redirect HTML. Let the COMPOSITOR own fullscreen, not the page. Client-requested fullscreen re-raises above overlay even on labwc. 🟢
- Firefox must speak text-input: env `MOZ_ENABLE_WAYLAND=1` + pref `widget.wayland.use-text-input=true` so focus events reach squeekboard via `input-method-v2`. 🟢
- Remove the manually-installed flaky Firefox keyboard extension from the Pi; document removal in README. 🟢
- Rotation: squeekboard follows compositor transform; verify it rotates with `<KIOSK_ROTATION>`. 🟢
- Lighter alt if RAM-tight on Pi 3: `wvkbd` (the base package, in bookworm main; `wvkbd-mobintl` arrived in trixie). Swapped squeekboard → wvkbd after squeekboard had unresolvable deps in bookworm arm64. Uses `--show` to stay always-visible in kiosk mode. 🟢
- Acceptance test: kiosk fullscreen → tap input on the live site (e.g. order notes) → OSK appears over the page → typing reaches the field → OSK hides on blur. 🟢

## manager-os (Rust server, `manager-os/src/main.rs`)
- SECURITY: `set_wifi` (`:278`) interpolates SSID/password into `wpa_supplicant.conf` unescaped → `"`/newline injection. Escape both (mirror sed-escape in `adagi-kiosk.yaml`) or use `wpa_cli`.
- SECURITY: unauthenticated mutating API runs as root on `0.0.0.0:8080`. Anyone on LAN can rewrite WiFi / restart kiosk. After connectivity, bind `127.0.0.1` only (browser is local) OR require token on `/set_wifi`,`/start_kiosk`.
- PERF: `check_wifi_connection` pings `8.8.8.8` `-W 5` on every `/` and `/check_wifi` request → up to 5s latency per call. Cache result ~10s; drop timeout to 1-2s.
- `set_wifi` blocks request up to ~35s (sleeps + 30s wait loop). Return `202` immediately; frontend polls `/check_wifi` (already exists).
- `Files::new("/static",...).show_files_listing()` (`:465`) exposes dir listing. Remove `.show_files_listing()`.
- Replace `wpa_supplicant.conf`+`systemctl`+`dhclient` orchestration (~100 lines) with NetworkManager `nmcli` (handles DHCP + reconnect). Reduces code + flakiness.
- `Cargo.toml`: `actix-web = { version="4", default-features=false, features=["macros"] }` — drops compression stack (flate2/zstd/brotli), unused on localhost. Faster compile.
- Add `[profile.release] strip=true, opt-level="z", lto=true, codegen-units=1, panic="abort"` — smaller binary, faster rsync, lower RAM.
- Inline HTML in `index`/`start_kiosk` duplicates markup. Move to static files; serve via template/read.
- Add `/health` (uptime, wlan state, temp, kiosk.service status) for fleet/OTA scraping.

## kiosk-os (image layer)
- Firefox ESR is heavy on Pi 3 (slow cold start, ~400MB+ RAM). Evaluate `cog` (WPE WebKit, embedded kiosk, fast start) or chromium `--kiosk`. Pi 4/5 Firefox OK. Gate by `device.layer`.
- Firefox kiosk-hardening via `policies.json`: add `DisableAppUpdate:true`, `DisableTelemetry:true`, `DisablePocket:true`, `DontCheckDefaultBrowser:true`, `OverrideFirstRunPage:""`, `browser.sessionstore.resume_from_crash:false` (crash dialog blocks kiosk). 🟢
- SD wear/perf: `browser.cache.disk.enable:false` (memory cache only). Disk cache writes are #1 SD-corruption cause. 🟢
- Read-only rootfs + overlayfs (kiosks get power-cut). With disk-cache off → near-immune to SD corruption.
- HW watchdog: `config.txt` `dtparam=watchdog=on` + systemd `RuntimeWatchdogSec=15s`. Frozen Pi self-reboots. 🟢
- `wifi_setup.service.tpl`: add `WatchdogSec=` + `sd_notify` ping in Rust so systemd restarts a hung service. 🟢
- AP-mode fallback: if no WiFi post-boot, bring up `hostapd`+`dnsmasq` captive portal → configure from phone (no touchscreen needed).
- mDNS via `avahi-daemon` → device reachable as `kiosk.local`. 🟢
- `boot/firmware/config.txt`: `gpu_mem=128` fine for browser; verify not starving 1GB Pi 3. Consider `gpu_mem=96` if RAM-tight.

## design / frontend (`manager-os/static/`)
- `tailwind.js` = 262KB CDN JIT runtime parsed on every load (slow on Pi 3). Precompile with Tailwind CLI → ship ~few-KB static CSS. Remove `tailwind.js`. 🟢
- Audit `index.html`/`script.js` for OSK-friendliness: large touch targets, `inputmode`/`autocomplete` attrs, viewport not obscured by OSK (scroll focused field into view). 🟢
- Bundle/minify `script.js`+`style.css`; no external CDN deps (kiosk may be offline during setup). 🟢

## performance / build
- Dev loop: drop Docker for Rust builds. `cargo-zigbuild` (zig + `cargo install cargo-zigbuild`) cross-compiles aarch64 natively on macOS; incremental rebuild sec vs min. Skips container start + slow VirtioFS bind-mount I/O. 🟢
- If keeping Docker: bind-mount `./manager-os:/app` puts `target/` on slow macOS VirtioFS. Use named volumes for `CARGO_TARGET_DIR` and `/usr/local/cargo/registry` (no re-download deps, no small-file I/O on bind mount). 🟢
- Cache rpi-image-gen base image layer; only rebuild on dep change.

## Dockerfile (`manager-os/Dockerfile.manager`)
- Remove unused deps: `gcc-arm-linux-gnueabihf`/`g++-arm-linux-gnueabihf` (32-bit ARM; target is aarch64), `bluez`, `libdbus-1-dev`, `libudev-dev`, `libssl-dev`, `qemu-user-static` — none used by current `Cargo.toml`. Big image-build speedup. 🟢
- Add `rm -rf /var/lib/apt/lists/*` after install (missing here; root `Dockerfile` does it). 🟢
- Pin via multi-stage + cargo-chef for dependency layer caching (deps compile once across code edits). 🟢

## Dockerfile (root, image-gen)
- `git clone --depth 1` rpi-image-gen pinned to `master` → non-reproducible. Pin a commit/tag via `ARG RPI_IMAGE_GEN_REF`. 🟢
- Heavy `install_deps.sh` reruns on cache miss. Order layers so deps install before any frequently-changing COPY. 🟢

## docker-compose.yml
- Add named volumes (see perf): `cargo-target`, `cargo-registry` for `manager-os`. 🟢
- `privileged: true` on both services — scope down (image-gen needs loop/binfmt; manager-os build does not). Drop privileged on `manager-os`. 🟢
- Pin `image:` tags instead of `:latest` for reproducible builds.

## OTA AUTO-UPDATE (flagship future feature)
Goal: flash a Pi once; when a newer KioskOS image is published, the device pulls + applies it itself, no reflash, no on-site visit. Reuse existing backend `ota-requester-worker` (CF Worker + R2) — it already serves the contract below; extend it from ESP32 to the Pi/image family.

BACKEND (already exists — extend, don't rebuild):
- `GET /check-update?app=kiosk&channel=stable&family=rpi&version=<current>` → `200` JSON manifest if newer (SemVer compare), `204` if up-to-date, `404` no manifest. (Worker `src/index.js handleCheckUpdate`.)
- `GET /firmware/<family>/<app>/<channel>/<version>/<file>` → proxies R2 object (the image/rootfs artifact).
- TODO worker side: add `family=rpi` defaults; manifest must carry `version`, `url` (or path), `sha256`, `size`, optional `signature`, `min_version` (block illegal downgrade/skip), `notes`. Add `release`→`latest.json` publish step in CI for the image.

DEVICE AGENT (new on Pi — `kiosk-updater`):
- Small Rust binary or systemd timer + script. Runs `kiosk-updater.timer` (e.g. every 6h + 2min after boot, randomized splay to avoid fleet thundering herd).
- Flow: read current version from `/etc/kiosk/version` → `GET /check-update?...&version=$CUR` → on `200` parse manifest → download artifact to INACTIVE A/B partition → verify `sha256` (+ signature if signed) → write to inactive root → flip boot flag → reboot into new slot.
- A/B already present (`mbr/simple_dual`). Use it: never overwrite the running slot. On boot, mark new slot "trial"; if health check passes (kiosk.service up + connectivity within N min) → commit; else rollback to previous slot (bootloader `tryboot`/`autoboot.txt` on Pi, or a boot-count flag in a small state partition).
- Resume partial downloads (HTTP Range); checksum gate before any boot-flag change. Atomic: power loss mid-download must NOT brick (inactive slot only touched until verified).
- Apply window: only when idle (no active order / between sessions) or in a configured maintenance window (e.g. 03:00 local) to avoid interrupting customers.
- Bandwidth: stream to disk, low-priority; optional delta updates later (rsync/casync/RAUC bundles) to cut image size over cellular.

SECURITY:
- HTTPS only; pin worker cert/host. Verify `sha256` ALWAYS; verify image SIGNATURE (cosign/minisign public key baked into rootfs) before flipping boot. Reject unsigned/mismatched.
- Per-device auth token (header) so only enrolled devices fetch; rotate via config.
- Channel control: `stable`/`beta`/`canary` from kiosk config → staged rollout; pin a device to a version to halt updates.

OBSERVABILITY / CONTROL:
- Report to worker on each check/apply: device ID, current version, result, error. Powers a fleet dashboard.
- Surface in `manager-os` `/health`: current version, available version, last-check time, update state (idle/downloading/ready/failed/rolled-back).
- Endpoints (token-gated): `POST /ota/check` (force now), `POST /ota/apply`, `POST /ota/pin {version}`, `POST /ota/channel {stable|beta}`.
- Server-side rollout: worker can stage % of fleet, pause on failure-rate spike.

PROVEN-STACK ALTERNATIVE (consider vs. DIY A/B):
- If hand-rolling A/B gets fragile, adopt **RAUC** or **Mender** (battle-tested A/B + rollback + signing + delta + dashboard for embedded Linux). KioskOS image build (`build.sh`/rpi-image-gen) would produce a RAUC bundle instead of raw `.img`; agent + server handle the rest. Lower long-term risk than custom flip/rollback logic.

ACCEPTANCE TEST: publish version N+1 to worker → powered device auto-detects within timer window → downloads to inactive slot → verifies → reboots → runs N+1 → induced failure → auto-rollback to N.

## HOW-TO DETAILS (concrete steps for the non-obvious items)

### A/B boot switch + rollback on Raspberry Pi (the hard part)
Pi bootloader supports `tryboot`: boots `tryboot.txt` instead of `config.txt` for ONE reboot only, then reverts unless committed. Use it for safe trials.
- Layout: slot A = `PARTUUID`-X root, slot B = -Y root, plus tiny shared state partition (or use boot dir). Each slot's `cmdline.txt` points `root=` at its own PARTUUID.
- Updater writes new image to INACTIVE slot's root partition (e.g. `dd`/extract rootfs to `/dev/mmcblk0p3`), then:
  - Write the inactive slot's boot config to `/boot/firmware/tryboot.txt` (sets `os_prefix`/`root=` for slot B).
  - Reboot with tryboot: `sudo reboot "0 tryboot"` (passes `tryboot` to firmware). Boots slot B once.
- On boot in trial slot, a `kiosk-commit.service` (oneshot, `After=kiosk.service`) waits for health (kiosk.service active + `/check_wifi` ok within N min):
  - PASS → make it permanent: copy `tryboot.txt`→`config.txt` (or set `autoboot.txt` `[tryboot] tryboot_a_b=1`), clear trial flag.
  - FAIL/no-commit → next power cycle firmware auto-reverts to `config.txt` (slot A). Optionally `rpi-eeprom` `BOOT_ORDER`/watchdog forces the cycle.
- State flag: write `/boot/firmware/ota-state` (`trial=B,ver=N+1`) so commit/rollback logic survives reboot. Bootloader's auto-revert is the safety net even if Linux never comes up.
- Simpler `autoboot.txt` A/B path (no tryboot): `[all] tryboot_a_b=1` + `boot_partition` toggling — pick one mechanism, don't mix.

### Manifest JSON (worker R2 `manifest/rpi/kiosk/stable/latest.json`)
```json
{ "version":"1.4.0","family":"rpi","app":"kiosk","channel":"stable",
  "url":"/firmware/rpi/kiosk/stable/1.4.0/rootfs.img.xz",
  "sha256":"<hex>","size":734003200,"min_version":"1.0.0",
  "signature":"<minisign>","compression":"xz","notes":"..." }
```
- Publish step (CI, after `build.sh`): upload artifact to R2 key `firmware/rpi/kiosk/stable/<ver>/rootfs.img.xz`, then overwrite `latest.json`. Sign with `minisign -Sm rootfs.img.xz` using a key whose `.pub` is baked into the rootfs.

### Updater agent core (Pi, pseudo — keep it ~150 lines Rust or a hardened bash)
```
CUR=$(cat /etc/kiosk/version)
resp=$(curl -fsS -H "X-Device-Token: $TOK" \
  "$OTA/check-update?family=rpi&app=kiosk&channel=$CH&version=$CUR")
[ -z "$resp" ] && exit 0            # 204 = up to date
url=$(jq -r .manifest.url <<<"$resp"); sha=$(jq -r .manifest.sha256 <<<"$resp")
curl -fSL -C - "$OTA$url" -o /var/ota/new.img.xz       # -C - resumes
echo "$sha  /var/ota/new.img.xz" | sha256sum -c - || exit 1
minisign -Vm /var/ota/new.img.xz -P "$PUBKEY" || exit 1
INACTIVE=$(get_inactive_slot)                          # reads current root, returns other dev
xzcat /var/ota/new.img.xz | dd of=$INACTIVE bs=4M conv=fsync
write_tryboot_for $INACTIVE; echo "trial=$INACTIVE" > /boot/firmware/ota-state
sudo reboot "0 tryboot"
```

### labwc + squeekboard (replace cage) — exact files 🟢
- `kiosk.service.tpl`: `ExecStart=/usr/bin/labwc` (drop cage). Keep `User=`, `PAMName=login`, TTY block. 🟢
- `~/.config/labwc/autostart` (install via layer hook for `<KIOSK_USER>`): 🟢
```
wlr-randr --output HDMI-A-1 --transform <KIOSK_ROTATION> 2>/dev/null || true
squeekboard &
MOZ_ENABLE_WAYLAND=1 firefox-esr --kiosk --profile $PROFILE http://localhost:8080 &
```
- `~/.config/labwc/rc.xml`: empty `<theme>` decorations off; `<windowRules><windowRule identifier="*"><skipTaskbar/></windowRule></windowRules>`; let browser fullscreen but labwc keeps OSK on overlay layer. 🟢
- Firefox pref (in `policies.json` Preferences): `"widget.wayland.use-text-input": {"Value":true,"Status":"locked"}`. 🟢
- If squeekboard still won't auto-show: it needs the compositor's `input-method-v2` + `virtual-keyboard-v1` — labwc has both; confirm `labwc --version` ≥ 0.7. cage lacks reliable layer-over-fullscreen → that's why it failed. 🟢

### Runtime config endpoint (no-reflash settings)
- Persist `/etc/kiosk/config.json`; `wifi_setup_service` loads at start + on `POST /config`.
- `POST /config {homepage_url,rotation,mode,brightness,idle_timeout}` → validate → write file → restart only affected unit (`systemctl restart kiosk.service` for url/rotation; `wlr-randr` live for rotation; write `/sys/class/backlight/*/brightness` for brightness). Redact `wifi_psk` in `GET /config`.
- Precedence in code: load defaults → overlay build-time `adagi_os.options` values (env) → overlay `/etc/kiosk/config.json`. Last wins.

### Health endpoint fields (`GET /health`, drives fleet + OTA dashboard)
```
{ version, available_version, ota_state, uptime_s, wlan:{ssid,signal_dbm,ip},
  cpu_temp_c: read /sys/class/thermal/thermal_zone0/temp ÷1000,
  mem_free_kb: /proc/meminfo, kiosk_service: systemctl is-active kiosk.service }
```

## GITHUB CI/CD 🟢
Add `.github/workflows/`. Goal: every PR checks code; tags build + sign + publish the image to the OTA worker's R2. Runners are `ubuntu-latest` (x86) — cross-build aarch64; image-gen needs `binfmt`/qemu (see root `Dockerfile` amd64 path). 🟢

### `ci.yml` (PR + push to main — fast gates, no image build) 🟢
```yaml
on: { pull_request: {}, push: { branches: [main] } }
jobs:
  rust:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with: { targets: aarch64-unknown-linux-gnu, components: clippy,rustfmt }
      - uses: Swatinem/rust-cache@v2            # caches target/ + registry
        with: { workspaces: manager-os }
      - run: cd manager-os && cargo fmt --check
      - run: cd manager-os && cargo clippy --target aarch64-unknown-linux-gnu -- -D warnings
      - run: cd manager-os && cargo build --release --target aarch64-unknown-linux-gnu
      - run: cd manager-os && cargo test
  shell:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: shellcheck build.sh scripts/*.sh kiosk_os/image/mbr/simple_dual/kiosk-conf/*.tpl
      - run: yamllint kiosk_os/**/*.yaml          # catches the openssh-server indent bug
  frontend:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npx --yes prettier --check "manager-os/static/**/*.{js,css,html}"
```
- Add `cargo-audit`/`cargo-deny` job for CVEs in deps. 🟢
- Cross-compile via `cargo-zigbuild` in CI too (same as dev) → no docker, faster, cache-friendly. 🟢

### `release.yml` (on `v*` tag — build image, sign, publish OTA) 🟢
```yaml
on: { push: { tags: ['v*'] } }
jobs:
  image:
    runs-on: ubuntu-latest
    permissions: { contents: write, id-token: write }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-qemu-action@v3       # binfmt for rpi-image-gen amd64 path
      - run: ./build.sh                         # produces deploy/adagi_os.img (+ .sbom)
      - run: xz -T0 deploy/adagi_os.img         # compress before upload
      - name: sign
        run: minisign -Sm deploy/adagi_os.img.xz -s <(echo "${{ secrets.MINISIGN_KEY }}")
      - name: checksum + manifest
        run: |                                   # build latest.json (version from tag)
          VER=${GITHUB_REF_NAME#v}; SHA=$(sha256sum deploy/adagi_os.img.xz|cut -d' ' -f1)
          jq -n --arg v "$VER" --arg s "$SHA" \
            '{version:$v,family:"rpi",app:"kiosk",channel:"stable",
              url:"/firmware/rpi/kiosk/stable/\($v)/rootfs.img.xz",sha256:$s}' > latest.json
      - name: publish to R2 (OTA worker bucket)
        env: { AWS_ACCESS_KEY_ID: ${{ secrets.R2_KEY }}, AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET }} }
        run: |                                   # R2 is S3-compatible
          aws s3 cp deploy/adagi_os.img.xz s3://mcu-ota-dev-firmware/firmware/rpi/kiosk/stable/$VER/rootfs.img.xz --endpoint-url $R2_ENDPOINT
          aws s3 cp latest.json s3://mcu-ota-dev-firmware/manifest/rpi/kiosk/stable/latest.json --endpoint-url $R2_ENDPOINT
      - uses: softprops/action-gh-release@v2     # attach .img.xz + .sbom + .sig to GH release
        with: { files: "deploy/adagi_os.img.xz*\ndeploy/*.sbom" }
```
- Secrets: `MINISIGN_KEY`, `R2_KEY`, `R2_SECRET`, `R2_ENDPOINT`. Public key `.pub` baked into rootfs for device-side verify (closes OTA signing loop). 🟢
- Channel from branch/tag suffix: `v1.4.0-beta` → `channel=beta` path → staged rollout. 🟢
- Cache the rpi-image-gen base docker layer (`docker/build-push-action` cache or `actions/cache` on `/var/lib/docker`) — image build is the slow step. 🟢
- Concurrency guard: `concurrency: { group: release-${{ github.ref }}, cancel-in-progress: false }` so two tags don't race the bucket. 🟢
- Note: OTA worker repo currently uses GitLab CI (`.gitlab-ci.yml` w/ newman smoke-test) — keep worker deploy there; this `release.yml` only PUBLISHES artifacts the worker serves. Don't duplicate worker deploy in GH.
- Optional: nightly `schedule` job rebuilding image on base-OS changes to catch upstream breakage early. 🟢

## UI / UX (setup wizard, `manager-os/static/`)
- Large touch targets (≥48px), high contrast, big fonts — Pi touchscreen + glove use. Audit `style.css`.
- OSK-aware layout: scroll focused field into view above keyboard; never let OSK cover the active input or submit button.
- WiFi flow: live `/scan_wifi` list with signal-strength bars + lock icon for secured nets; spinner during scan; manual-SSID entry for hidden nets.
- Password field: show/hide toggle (touch-friendly), inline validation, Caps-lock-style feedback (OSK has no indicator).
- Connection feedback: replace ~35s blocking wait with progress states (Saving → Connecting → Getting IP → Online) driven by `/check_wifi` polling; clear error + retry on failure.
- Success screen: show assigned IP + `kiosk.local` hostname + "Launch kiosk" button.
- Offline-first: no CDN assets (see tailwind item); all fonts/icons local — setup runs with no internet.
- i18n: strings table (ES/EN) — repo is mixed Spanish/English; pick per-device via config.
- A11y: `inputmode`, `autocomplete`, `aria-label`, focus order; respects `prefers-reduced-motion`.
- Branding: configurable logo/colors from kiosk config (white-label per customer).
- Idle screensaver/attract loop on setup screen if untouched.

## SERVER ACTIONS (new `manager-os` endpoints)
All mutating endpoints behind token/localhost (see security item). Return JSON `{success,error}`.
- `GET /health` — uptime, wlan state+SSID, signal dBm, IP, CPU temp, free RAM, kiosk.service status, image version. For OTA/fleet.
- `POST /forget_wifi` — clear `wpa_supplicant` net, return to setup.
- `GET /wifi_status` — current SSID, signal, IP, gateway (richer than `/check_wifi`).
- `POST /reboot`, `POST /shutdown` — graceful, confirm-gated.
- `POST /restart_kiosk` — already implicit in `start_kiosk`; split restart from redirect.
- `POST /set_homepage` `{url}` — change kiosk URL at runtime, persist, restart browser. No reflash.
- `POST /set_rotation` `{0|90|180|270}` — apply via `wlr-randr` live + persist.
- `POST /set_brightness` `{0-100}` — backlight via `/sys/class/backlight`.
- `GET /logs?service=` — tail journald for remote debug (token-gated).
- `POST /screenshot` — grab framebuffer (`grim`) for remote support.
- `POST /factory_reset` — wipe config/wifi, return to first-boot state.
- `GET /version` — image + service version for OTA compare.
- `POST /ota/check`, `POST /ota/apply` — trigger update agent.

## KIOSK MODES (selectable via config)
Add `kiosk.mode` to `adagi_os.options`/`adagi-kiosk.yaml`; `kiosk-launch.sh.tpl` branches on it.
- `single-url` (current) — one fullscreen site, `--kiosk`.
- `signage` — rotate through a URL playlist on a timer; no input; auto-reload on crash. For ads/menus.
- `whitelist` — kiosk URL + Firefox policy `WebsiteFilter`/allowed-domains so users can't navigate off-site.
- `maintenance` — drop to setup wizard + enable SSH + show diagnostics; triggered by key combo or `/mode`.
- `offline` — serve a local static app from `wifi_setup_service` when no internet (cached menu).
- `pos`/`self-order` (current target) — full input + OSK; ensure keyboard fix applies here.
- Auto-recovery per mode: on browser exit, relaunch (systemd `Restart=always` already on kiosk.service — verify covers in-browser crash, add inactivity reload).
- Inactivity reset: reload homepage / clear session after N min idle (abandoned order). JS idle-timer or `xdotool`-equivalent on Wayland.

## KIOSK CONFIGURATION (single source of truth + runtime)
- `adagi_os.options` is build-time source; `build.sh sync_config_from_options` pushes to yaml. Document the full key list (incl. new: `mode`, `brightness`, `screensaver_timeout`, `allowed_domains`, `logo_url`, `locale`).
- Add RUNTIME config: persist a JSON/TOML at `/etc/kiosk/config.json`; `wifi_setup_service` reads it + exposes `GET/POST /config` so settings change without reflash (homepage, rotation, mode, brightness, idle timeout).
- Config precedence: runtime file > build-time options > defaults. Server reloads on `/config` POST and restarts only affected unit.
- Validate config server-side (reuse `validate_option_values` logic from `build.sh` in Rust).
- Remote config: optional pull from a central URL/`ota-requester-worker` on boot → fleet management without touching each device.
- Secure: never log `wifi_psk`; store secrets `chmod 600`; redact in `/config` GET responses.
- Provisioning QR: encode device ID/config-endpoint as QR on setup screen → phone-based onboarding.
- First-boot wizard vs. reconfigure: detect configured state, skip wizard when already set up.
