#!/bin/bash

set -e

SCRIPT_DIR="$(pwd)"
SERVICE_PATH="/etc/systemd/system/radio.service"
USER_NAME="radiox"

if [[ $EUID -ne 0 ]]; then
   echo "Please run as root: sudo ./install.sh"
   exit 1
fi

echo "Installing dependencies..."
apt update
apt install -y mpv alsa-utils jq

# Create user if not exists
if ! id "$USER_NAME" &>/dev/null; then
    useradd -m -r -s /bin/false "$USER_NAME"
fi

# Make script executable
chmod +x "$SCRIPT_DIR/src/radio.sh"

echo "Creating systemd service..."

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Radio Player Service
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/src/radio.sh
User=$USER_NAME
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
systemctl daemon-reload
systemctl enable radio.service

echo "Installation complete!"
echo "Start with: systemctl start radio.service"
