#!/bin/bash

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/DandyTheWood/InternetRadioServer/main/radio_player"
INSTALL_DIR="$HOME/InternetRadioServer"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_PATH="$SERVICE_DIR/radio.service"

echo "=== InternetRadioServer Installer ==="
echo ""

# Debian only
if ! command -v apt >/dev/null 2>&1; then
    echo "This installer supports Debian/Ubuntu only."
    exit 1
fi

# Check sudo
if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: sudo is required but not installed."
    exit 1
fi

# Install dependencies
echo "Installing dependencies..."
sudo apt update
sudo apt install -y mpv alsa-utils jq curl

# Remove old installation safely
if [ -d "$INSTALL_DIR" ]; then
    echo "Removing existing installation..."
    rm -rf "$INSTALL_DIR"
fi

# Create directory structure
mkdir -p "$INSTALL_DIR/conf"
mkdir -p "$INSTALL_DIR/src"

# Download project files
echo "Downloading project files..."

curl -fSL "$BASE_URL/src/radio.sh" -o "$INSTALL_DIR/src/radio.sh"
curl -fSL "$BASE_URL/conf/radio.json" -o "$INSTALL_DIR/conf/radio.json"

# Verify downloads
if [ ! -s "$INSTALL_DIR/src/radio.sh" ]; then
    echo "Error: Failed to download radio.sh"
    exit 1
fi

if [ ! -s "$INSTALL_DIR/conf/radio.json" ]; then
    echo "Error: Failed to download radio.json"
    exit 1
fi

chmod +x "$INSTALL_DIR/src/radio.sh"

# Create systemd user directory
mkdir -p "$SERVICE_DIR"

echo "Creating systemd user service..."

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Internet Radio Player
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/src/radio.sh
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

# Reload systemd user daemon
systemctl --user daemon-reload
systemctl --user enable radio.service

# Enable linger (boot without login)
if command -v loginctl >/dev/null 2>&1; then
    sudo loginctl enable-linger "$USER"
fi

echo ""
echo "✅ Installation complete!"
echo ""
echo "Start service:"
echo "  systemctl --user start radio.service"
echo ""
echo "Check status:"
echo "  systemctl --user status radio.service"
