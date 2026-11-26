#!/bin/bash
# ERR_TRAP is expanded when the trap is set on purpose
# shellcheck disable=SC2064
# Shared helpers for the test suites. Sourced by run_tests.sh, never run directly.

# ---------- sandbox ----------

# Commands the installer may run that would change the real system
MOCKED_COMMANDS=(
    systemctl rc-update rc-service sv dinitctl loginctl
    usermod addgroup
    apt-get dnf pacman zypper apk xbps-install emerge
    mpv aplay
)
PKG_COMMANDS=(apt-get dnf pacman zypper apk xbps-install emerge)

REAL_PATH="$PATH"    # tests may narrow PATH; teardown and assertions restore it
ERR_TRAP='echo "unexpected failure (exit $?) at line $LINENO: $BASH_COMMAND" >&2'

setup_sandbox() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/radio-test.XXXXXX")"
    CALLS="$SANDBOX/calls"
    : > "$CALLS"

    export HOME="$SANDBOX/home"
    export RADIO_SYS_ROOT="$SANDBOX/root"
    unset RADIO_INIT XDG_RUNTIME_DIR

    mkdir -p "$HOME" "$RADIO_SYS_ROOT"/{etc/systemd/system,etc/init.d,etc/dinit.d,etc/sv,var/service,var/log,proc/1,run}
    echo bash > "$RADIO_SYS_ROOT/proc/1/comm"    # unknown init by default

    # shellcheck disable=SC1091
    source "$REPO_DIR/setup_radio_server.sh"

    # The installer enables `set -euo pipefail`; report where a test died
    set -E
    trap "$ERR_TRAP" ERR

    install_mocks
}

teardown_sandbox() {
    PATH="$REAL_PATH"
    [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# ---------- mocks ----------

_mock_call() {
    local name="$1"
    shift
    printf '%s\n' "$name${*:+ $*}" >> "$CALLS"
}

# mock NAME... : replace commands with functions that only record their arguments
mock() {
    local n
    for n in "$@"; do
        eval "$(printf '%q() { _mock_call %q "$@"; }' "$n" "$n")"
    done
}

# mock_rc NAME RC : recording mock that returns RC
mock_rc() {
    eval "$(printf '%q() { _mock_call %q "$@"; return %d; }' "$1" "$1" "$2")"
}

install_mocks() {
    mock "${MOCKED_COMMANDS[@]}"

    # sudo records the call and runs the command (mocks, or harmless tools like tee/mkdir
    # that only ever touch the sandbox)
    sudo() { _mock_call sudo "$@"; "$@"; }

    amixer() {
        _mock_call amixer "$@"
        [ "${1:-}" != scontrols ] || echo "Simple mixer control 'Master',0"
    }
    curl() { _mock_call curl "$@"; printf 200; }
    sleep() { :; }
}

# Pretend that none of the dependencies is installed
all_deps_missing() {
    deps_present() { return 1; }
    missing_pkgs() { echo "mpv alsa-utils jq curl"; }
}

# Make package-manager mocks "install" the dependencies
deps_installed_by_package_manager() {
    all_deps_missing
    deps_present() { [ -f "$SANDBOX/deps-installed" ]; }
    local n
    for n in "${PKG_COMMANDS[@]}"; do
        eval "$(printf '%q() { _mock_call %q "$@"; touch "$SANDBOX/deps-installed"; }' "$n" "$n")"
    done
}

# ---------- fake system state ----------

fake_os_release() {    # fake_os_release ID [ID_LIKE]
    {
        echo "ID=$1"
        [ -z "${2:-}" ] || echo "ID_LIKE=\"$2\""
    } > "$RADIO_SYS_ROOT/etc/os-release"
}

fake_pid1() { echo "$1" > "$RADIO_SYS_ROOT/proc/1/comm"; }

fake_systemd() { mkdir -p "$RADIO_SYS_ROOT/run/systemd/system"; }

# Restrict PATH to a directory containing only the given real tools
only_tools() {
    local bin="$SANDBOX/bin" t
    mkdir -p "$bin"
    for t in "$@"; do ln -sf "$(command -v "$t")" "$bin/$t"; done
    PATH="$bin"
}

# ---------- assertions ----------

restore_path() { PATH="$REAL_PATH"; }

fail() {
    PATH="$REAL_PATH"
    printf 'assertion failed: %b\n' "$*" >&2
    exit 1
}

# run CMD... : capture output and exit status without aborting the test
run() {
    set +e
    trap - ERR
    OUTPUT="$("$@" 2>&1)"
    STATUS=$?
    trap "$ERR_TRAP" ERR
    set -e
}

assert_eq() {
    [ "$1" = "$2" ] || fail "expected '$2', got '$1'${3:+ ($3)}"
}

assert_status() {
    [ "$STATUS" -eq "$1" ] || fail "expected exit status $1, got $STATUS\noutput:\n$OUTPUT"
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "expected text to contain '$2'\ntext:\n$1"
}

assert_not_contains() {
    [[ "$1" != *"$2"* ]] || fail "expected text not to contain '$2'\ntext:\n$1"
}

assert_output_contains() { assert_contains "$OUTPUT" "$1"; }

assert_file() { [ -f "$1" ] || fail "missing file: $1"; }

assert_executable() { [ -x "$1" ] || fail "not executable: $1"; }

assert_missing() { [ ! -e "$1" ] && [ ! -L "$1" ] || fail "should not exist: $1"; }

assert_called() {
    grep -qxF -- "$1" "$CALLS" || fail "expected call: $1\ncalls:\n$(cat "$CALLS")"
}

assert_not_called() {
    ! grep -qxF -- "$1" "$CALLS" || fail "unexpected call: $1\ncalls:\n$(cat "$CALLS")"
}

# assert_no_call_matching REGEX : no recorded call matches the extended regex
assert_no_call_matching() {
    ! grep -qE -- "$1" "$CALLS" || fail "unexpected call matching /$1/\ncalls:\n$(cat "$CALLS")"
}

assert_no_calls() {
    [ ! -s "$CALLS" ] || fail "expected no system calls, got:\n$(cat "$CALLS")"
}

# assert_call_order A B : call A was recorded before call B
assert_call_order() {
    local a b
    a="$(grep -nxF -- "$1" "$CALLS" | head -n1 | cut -d: -f1)"
    b="$(grep -nxF -- "$2" "$CALLS" | head -n1 | cut -d: -f1)"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] \
        || fail "expected '$1' before '$2'\ncalls:\n$(cat "$CALLS")"
}

config_value() { jq -r ".$1" "$CONFIG"; }
