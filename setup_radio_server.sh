#!/bin/bash
# InternetRadioServer installer (Debian / Ubuntu / Raspberry Pi OS)

set -euo pipefail

INSTALL_DIR="$HOME/InternetRadioServer"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_PATH="$SERVICE_DIR/radio.service"
CONFIG="$INSTALL_DIR/conf/radio.json"

STREAM_URL=""
STATION_NAME="Internet Radio"
VOLUME=70
AMIXER_DEV=""

# ---------- helpers ----------

usage() {
    cat <<'EOF'
InternetRadioServer

Usage: bash setup_radio_server.sh <option>

Options:
  --install     Install dependencies, create the service and start the radio
  --configure   Change stream URL, station name, volume or mixer
                of an existing installation and restart the radio
  --uninstall   Remove the service and installed files
  -h, --help    Show this help
EOF
}

die() { printf '\nERROR: %s\n\n' "$1" >&2; exit 1; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

check_basics() {
    [ "$(id -u)" -ne 0 ] || die "Do not run this as root."
    command -v systemctl >/dev/null 2>&1 || die "systemd is required."
    # Needed to reach the user systemd instance in some SSH/su setups
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
}

load_config() {
    [ -f "$CONFIG" ] || return 0
    STREAM_URL="$(jq -r '.stream_url // empty' "$CONFIG" 2>/dev/null || true)"
    STATION_NAME="$(jq -r '.station_name // "Internet Radio"' "$CONFIG" 2>/dev/null || echo "$STATION_NAME")"
    VOLUME="$(jq -r '.volume // 70' "$CONFIG" 2>/dev/null || echo 70)"
    AMIXER_DEV="$(jq -r '.amixer_dev // empty' "$CONFIG" 2>/dev/null || true)"
}

detect_mixer() {
    [ -z "$AMIXER_DEV" ] || return 0
    local controls c
    controls="$(amixer scontrols 2>/dev/null | sed -n "s/.*'\(.*\)',.*/\1/p" || true)"
    for c in Master PCM Headphone Speaker; do
        if printf '%s\n' "$controls" | grep -qx "$c"; then AMIXER_DEV="$c"; return 0; fi
    done
    AMIXER_DEV="$(printf '%s\n' "$controls" | head -n1)"
}

ask_settings() {
    local input

    while true; do
        if [ -n "$STREAM_URL" ]; then
            read -r -p "Stream URL [$STREAM_URL]: " input
            input="$(trim "$input")"
            [ -n "$input" ] || input="$STREAM_URL"
        else
            read -r -p "Stream URL (http:// or https://): " input
            input="$(trim "$input")"
        fi
        if [[ "$input" =~ ^https?://[^[:space:]]+$ ]]; then STREAM_URL="$input"; break; fi
        echo "Invalid URL."
    done

    read -r -p "Station name [$STATION_NAME]: " input
    input="$(trim "$input")"
    [ -z "$input" ] || STATION_NAME="$input"

    while true; do
        read -r -p "Volume 0-100 [$VOLUME]: " input
        input="$(trim "$input")"
        [ -n "$input" ] || input="$VOLUME"
        if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -le 100 ]; then VOLUME="$input"; break; fi
        echo "Enter a number from 0 to 100."
    done

    read -r -p "ALSA mixer control [${AMIXER_DEV:-none}] ('-' to disable): " input
    input="$(trim "$input")"
    if [ "$input" = "-" ]; then AMIXER_DEV=""; elif [ -n "$input" ]; then AMIXER_DEV="$input"; fi

    echo ""
    echo "Station : $STATION_NAME"
    echo "Stream  : $STREAM_URL"
    echo "Volume  : $VOLUME%"
    echo "Mixer   : ${AMIXER_DEV:-disabled}"
    echo ""
    read -r -p "Continue? [Y/n]: " input
    if [[ "$input" =~ ^[Nn]$ ]]; then echo "Cancelled."; exit 0; fi
    echo ""
}

write_config() {
    jq -n \
        --arg name "$STATION_NAME" \
        --arg url "$STREAM_URL" \
        --argjson volume "$VOLUME" \
        --arg dev "$AMIXER_DEV" \
        '{station_name: $name, stream_url: $url, volume: $volume, amixer_dev: $dev}' \
        > "$CONFIG"
}

check_stream() {
    local code
    code="$(curl -sL --max-time 8 --range 0-2047 -o /dev/null -w '%{http_code}' "$STREAM_URL" 2>/dev/null || true)"
    case "$code" in
        200|206) echo "Stream check: OK (HTTP $code)" ;;
        *)       echo "Stream check: no valid response (HTTP ${code:-none}), continuing anyway" ;;
    esac
}

print_footer() {
    echo ""
    echo "Status    : systemctl --user status radio.service"
    echo "Logs      : journalctl --user -u radio.service -f"
    echo "Configure : bash setup_radio_server.sh --configure"
}

# ---------- --install ----------

do_install() {
    check_basics
    command -v apt-get >/dev/null 2>&1 || die "Debian/Ubuntu only (apt-get not found)."
    command -v sudo >/dev/null 2>&1 || die "sudo is required."

    echo "Installing dependencies..."
    sudo apt-get update
    sudo apt-get install -y mpv alsa-utils jq curl
    echo ""

    load_config
    detect_mixer

    echo "=============================================="
    echo "       InternetRadioServer Installer"
    echo "=============================================="
    echo ""
    ask_settings

    # Stop old service, back up old install
    systemctl --user stop radio.service 2>/dev/null || true
    if [ -d "$INSTALL_DIR" ]; then
        local backup="${INSTALL_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
        echo "Old install moved to $backup"
        mv "$INSTALL_DIR" "$backup"
    fi
    mkdir -p "$INSTALL_DIR/src" "$INSTALL_DIR/conf" "$SERVICE_DIR"

    write_config

    cat > "$INSTALL_DIR/src/radio.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$BASE_DIR/conf/radio.json"

[ -f "$CONFIG" ] || { echo "ERROR: missing $CONFIG"; exit 1; }

STATION_NAME="$(jq -r '.station_name // "Internet Radio"' "$CONFIG")"
STREAM_URL="$(jq -r '.stream_url // empty' "$CONFIG")"
VOLUME="$(jq -r '.volume // 70' "$CONFIG")"
AMIXER_DEV="$(jq -r '.amixer_dev // empty' "$CONFIG")"

[ -n "$STREAM_URL" ] || { echo "ERROR: no stream_url in $CONFIG"; exit 1; }

# Wait up to 120 s for a sound card (useful right after boot)
for _ in $(seq 1 120); do
    aplay -l 2>/dev/null | grep -q '^card' && break
    sleep 1
done

# Open the hardware mixer; loudness is set by mpv --volume
if [ -n "$AMIXER_DEV" ]; then
    amixer set "$AMIXER_DEV" 100% unmute >/dev/null 2>&1 || true
fi

echo "Station: $STATION_NAME"
echo "Stream : $STREAM_URL"
echo "Volume : $VOLUME%"

# If the network is not ready, mpv exits and systemd restarts it after 5 s
exec mpv --no-video --no-terminal --audio-display=no \
    --volume="$VOLUME" --network-timeout=15 \
    --cache=yes --cache-secs=10 \
    "$STREAM_URL"
EOF
    chmod 0755 "$INSTALL_DIR/src/radio.sh"

    check_stream

    # Audio group + lingering (start at boot without login)
    local group_changed=0
    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx audio; then
        sudo usermod -aG audio "$USER"
        group_changed=1
    fi
    sudo loginctl enable-linger "$USER"

    # network-online.target does not exist in the user manager,
    # so retries are handled by Restart=always
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Internet Radio Player

[Service]
Type=simple
ExecStart=$INSTALL_DIR/src/radio.sh
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload || die "Cannot reach the user systemd instance. Log in normally or via SSH and re-run."
    systemctl --user enable radio.service
    systemctl --user restart radio.service
    sleep 3

    echo ""
    if systemctl --user is-active --quiet radio.service; then
        echo "Done. Radio is playing."
    else
        echo "Installed, but the service is not running yet."
        echo "Check: journalctl --user -u radio.service -n 50 --no-pager"
    fi
    print_footer

    if [ "$group_changed" -eq 1 ]; then
        echo ""
        echo "You were added to the 'audio' group. If there is no sound, reboot once."
    fi
}

# ---------- --configure ----------

do_configure() {
    check_basics
    command -v jq >/dev/null 2>&1 || die "jq not found. Run: bash setup_radio_server.sh --install"
    [ -f "$CONFIG" ] || die "No installation found. Run: bash setup_radio_server.sh --install"

    load_config
    detect_mixer

    echo "=============================================="
    echo "       InternetRadioServer Configuration"
    echo "=============================================="
    echo ""
    ask_settings

    write_config
    check_stream

    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user restart radio.service || die "Could not restart radio.service."
    sleep 2

    echo ""
    if systemctl --user is-active --quiet radio.service; then
        echo "Done. New settings are active."
    else
        echo "Settings saved, but the service is not running."
        echo "Check: journalctl --user -u radio.service -n 50 --no-pager"
    fi
    print_footer
}

# ---------- --uninstall ----------

do_uninstall() {
    check_basics
    systemctl --user disable --now radio.service 2>/dev/null || true
    rm -f "$SERVICE_PATH"
    systemctl --user daemon-reload 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    echo "Removed. Backups (${INSTALL_DIR}.backup.*) were not touched."
    echo "Optional: sudo loginctl disable-linger \"$USER\""
}

# ---------- main ----------

case "${1:-}" in
    --install)    do_install ;;
    --configure)  do_configure ;;
    --uninstall)  do_uninstall ;;
    -h|--help|"") usage ;;
    *)            usage; exit 1 ;;
esac
