[Unit]
Description=Apply Display Rotation using wlr-randr
After=multi-user.target
Before=kiosk.service
Before=wifi_setup.service
DefaultDependencies=no

[Service]
Type=oneshot
User=<KIOSK_USER>
Environment="WAYLAND_DISPLAY=wayland-0"
Environment="XDG_RUNTIME_DIR=<KIOSK_RUNDIR>"
ExecStartPre=/bin/sleep 2
ExecStart=/usr/local/bin/rotate-display.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target