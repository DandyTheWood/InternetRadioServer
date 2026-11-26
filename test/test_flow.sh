#!/bin/bash
# End-to-end --install / --configure / --uninstall in the sandbox, plus the CLI

URL="https://example.com/stream.mp3"

# Answers, in prompt order: URL, station name, volume, mixer, confirm
answers() { printf '%s\n' "$@"; }

prepare_system() {    # prepare_system INIT
    deps_present() { return 0; }
    case "$1" in
        systemd) fake_systemd ;;
        openrc)  mkdir -p "$RADIO_SYS_ROOT/run/openrc" ;;
        runit)   fake_pid1 runit
                 sv() { _mock_call sv "$@"; [ "$1" != status ] || echo "run: $2: (pid 1) 5s"; } ;;
        dinit)   fake_pid1 dinit
                 dinitctl() { _mock_call dinitctl "$@"; [ "$1" != status ] || echo "State: STARTED"; } ;;
    esac
}

install_with() {    # install_with ANSWER...
    run do_install < <(answers "$@")
}

# ---------- --install ----------

test_install_systemd_end_to_end() {
    prepare_system systemd
    install_with "$URL" "My Station" 55 "" ""
    assert_status 0
    assert_output_contains "Init system: systemd"
    assert_output_contains "Done. Radio is playing."

    assert_eq "$(config_value station_name)" "My Station"
    assert_eq "$(config_value stream_url)" "$URL"
    assert_eq "$(config_value volume)" 55
    assert_eq "$(config_value amixer_dev)" Master "auto-detected mixer"

    assert_executable "$INSTALL_DIR/src/radio.sh"
    bash -n "$INSTALL_DIR/src/radio.sh" || fail "generated radio.sh has a syntax error"
    assert_file "$SYSTEMD_UNIT"
    assert_called "systemctl enable radio"
    assert_no_call_matching '^loginctl enable-linger'
}

test_install_every_init_system() {
    local init path
    for init in openrc runit dinit; do
        teardown_sandbox
        setup_sandbox
        prepare_system "$init"
        install_with "$URL" "" "" "" ""
        assert_status 0
        assert_output_contains "Init system: $init"
        assert_output_contains "Done. Radio is playing."
        case "$init" in
            openrc) path="$OPENRC_SCRIPT" ;;
            runit)  path="$RADIO_SYS_ROOT/etc/sv/radio/run" ;;
            dinit)  path="$DINIT_SERVICE" ;;
        esac
        assert_file "$path"
    done
}

test_install_unknown_init_dies_before_installing_packages() {
    deps_present() { return 1; }
    fake_os_release debian
    install_with "$URL" "" "" "" ""
    assert_status 1
    assert_output_contains "Unsupported init system"
    assert_output_contains "$INSTALL_DIR/src/radio.sh"
    assert_no_call_matching '^(apt-get|dnf|pacman|zypper|apk|xbps-install|emerge) '
    assert_missing "$INSTALL_DIR"
}

test_install_refuses_root() {
    id() { if [ "${1:-}" = -u ]; then echo 0; else command id "$@"; fi; }
    install_with "$URL" "" "" "" ""
    assert_status 1
    assert_output_contains "Do not run this as root"
    assert_no_calls
}

test_install_installs_missing_deps() {
    prepare_system systemd
    fake_os_release debian
    deps_installed_by_package_manager
    install_with "$URL" "" "" "" ""
    assert_status 0
    assert_called "apt-get install -y mpv alsa-utils jq curl"
}

test_install_validates_input() {
    prepare_system systemd
    install_with "ftp://nope" "not a url" "$URL" "" 150 abc 40 "" ""
    assert_status 0
    assert_output_contains "Invalid URL."
    assert_output_contains "Enter a number from 0 to 100."
    assert_eq "$(config_value stream_url)" "$URL"
    assert_eq "$(config_value volume)" 40
}

test_install_mixer_can_be_disabled() {
    prepare_system systemd
    install_with "$URL" "" "" "-" ""
    assert_status 0
    assert_eq "$(config_value amixer_dev)" ""
}

test_install_cancel_changes_nothing() {
    prepare_system systemd
    install_with "$URL" "" "" "" n
    assert_status 0
    assert_output_contains "Cancelled."
    assert_missing "$INSTALL_DIR"
    assert_missing "$SYSTEMD_UNIT"
}

test_install_reports_service_not_running() {
    prepare_system systemd
    systemctl() { _mock_call systemctl "$@"; [ "$1" != is-active ]; }
    install_with "$URL" "" "" "" ""
    assert_status 0
    assert_output_contains "not running yet"
    assert_output_contains "journalctl -u radio"
}

test_reinstall_backs_up_and_reuses_settings() {
    prepare_system systemd
    install_with "$URL" "Old Name" 33 "" ""
    assert_status 0
    : > "$CALLS"

    install_with "" "" "" "" ""    # accept all previous values
    assert_status 0
    assert_eq "$(config_value station_name)" "Old Name"
    assert_eq "$(config_value volume)" 33
    assert_called "systemctl stop radio"
    compgen -G "${INSTALL_DIR}.backup.*" >/dev/null || fail "no backup directory created"
    assert_output_contains "Old install moved to"
}

test_install_migrates_legacy_user_service() {
    prepare_system systemd
    mkdir -p "$(dirname "$LEGACY_USER_SERVICE")"
    echo "[Service]" > "$LEGACY_USER_SERVICE"
    install_with "$URL" "" "" "" ""
    assert_status 0
    assert_missing "$LEGACY_USER_SERVICE"
    assert_call_order "systemctl --user disable --now radio.service" "systemctl enable radio"
}

# ---------- --configure ----------

test_configure_updates_settings_and_restarts() {
    prepare_system systemd
    install_with "$URL" "Before" 50 "" ""
    : > "$CALLS"

    run do_configure < <(answers "" "After" 30 "-" "")
    assert_status 0
    assert_output_contains "New settings are active."
    assert_eq "$(config_value station_name)" "After"
    assert_eq "$(config_value volume)" 30
    assert_eq "$(config_value amixer_dev)" ""
    assert_eq "$(config_value stream_url)" "$URL"
    assert_called "systemctl restart radio"
    assert_not_called "systemctl enable radio"
}

test_configure_without_install_dies() {
    prepare_system systemd
    run do_configure < /dev/null
    assert_status 1
    assert_output_contains "No installation found"
}

test_configure_legacy_install_asks_to_reinstall() {
    prepare_system systemd
    mkdir -p "$(dirname "$CONFIG")"
    echo '{"stream_url": "https://x.example/a"}' > "$CONFIG"
    run do_configure < /dev/null
    assert_status 1
    assert_output_contains "not installed (older installation?)"
}

# ---------- --uninstall ----------

test_uninstall_removes_everything_but_backups() {
    prepare_system systemd
    install_with "$URL" "" "" "" ""
    install_with "" "" "" "" ""    # creates a backup
    : > "$CALLS"

    run do_uninstall
    assert_status 0
    assert_missing "$INSTALL_DIR"
    assert_missing "$SYSTEMD_UNIT"
    assert_called "systemctl disable --now radio"
    compgen -G "${INSTALL_DIR}.backup.*" >/dev/null || fail "backup was removed"
}

test_uninstall_with_unknown_init_still_removes_files() {
    mkdir -p "$INSTALL_DIR/conf"
    run do_uninstall
    assert_status 0
    assert_output_contains "skipping service removal"
    assert_missing "$INSTALL_DIR"
}

# ---------- CLI ----------

test_cli_help() {
    local arg
    for arg in --help -h ""; do
        run bash "$REPO_DIR/setup_radio_server.sh" $arg
        assert_status 0
        assert_output_contains "Usage: bash setup_radio_server.sh"
    done
}

test_cli_unknown_option() {
    run bash "$REPO_DIR/setup_radio_server.sh" --bogus
    assert_status 1
    assert_output_contains "Usage:"
}

test_sourcing_does_not_run_main() {
    run bash -c 'source "$1" --install && echo sourced-ok' _ "$REPO_DIR/setup_radio_server.sh"
    assert_status 0
    assert_eq "$OUTPUT" "sourced-ok"
}
