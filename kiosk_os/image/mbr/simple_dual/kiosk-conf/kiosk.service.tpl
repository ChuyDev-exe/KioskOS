[Unit]
Description=Kiosk Wayland Session
After=multi-user.target

[Service]
User=<KIOSK_USER>
TTYPath=/dev/tty1
PAMName=login
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
Environment="HOME=/home/<KIOSK_USER>"
Environment="XDG_RUNTIME_DIR=/run/user/%U"
Environment="MOZ_ENABLE_WAYLAND=1"
Restart=always
ExecStart=/usr/bin/labwc
StandardError=journal

[Install]
WantedBy=default.target