[Unit]
Description=Kiosk Wayland Session (labwc + WPE WebKit)
# The browser opens the local manager service first: start after it.
After=systemd-user-sessions.service plymouth-quit-wait.service wifi_setup.service
Wants=wifi_setup.service
# Never give up restarting the session.
StartLimitIntervalSec=0

[Service]
User=<KIOSK_USER>
TTYPath=/dev/tty1
PAMName=login
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
Environment="HOME=/home/<KIOSK_USER>"
Environment="XDG_RUNTIME_DIR=/run/user/%U"
# WebKit's HTTP cache goes to RAM (tmpfs) instead of the SD card.
RuntimeDirectory=kiosk-cache
Environment="XDG_CACHE_HOME=/run/kiosk-cache"
Restart=always
RestartSec=2
ExecStart=/usr/bin/labwc
StandardError=journal

[Install]
WantedBy=multi-user.target
