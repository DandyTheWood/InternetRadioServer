#!/bin/bash
# The player script (src/radio.sh), run with stand-ins for mpv, aplay and amixer

# Copy of radio.sh embedded in the installer (between the heredoc markers)
embedded_radio_sh() {
    sed -n "/cat > \"\$INSTALL_DIR\/src\/radio.sh\" <<'EOF'/,/^EOF$/p" "$REPO_DIR/setup_radio_server.sh" | sed '1d;$d'
}

# Builds an app dir with radio.sh + config, and a bin dir with fake tools
prepare_player() {    # prepare_player JSON
    APP="$SANDBOX/app"
    BIN="$SANDBOX/fakebin"
    mkdir -p "$APP/src" "$APP/conf" "$BIN"
    embedded_radio_sh > "$APP/src/radio.sh"
    chmod 755 "$APP/src/radio.sh"
    [ -z "$1" ] || printf '%s\n' "$1" > "$APP/conf/radio.json"

    cat > "$BIN/mpv" <<'EOF'
#!/bin/sh
echo "mpv-args: $*"
echo "mpv-xdg: ${XDG_RUNTIME_DIR:-unset}"
EOF
    cat > "$BIN/aplay" <<'EOF'
#!/bin/sh
echo "card 0: Fake [Fake], device 0: Fake"
EOF
    cat > "$BIN/amixer" <<EOF
#!/bin/sh
echo "\$*" >> "$SANDBOX/amixer.log"
EOF
    chmod 755 "$BIN"/*
}

play() {
    run env -u XDG_RUNTIME_DIR PATH="$BIN:$PATH" bash "$APP/src/radio.sh"
}

test_embedded_radio_sh_matches_test_copy() {
    diff <(embedded_radio_sh) "$TEST_DIR/src/radio.sh" \
        || fail "test/src/radio.sh differs from the copy inside setup_radio_server.sh"
}

test_player_runs_mpv_with_config() {
    prepare_player '{"station_name":"Test FM","stream_url":"https://example.com/s.mp3","volume":42,"amixer_dev":"PCM"}'
    play
    assert_status 0
    assert_output_contains "Station: Test FM"
    assert_output_contains "--volume=42"
    assert_output_contains "--no-video"
    assert_output_contains "https://example.com/s.mp3"
    assert_eq "$(cat "$SANDBOX/amixer.log")" "set PCM 100% unmute"
}

test_player_with_repo_test_config() {
    prepare_player ""
    cp "$TEST_DIR/conf/radio.json" "$APP/conf/radio.json"
    play
    assert_status 0
    assert_output_contains "--volume=$(jq -r .volume "$TEST_DIR/conf/radio.json")"
    assert_output_contains "$(jq -r .stream_url "$TEST_DIR/conf/radio.json")"
}

test_player_skips_mixer_when_disabled() {
    prepare_player '{"stream_url":"https://example.com/s.mp3","amixer_dev":""}'
    play
    assert_status 0
    assert_missing "$SANDBOX/amixer.log"
}

test_player_defaults() {
    prepare_player '{"stream_url":"https://example.com/s.mp3"}'
    play
    assert_status 0
    assert_output_contains "Station: Internet Radio"
    assert_output_contains "--volume=70"
}

test_player_uses_session_runtime_dir_when_present() {
    prepare_player '{"stream_url":"https://example.com/s.mp3"}'
    play
    if [ -d "/run/user/$(id -u)" ]; then
        assert_output_contains "mpv-xdg: /run/user/$(id -u)"
    else
        assert_output_contains "mpv-xdg: unset"
    fi
}

test_player_fails_without_stream_url() {
    prepare_player '{"station_name":"Nothing"}'
    play
    assert_status 1
    assert_output_contains "no stream_url"
}

test_player_fails_without_config() {
    prepare_player ""
    play
    assert_status 1
    assert_output_contains "missing"
}
