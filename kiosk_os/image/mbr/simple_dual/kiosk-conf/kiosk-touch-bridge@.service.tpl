[Unit]
Description=KioskOS touch bridge for %I (absolute mouse -> touchscreen)
BindsTo=dev-input-%i.device
After=dev-input-%i.device

[Service]
Type=simple
# auto: bridge absolute mice unless the same USB device already exposes a
# touchscreen; force: always; off: never (set kiosk.touch_bridge).
Environment="KIOSK_TOUCH_BRIDGE=<KIOSK_TOUCH_BRIDGE>"
ExecStartPre=-/sbin/modprobe uinput
ExecStart=/usr/local/bin/wifi_setup_service touch-bridge /dev/input/%I
Restart=on-failure
RestartSec=2
