#!/bin/bash
# Full installer lifecycle against a real init system.
# Runs inside the container as the unprivileged user "tester" (see run.sh).
#
# Usage: check_init.sh EXPECTED_INIT STREAM_URL PHASE
#   PHASE=install  --install, playback, crash recovery, --configure
#   PHASE=reboot   after a container restart: autostart at boot, then --uninstall

set -uo pipefail

EXPECT_INIT="$1"
STREAM="$2"
PHASE="$3"
INSTALLER=/src/setup_radio_server.sh
APP="$HOME/InternetRadioServer"
FAILS=0

pass() { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else bad "$what"; return 1; fi; }

wait_for() {    # wait_for SECONDS CMD...
    local i
    for ((i = 0; i < $1; i++)); do
        "${@:2}" && return 0
        sleep 1
    done
    return 1
}

# Oldest process of the player (radio.sh, or mpv after radio.sh exec'd it), as tester
player_pid() { pgrep -o -u tester -f 'InternetRadioServer/src/radio.sh|mpv --no-video' || true; }
player_running() { [ -n "$(player_pid)" ]; }
player_gone() { [ -z "$(player_pid)" ]; }
player_restarted() { local p; p="$(player_pid)"; [ -n "$p" ] && [ "$p" != "$OLD_PID" ]; }
mpv_pid() { pgrep -u tester -x mpv | head -n1 || true; }
mpv_running() { [ -n "$(mpv_pid)" ]; }

in_audio_group() {
    local gid
    gid="$(awk -F: '$1 == "audio" { print $3 }' /etc/group)"
    grep -E "^Groups:|^Gid:" "/proc/$1/status" | grep -qw "$gid"
}

service_file() {
    case "$EXPECT_INIT" in
        systemd) echo /etc/systemd/system/radio.service ;;
        openrc)  echo /etc/init.d/radio ;;
        runit)   if [ -d /etc/runit/sv ]; then echo /etc/runit/sv/radio/run; else echo /etc/sv/radio/run; fi ;;
        dinit)   echo /etc/dinit.d/radio ;;
    esac
}

service_log() {
    case "$EXPECT_INIT" in
        systemd)      sudo journalctl -u radio --no-pager 2>/dev/null ;;
        openrc|dinit) sudo cat /var/log/radio.log 2>/dev/null ;;
        runit)        sudo cat /var/log/radio/current 2>/dev/null ;;
    esac
}

log_has() { service_log | grep -qF "$1"; }

phase_install() {
    echo "== --install"
    local out
    out="$(printf '%s\n' "$STREAM" "Docker FM" 55 - "" | bash "$INSTALLER" --install 2>&1)"
    local rc=$?
    printf '%s\n' "$out" > "$HOME/install.log"
    check "--install exits 0 (got $rc)" [ "$rc" -eq 0 ]
    check "detected init system: $EXPECT_INIT" grep -qF "Init system: $EXPECT_INIT" <<<"$out"
    check "installer reports the radio is playing" grep -qF "Done. Radio is playing." <<<"$out"
    check "service definition exists: $(service_file)" [ -f "$(service_file)" ]
    check "radio.json written" [ "$(jq -r .volume "$APP/conf/radio.json")" = 55 ]

    echo "== the service"
    check "player runs as tester" wait_for 15 player_running
    local pid
    pid="$(player_pid)"
    [ -z "$pid" ] || check "player has the audio group" in_audio_group "$pid"

    echo "== playback (radio.sh waits up to 120 s for a sound card; containers have none)"
    if wait_for 200 mpv_running; then
        pass "mpv started"
        local cmd
        cmd="$(tr '\0' ' ' < "/proc/$(mpv_pid)/cmdline")"
        check "mpv volume is 55" grep -qF -- "--volume=55" <<<"$cmd"
        check "mpv plays the configured stream" grep -qF -- "$STREAM" <<<"$cmd"
        check "service log has the station name" wait_for 10 log_has "Station: Docker FM"
    else
        bad "mpv started"
        service_log | tail -n 20 | sed 's/^/        log: /'
    fi

    echo "== crash recovery"
    OLD_PID="$(player_pid)"
    if [ -n "$OLD_PID" ]; then
        sudo kill -9 "$OLD_PID"
        check "supervisor restarts the player after kill -9" wait_for 30 player_restarted
    else
        bad "no player process to kill"
    fi

    echo "== --configure"
    OLD_PID="$(player_pid)"
    out="$(printf '%s\n' "" "Docker FM 2" 30 - "" | bash "$INSTALLER" --configure 2>&1)"
    rc=$?
    check "--configure exits 0 (got $rc)" [ "$rc" -eq 0 ]
    check "configure reports new settings active" grep -qF "New settings are active." <<<"$out"
    check "volume changed to 30" [ "$(jq -r .volume "$APP/conf/radio.json")" = 30 ]
    check "player was restarted" wait_for 20 player_restarted
    [ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/        /'
}

phase_reboot() {
    echo "== after container restart"
    check "radio starts at boot without login" wait_for 60 player_running

    echo "== --uninstall"
    local out rc
    out="$(bash "$INSTALLER" --uninstall 2>&1)"
    rc=$?
    check "--uninstall exits 0 (got $rc)" [ "$rc" -eq 0 ]
    check "player stopped" wait_for 20 player_gone
    check "service definition removed" [ ! -e "$(service_file)" ]
    check "install dir removed" [ ! -e "$APP" ]
    [ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/        /'
}

case "$PHASE" in
    install) phase_install ;;
    reboot)  phase_reboot ;;
    *)       echo "unknown phase $PHASE" >&2; exit 2 ;;
esac

if [ "$FAILS" -gt 0 ] && [ -f "$HOME/install.log" ] && [ "$PHASE" = install ]; then
    echo "  --- install output ---"
    sed 's/^/        /' "$HOME/install.log"
fi
exit $((FAILS > 0))
