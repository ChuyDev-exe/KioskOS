#!/bin/bash

ROTATION="<KIOSK_ROTATION>"
if [ -n "$ROTATION" ] && [ "$ROTATION" != "normal" ] && [ "$ROTATION" != "0" ]; then
    case "$ROTATION" in
        90|180|270)
            wlr-randr --output HDMI-A-1 --transform "$ROTATION" 2>/dev/null || true
            wlr-randr --output HDMI-A-2 --transform "$ROTATION" 2>/dev/null || true
            wlr-randr --output DSI-1 --transform "$ROTATION" 2>/dev/null || true
            ;;
    esac
fi

# On-screen keyboard. The Debian package installs the binary as
# wvkbd-mobintl (there is no plain "wvkbd") and it starts visible by default
# (--hidden would start it hidden; SIGUSR2 shows it, SIGUSR1 hides it).
wvkbd-mobintl &

exec /usr/local/bin/kiosk-launch.sh
