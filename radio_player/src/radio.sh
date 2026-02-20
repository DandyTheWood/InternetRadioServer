#!/bin/bash

set -euo pipefail

# Determine project base directory
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$BASE_DIR/conf/radio.json"

# Ensure config exists
if [ ! -f "$FILE" ]; then
    echo "Configuration file not found: $FILE"
    exit 1
fi

# Read values from JSON
API_URL=$(jq -r '.url // empty' "$FILE")
AMIXER_DEV=$(jq -r '.amixer_dev // empty' "$FILE")

if [[ -z "$API_URL" || -z "$AMIXER_DEV" ]]; then
    echo "Error: Missing values in radio.json"
    exit 1
fi

# Wait for ALSA device (max 120s)
for i in {1..120}; do
    if aplay -l | grep -q "^card"; then
        break
    fi
    sleep 1
done

# Set volume
amixer set "$AMIXER_DEV" 100% unmute || true

# Start radio
exec mpv --no-video --ao=alsa --cache=yes --cache-secs=10 "$API_URL"
