[Unit]
Description=Wifi Service for Setting Up Wifi SSID and PW via the Browser
After=network.target

[Service]
ExecStart=/usr/local/bin/wifi_setup_service
Environment="KIOSK_HOMEPAGE_URL=<KIOSK_HOMEPAGE_URL>"
Environment="STATIC_PATH=/static"
WorkingDirectory=/static
Restart=always
RestartSec=5
WatchdogSec=30
User=root
Group=root

[Install]
WantedBy=multi-user.target