#!/bin/bash

set -e

# Init lical variables
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
FILE="$BASE_DIR/conf/radio.json"

# Read values from JSON
API_URL=$(jq -r '.url' "$FILE")
AMIXER_DEV=$(jq -r '.amixer_dev' "$FILE")

if [[ -z "$API_URL" || -z "$AMIXER_DEV" ]]; then
    echo "Error: Missing values in radio.json"
    echo "API URL: $API_URL"
    echo "AMIXER DEV: $AMIXER_DEV"
    exit 1
fi

# Wait for ALSA device
for i in {1..120}; do
    if aplay -l | grep -q "^card"; then
        break
    fi
    sleep 1
done

# Set volume to 100%
amixer set "$AMIXER_DEV" 100% unmute

# Start radio
exec mpv --no-video --ao=alsa --cache=yes --cache-secs=10 "$API_URL"
