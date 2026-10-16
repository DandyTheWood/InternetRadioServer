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
