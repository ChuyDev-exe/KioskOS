#!/bin/bash
#
# Kiosk browser launcher: WPE WebKit (cog) inside labwc.
#
# Always opens the local manager service. The service decides what to show:
# the setup wizard when there is no connectivity, or a redirect to the
# configured homepage when the device is online. So there is no "kiosk vs
# maximized" branching here anymore.
set -u

URL="http://localhost:8080"

# Page zoom applied to every site (Firefox used 0.7 via full-zoom).
SCALE="0.7"

# Maximized (not fullscreen): the on-screen keyboard (wvkbd) lives in the
# layer-shell "top" layer with an exclusive zone, so a maximized window is
# laid out above it. A fullscreen window would cover the keyboard.
export COG_PLATFORM_WL_VIEW_MAXIMIZE=1

# Wait for the manager service (max ~30 s) so the first load does not end on
# a "could not connect" page.
for _ in $(seq 1 30); do
    if (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null; then
        break
    fi
    sleep 1
done

# Keep the browser alive: if cog exits or crashes, start it again. labwc
# keeps running when its autostart child dies, so systemd's Restart= would
# never notice a dead browser.
while true; do
    /usr/bin/cog \
        --platform=wl \
        --scale="$SCALE" \
        --webprocess-failure=restart \
        --bg-color=#0b0f14 \
        "$URL"
    echo "kiosk-launch: cog exited with status $?, restarting in 2 s" >&2
    sleep 2
done
