#!/bin/bash

# Rotate screen for the kiosk session.
ROTATION="<KIOSK_ROTATION>"
# Valid rotation values: normal, 90, 180, 270
if [ -n "$ROTATION" ] && [ "$ROTATION" != "normal" ] && [ "$ROTATION" != "0" ]; then
    case "$ROTATION" in
        90|180|270)
            wlr-randr --output HDMI-A-1 --transform "$ROTATION" 2>/dev/null || true
            wlr-randr --output HDMI-A-2 --transform "$ROTATION" 2>/dev/null || true
            wlr-randr --output DSI-1 --transform "$ROTATION" 2>/dev/null || true
            ;;
    esac
fi

# Check if WiFi is connected
check_wifi() {
    local interface="wlan0"
    
    if [ ! -f "/sys/class/net/$interface/operstate" ]; then
        return 1
    fi
    
    local state=$(cat /sys/class/net/$interface/operstate 2>/dev/null || echo "down")
    if [ "$state" != "up" ]; then
        return 1
    fi
    
    if ip addr show "$interface" | grep -q "inet .*scope global"; then
        return 0
    fi
    
    return 1
}

check_internet() {
    ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1
}

# Firefox options
FIREFOX_PROFILE="/home/<KIOSK_USER>/.mozilla/firefox/kiosk.default"
FIREFOX_OPTS="--noerrdialogs --profile $FIREFOX_PROFILE"

# Give networking a short head-start, then choose launch mode.
for _ in 1 2 3 4 5; do
    check_wifi && break
    sleep 2
done

if check_wifi && check_internet; then
    exec /usr/bin/firefox-esr http://localhost:8080 $FIREFOX_OPTS --kiosk
else
    exec /usr/bin/firefox-esr http://localhost:8080 $FIREFOX_OPTS --start-maximized
fi