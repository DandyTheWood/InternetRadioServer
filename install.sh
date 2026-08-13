```bash
#!/bin/bash

set -euo pipefail

# ============================================================
# InternetRadioServer - Interactive Installer
# Debian / Ubuntu
# ============================================================

INSTALL_DIR="$HOME/InternetRadioServer"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_PATH="$SERVICE_DIR/radio.service"

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

error() {
    echo ""
    echo "ERROR: $1"
    echo ""
    exit 1
}

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

clear

echo "=============================================="
echo "       InternetRadioServer Installer"
echo "=============================================="
echo ""

# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
    error "Do not run this installer as root."
fi

if ! command -v apt >/dev/null 2>&1; then
    error "This installer supports Debian/Ubuntu only."
fi

if ! command -v sudo >/dev/null 2>&1; then
    error "sudo is required but was not found."
fi

if ! command -v systemctl >/dev/null 2>&1; then
    error "systemctl was not found. systemd is required."
fi

# ------------------------------------------------------------
# Ask for radio stream URL
# ------------------------------------------------------------

echo "Radio configuration"
echo "-------------------"
echo ""
echo "Enter the URL of your internet radio stream."
echo ""
echo "Example:"
echo "  https://example.com/radio.mp3"
echo ""
echo "The URL must start with http:// or https://."
echo ""

while true; do
    read -r -p "Radio stream URL: " STREAM_URL

    # Remove accidental whitespace
    STREAM_URL="$(printf '%s' "$STREAM_URL" | xargs)"

    if [ -z "$STREAM_URL" ]; then
        echo "Please enter a URL."
        echo ""
        continue
    fi

    if [[ ! "$STREAM_URL" =~ ^https?:// ]]; then
        echo "Invalid URL. It must start with http:// or https://."
        echo ""
        continue
    fi

    break
done

echo ""

# ------------------------------------------------------------
# Ask for station name
# ------------------------------------------------------------

read -r -p "Radio station name [Internet Radio]: " STATION_NAME

if [ -z "$STATION_NAME" ]; then
    STATION_NAME="Internet Radio"
fi

echo ""

# ------------------------------------------------------------
# Ask for volume
# ------------------------------------------------------------

while true; do
    read -r -p "Initial volume (0-100) [70]: " VOLUME

    if [ -z "$VOLUME" ]; then
        VOLUME=70
    fi

    if [[ "$VOLUME" =~ ^[0-9]+$ ]] && [ "$VOLUME" -ge 0 ] && [ "$VOLUME" -le 100 ]; then
        break
    fi

    echo "Please enter a number from 0 to 100."
done

echo ""

# ------------------------------------------------------------
# Show configuration
# ------------------------------------------------------------

echo "=============================================="
echo "Configuration"
echo "=============================================="
echo ""
echo "Station : $STATION_NAME"
echo "Stream  : $STREAM_URL"
echo "Volume  : $VOLUME%"
echo ""

read -r -p "Continue with installation? [Y/n]: " CONFIRM

if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
    echo ""
    echo "Installation cancelled."
    exit 0
fi

echo ""

# ------------------------------------------------------------
# Install dependencies
# ------------------------------------------------------------

echo "Installing dependencies..."

sudo apt update
sudo apt install -y mpv alsa-utils jq curl

echo ""
echo "Dependencies installed."
echo ""

# ------------------------------------------------------------
# Stop existing service
# ------------------------------------------------------------

if systemctl --user list-unit-files 2>/dev/null | grep -q '^radio\.service'; then
    echo "Stopping existing radio service..."

    systemctl --user stop radio.service 2>/dev/null || true
    systemctl --user disable radio.service 2>/dev/null || true
fi

# ------------------------------------------------------------
# Backup existing installation
# ------------------------------------------------------------

if [ -d "$INSTALL_DIR" ]; then

    BACKUP_DIR="${INSTALL_DIR}.backup.$(date +%Y%m%d-%H%M%S)"

    echo "Existing installation found."
    echo "Creating backup:"
    echo "  $BACKUP_DIR"

    mv "$INSTALL_DIR" "$BACKUP_DIR"

    echo ""
fi

# ------------------------------------------------------------
# Create directories
# ------------------------------------------------------------

echo "Creating installation directory..."

mkdir -p "$INSTALL_DIR/src"
mkdir -p "$INSTALL_DIR/conf"
mkdir -p "$SERVICE_DIR"

# ------------------------------------------------------------
# Create configuration
# ------------------------------------------------------------

echo "Creating radio configuration..."

cat > "$INSTALL_DIR/conf/radio.json" <<EOF
{
    "station_name": $(printf '%s' "$STATION_NAME" | jq -R .),
    "stream_url": $(printf '%s' "$STREAM_URL" | jq -R .),
    "volume": $VOLUME
}
EOF

# Validate JSON
if ! jq empty "$INSTALL_DIR/conf/radio.json" >/dev/null 2>&1; then
    error "Generated radio.json is invalid."
fi

# ------------------------------------------------------------
# Create radio player
# ------------------------------------------------------------

cat > "$INSTALL_DIR/src/radio.sh" <<'EOF'
#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$INSTALL_DIR/conf/radio.json"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Configuration file not found:"
    echo "$CONFIG"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is not installed."
    exit 1
fi

if ! command -v mpv >/dev/null 2>&1; then
    echo "ERROR: mpv is not installed."
    exit 1
fi

STATION_NAME="$(jq -r '.station_name' "$CONFIG")"
STREAM_URL="$(jq -r '.stream_url' "$CONFIG")"
VOLUME="$(jq -r '.volume' "$CONFIG")"

if [ -z "$STREAM_URL" ] || [ "$STREAM_URL" = "null" ]; then
    echo "ERROR: No stream URL configured."
    exit 1
fi

echo "=============================================="
echo "Starting Internet Radio"
echo "Station: $STATION_NAME"
echo "Stream : $STREAM_URL"
echo "Volume : $VOLUME%"
echo "=============================================="

exec mpv \
    --no-video \
    --volume="$VOLUME" \
    --network-timeout=15 \
    --audio-display=no \
    "$STREAM_URL"
EOF

chmod 0755 "$INSTALL_DIR/src/radio.sh"
chmod 0644 "$INSTALL_DIR/conf/radio.json"

# ------------------------------------------------------------
# Test the stream
# ------------------------------------------------------------

echo ""
echo "Testing radio stream..."
echo ""

if curl \
    --head \
    --silent \
    --show-error \
    --location \
    --max-time 10 \
    "$STREAM_URL" >/dev/null 2>&1; then

    echo "✓ Stream URL responded."
else
    echo "✗ Could not verify the stream URL."
    echo ""
    echo "This does not necessarily mean the stream is invalid."
    echo "Some radio servers do not respond correctly to HEAD requests."
    echo ""
fi

# ------------------------------------------------------------
# Create systemd service
# ------------------------------------------------------------

echo ""
echo "Creating systemd service..."

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Internet Radio Player
Wants=network-online.target
After=network-online.target

[Service]
Type=simple

ExecStart=$INSTALL_DIR/src/radio.sh
WorkingDirectory=$INSTALL_DIR

Restart=always
RestartSec=5

Environment=HOME=$HOME

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

chmod 0644 "$SERVICE_PATH"

# ------------------------------------------------------------
# Reload systemd
# ------------------------------------------------------------

echo "Reloading systemd..."

systemctl --user daemon-reload

# ------------------------------------------------------------
# Enable service
# ------------------------------------------------------------

echo "Enabling radio service..."

systemctl --user enable radio.service

# ------------------------------------------------------------
# Enable linger
# ------------------------------------------------------------

if command -v loginctl >/dev/null 2>&1; then
    echo "Enabling user lingering..."

    sudo loginctl enable-linger "$USER"
fi

# ------------------------------------------------------------
# Start service
# ------------------------------------------------------------

echo ""
echo "Starting radio..."

if systemctl --user start radio.service; then

    sleep 2

    if systemctl --user is-active --quiet radio.service; then
        echo ""
        echo "=============================================="
        echo "       Installation Successful!"
        echo "=============================================="
        echo ""
        echo "Station:"
        echo "  $STATION_NAME"
        echo ""
        echo "Stream:"
        echo "  $STREAM_URL"
        echo ""
        echo "Volume:"
        echo "  $VOLUME%"
        echo ""
        echo "Useful commands:"
        echo ""
        echo "  Status:"
        echo "    systemctl --user status radio.service"
        echo ""
        echo "  Live logs:"
        echo "    journalctl --user -u radio.service -f"
        echo ""
        echo "  Restart:"
        echo "    systemctl --user restart radio.service"
        echo ""
        echo "  Stop:"
        echo "    systemctl --user stop radio.service"
        echo ""
        echo "  Change radio:"
        echo "    nano $INSTALL_DIR/conf/radio.json"
        echo ""
    else
        echo ""
        echo "⚠ Service started but is not currently active."
        echo ""
        echo "Check:"
        echo "  systemctl --user status radio.service"
        echo ""
        echo "Logs:"
        echo "  journalctl --user -u radio.service -n 100 --no-pager"
        echo ""
    fi

else

    echo ""
    echo "ERROR: Could not start radio.service."
    echo ""
    echo "Check:"
    echo "  systemctl --user status radio.service"
    echo ""
    echo "Logs:"
    echo "  journalctl --user -u radio.service -n 100 --no-pager"
    echo ""

    exit 1
fi
```
