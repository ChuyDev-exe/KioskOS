#!/bin/bash

# Rotate screen if configured
ROTATION="<KIOSK_ROTATION>"
if [ -n "$ROTATION" ] && [ "$ROTATION" != "normal" ]; then
    # Try common outputs for Raspberry Pi
    wlr-randr --output HDMI-A-1 --transform "$ROTATION" 2>/dev/null || true
    wlr-randr --output HDMI-A-2 --transform "$ROTATION" 2>/dev/null || true
    wlr-randr --output DSI-1 --transform "$ROTATION" 2>/dev/null || true
fi

# Launch Firefox
exec /usr/bin/firefox-esr http://localhost:8080 \
   --kiosk --noerrdialogs --disable-infobars --disable-cursor \
   --no-first-run --ozone-platform=wayland \
   --enable-features=OverlayScrollbar --start-maximized
