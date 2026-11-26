#!/bin/bash
# Tests narrow PATH on purpose; SUDO is read by the sourced installer
# shellcheck disable=SC2034
# Service definitions and service operations for every init system

use_init() {
    RADIO_INIT="$1" detect_init
    SUDO=sudo
}

# ---------- rendered definitions ----------

test_render_systemd_unit() {
    use_init systemd
    local unit
    unit="$(render_systemd)"
    assert_contains "$unit" "User=$USER"
    assert_contains "$unit" "SupplementaryGroups=audio"
    assert_contains "$unit" "Environment=\"HOME=$HOME\""
    assert_contains "$unit" "ExecStart=\"$INSTALL_DIR/src/radio.sh\""
    assert_contains "$unit" "Restart=always"
    assert_contains "$unit" "RestartSec=5"
    assert_contains "$unit" "StartLimitIntervalSec=0"
    assert_contains "$unit" "WantedBy=multi-user.target"
    assert_not_contains "$unit" "default.target"
}

test_render_systemd_unit_passes_systemd_analyze() {
    command -v systemd-analyze >/dev/null 2>&1 || { echo "systemd-analyze not available, skipped"; return 0; }
    use_init systemd
    mkdir -p "$INSTALL_DIR/src"
    printf '#!/bin/sh\n' > "$INSTALL_DIR/src/radio.sh"
    chmod 755 "$INSTALL_DIR/src/radio.sh"
    render_systemd > "$SANDBOX/radio.service"
    run command systemd-analyze verify "$SANDBOX/radio.service"
    assert_status 0
}

test_render_openrc_script() {
    use_init openrc
    local script
    script="$(render_openrc)"
    assert_eq "$(head -n1 <<<"$script")" "#!/sbin/openrc-run"
    assert_contains "$script" "supervisor=supervise-daemon"
    assert_contains "$script" "command_user=\"$USER:audio\""
    assert_contains "$script" "--env HOME=$HOME"
    assert_contains "$script" "respawn_delay=5"
    assert_contains "$script" "respawn_max=0"
    assert_contains "$script" "output_log=\"$LOG_FILE\""
    sh -n <<<"$script" || fail "OpenRC script is not valid sh"
}

test_render_runit_scripts() {
    use_init runit
    local run_script
    run_script="$(render_runit_run)"
    assert_contains "$run_script" "exec 2>&1"
    assert_contains "$run_script" "exec chpst -u \"$USER:audio\" \"$INSTALL_DIR/src/radio.sh\""
    assert_contains "$(render_runit_finish)" "sleep 5"
    assert_contains "$(render_runit_log)" "exec svlogd -tt \"$RUNIT_LOG_DIR\""
    sh -n <<<"$run_script" || fail "runit run is not valid sh"
    sh -n <<<"$(render_runit_finish)" || fail "runit finish is not valid sh"
    sh -n <<<"$(render_runit_log)" || fail "runit log/run is not valid sh"
}

test_render_dinit_service() {
    use_init dinit
    local svc
    svc="$(render_dinit)"
    assert_contains "$svc" "type = process"
    assert_contains "$svc" "command = /usr/bin/env \"HOME=$HOME\" \"$INSTALL_DIR/src/radio.sh\""
    assert_contains "$svc" "run-as = $USER"
    assert_contains "$svc" "restart = true"
    assert_contains "$svc" "restart-delay = 5"
    assert_contains "$svc" "logfile = $LOG_FILE"
}

test_render_paths_with_spaces_are_quoted() {
    INSTALL_DIR="$SANDBOX/my home/InternetRadioServer"
    HOME="$SANDBOX/my home"

    use_init systemd
    assert_contains "$(render_systemd)" "ExecStart=\"$INSTALL_DIR/src/radio.sh\""

    use_init runit
    mkdir -p "$INSTALL_DIR/src"
    printf '#!/bin/sh\necho "radio ran in $(pwd) with HOME=$HOME"\n' > "$INSTALL_DIR/src/radio.sh"
    chmod 755 "$INSTALL_DIR/src/radio.sh"
    # Run the generated runit script with a chpst stand-in to prove the quoting works
    mkdir -p "$SANDBOX/bin"
    printf '#!/bin/sh\nshift 2\nexec "$@"\n' > "$SANDBOX/bin/chpst"
    chmod 755 "$SANDBOX/bin/chpst"
    render_runit_run > "$SANDBOX/run"
    run env PATH="$SANDBOX/bin:$PATH" sh "$SANDBOX/run"
    assert_status 0
    assert_output_contains "radio ran in $INSTALL_DIR with HOME=$HOME"
}

# ---------- write + enable ----------

test_systemd_write_and_enable() {
    use_init systemd
    svc_write
    svc_enable_start
    assert_file "$SYSTEMD_UNIT"
    assert_eq "$(cat "$SYSTEMD_UNIT")" "$(render_systemd)"
    assert_call_order "systemctl daemon-reload" "systemctl enable radio"
    assert_call_order "systemctl enable radio" "systemctl restart radio"
    assert_called "sudo systemctl enable radio"
}

test_openrc_write_and_enable() {
    use_init openrc
    svc_write
    svc_enable_start
    assert_executable "$OPENRC_SCRIPT"
    assert_file "$LOG_FILE"
    assert_eq "$(stat -c %U "$LOG_FILE")" "$USER" "log file owner"
    assert_called "rc-update add radio default"
    assert_called "rc-service radio restart"
}

test_runit_write_and_enable() {
    use_init runit
    svc_write
    svc_enable_start
    assert_executable "$SV_DIR/radio/run"
    assert_executable "$SV_DIR/radio/finish"
    assert_executable "$SV_DIR/radio/log/run"
    [ -L "$RUNSVDIR/radio" ] || fail "service link missing in $RUNSVDIR"
    assert_eq "$(readlink "$RUNSVDIR/radio")" "$SV_DIR/radio"
}

test_runit_enable_twice_keeps_single_link() {
    use_init runit
    svc_write
    svc_enable_start
    svc_enable_start
    [ ! -e "$SV_DIR/radio/radio" ] || fail "ln created a nested link inside the service dir"
}

test_dinit_write_and_enable() {
    use_init dinit
    svc_write
    svc_enable_start
    assert_file "$DINIT_SERVICE"
    assert_file "$LOG_FILE"
    assert_call_order "dinitctl reload radio" "dinitctl enable radio"
    assert_called "dinitctl start radio"
}

# ---------- status ----------

test_runit_status_parsing() {
    use_init runit
    sv() { echo "run: $2: (pid 42) 10s; run: log: (pid 41) 10s"; }
    svc_is_active || fail "run: should be active"
    sv() { echo "down: $2: 3s, normally up"; }
    if svc_is_active; then fail "down: should not be active"; fi
}

test_dinit_status_parsing() {
    use_init dinit
    dinitctl() { printf 'Service: radio\n    State: STARTED\n'; }
    svc_is_active || fail "STARTED should be active"
    dinitctl() { printf 'Service: radio\n    State: STOPPED\n'; }
    if svc_is_active; then fail "STOPPED should not be active"; fi
}

test_wait_active_gives_up() {
    use_init systemd
    mock_rc systemctl 3
    if svc_wait_active; then fail "service never became active"; fi
}

test_wait_active_succeeds_eventually() {
    use_init systemd
    systemctl() { _mock_call systemctl "$@"; [ "$(grep -c is-active "$CALLS")" -ge 3 ]; }
    svc_wait_active || fail "service became active on the 3rd check"
}

# ---------- stop / remove ----------

test_stop_and_remove_do_nothing_when_not_installed() {
    local init
    for init in systemd openrc runit dinit; do
        use_init "$init"
        svc_stop
        svc_remove
    done
    assert_no_calls    # in particular: no sudo password prompt
}

test_systemd_remove() {
    use_init systemd
    svc_write
    svc_remove
    assert_missing "$SYSTEMD_UNIT"
    assert_called "systemctl disable --now radio"
    assert_called "systemctl daemon-reload"
}

test_openrc_remove() {
    use_init openrc
    svc_write
    svc_remove
    assert_missing "$OPENRC_SCRIPT"
    assert_missing "$LOG_FILE"
    assert_called "rc-service radio stop"
    assert_called "rc-update del radio default"
}

test_runit_remove() {
    use_init runit
    svc_write
    svc_enable_start
    mkdir -p "$RUNIT_LOG_DIR"
    svc_remove
    assert_missing "$RUNSVDIR/radio"
    assert_missing "$SV_DIR/radio"
    assert_missing "$RUNIT_LOG_DIR"
    assert_call_order "sv down $RUNSVDIR/radio" "sv exit $RUNSVDIR/radio"
}

test_dinit_remove() {
    use_init dinit
    svc_write
    svc_remove
    assert_missing "$DINIT_SERVICE"
    assert_missing "$LOG_FILE"
    assert_call_order "dinitctl stop radio" "dinitctl disable radio"
}

# ---------- hints ----------

test_hints_for_every_init() {
    local init
    for init in systemd openrc runit dinit; do
        use_init "$init"
        run svc_hints
        assert_output_contains "Status    :"
        assert_output_contains "Logs      :"
    done
    use_init runit
    run svc_hints
    assert_output_contains "$RUNSVDIR/radio"
}

# ---------- legacy user service ----------

test_legacy_user_service_is_removed() {
    SUDO=sudo
    mkdir -p "$(dirname "$LEGACY_USER_SERVICE")"
    echo "[Service]" > "$LEGACY_USER_SERVICE"
    run remove_legacy_user_service
    assert_missing "$LEGACY_USER_SERVICE"
    assert_called "systemctl --user disable --now radio.service"
    assert_called "systemctl --user daemon-reload"
    assert_output_contains "disable-linger"
}

test_legacy_removal_noop_without_old_service() {
    SUDO=sudo
    run remove_legacy_user_service
    assert_eq "$OUTPUT" ""
    assert_no_calls
}

# ---------- audio group ----------

fake_groups() {
    eval "id() { if [ \"\${1:-}\" = -nG ]; then echo '$1'; else command id \"\$@\"; fi; }"
}

test_audio_group_already_member() {
    SUDO=sudo
    fake_groups "wheel audio video"
    add_audio_group
    assert_no_calls
}

test_audio_group_with_usermod() {
    SUDO=sudo
    fake_groups "wheel video"
    add_audio_group
    assert_called "usermod -aG audio $USER"
}

test_audio_group_busybox_addgroup() {
    SUDO=sudo
    fake_groups "wheel"
    unset -f usermod
    only_tools tr grep
    add_audio_group
    restore_path
    assert_called "addgroup $USER audio"
}
