#!/bin/bash
# InternetRadioServer installer
#   Package managers: apt, dnf, pacman, zypper, apk, xbps, emerge
#   Init systems:     systemd, OpenRC, runit, dinit

set -euo pipefail

# Test hook: prefixes every system path the installer reads or writes
# (see test/). Never set it in normal use.
SYS_ROOT="${RADIO_SYS_ROOT:-}"

USER="${USER:-$(id -un)}"
INSTALL_DIR="$HOME/InternetRadioServer"
CONFIG="$INSTALL_DIR/conf/radio.json"
LEGACY_USER_SERVICE="$HOME/.config/systemd/user/radio.service"

SVC=radio
OS_RELEASE="$SYS_ROOT/etc/os-release"
PID1_COMM="$SYS_ROOT/proc/1/comm"
LOG_FILE="$SYS_ROOT/var/log/radio.log"
SYSTEMD_UNIT="$SYS_ROOT/etc/systemd/system/$SVC.service"
OPENRC_SCRIPT="$SYS_ROOT/etc/init.d/$SVC"
DINIT_SERVICE="$SYS_ROOT/etc/dinit.d/$SVC"
RUNIT_LOG_DIR="$SYS_ROOT/var/log/radio"

STREAM_URL=""
STATION_NAME="Internet Radio"
VOLUME=70
AMIXER_DEV=""

SUDO=""
PKG_MGR=""
NEEDS_EPEL=0
INIT=""
SV_DIR=""
RUNSVDIR=""

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
}

detect_sudo() {
    if command -v sudo >/dev/null 2>&1; then
        SUDO=sudo
    elif command -v doas >/dev/null 2>&1; then
        SUDO=doas
    else
        die "sudo or doas is required."
    fi
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

add_audio_group() {
    if id -nG "$USER" | tr ' ' '\n' | grep -qx audio; then return 0; fi
    if command -v usermod >/dev/null 2>&1; then
        $SUDO usermod -aG audio "$USER"
    else
        $SUDO addgroup "$USER" audio    # BusyBox (Alpine)
    fi
}

print_footer() {
    echo ""
    svc_hints
    echo "Configure : bash setup_radio_server.sh --configure"
}

# ---------- distro / packages ----------

detect_pkg_manager() {
    local ids="" id pair
    if [ -r "$OS_RELEASE" ]; then
        # shellcheck disable=SC1090
        ids="$(. "$OS_RELEASE" && echo "${ID:-} ${ID_LIKE:-}")"
    fi

    for id in $ids; do
        case "$id" in
            debian|ubuntu|raspbian)          PKG_MGR=apt ;;
            fedora)                          PKG_MGR=dnf ;;
            rhel|centos|rocky|almalinux|ol)  PKG_MGR=dnf; NEEDS_EPEL=1 ;;
            arch|artix)                      PKG_MGR=pacman ;;
            suse|opensuse*|sles)             PKG_MGR=zypper ;;
            alpine)                          PKG_MGR=apk ;;
            void)                            PKG_MGR=xbps ;;
            gentoo)                          PKG_MGR=emerge ;;
            *)                               continue ;;
        esac
        return 0
    done

    # Unknown distribution: fall back to whatever package manager exists
    for pair in apt-get:apt dnf:dnf pacman:pacman zypper:zypper apk:apk xbps-install:xbps emerge:emerge; do
        if command -v "${pair%%:*}" >/dev/null 2>&1; then PKG_MGR="${pair#*:}"; return 0; fi
    done

    die "Unsupported distribution. Install mpv, alsa-utils, jq and curl manually and re-run."
}

deps_present() {
    local c
    for c in mpv jq curl amixer aplay; do
        command -v "$c" >/dev/null 2>&1 || return 1
    done
}

# Packages whose commands are missing. Only those are installed, so e.g. the
# curl-minimal that RHEL-like systems ship is not replaced by "curl" (they conflict).
missing_pkgs() {
    local pkgs=()
    command -v mpv >/dev/null 2>&1 || pkgs+=(mpv)
    { command -v amixer && command -v aplay; } >/dev/null 2>&1 || pkgs+=(alsa-utils)
    command -v jq >/dev/null 2>&1 || pkgs+=(jq)
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)
    echo "${pkgs[*]}"
}

gentoo_atom() {
    case "$1" in
        mpv)        echo media-video/mpv ;;
        alsa-utils) echo media-sound/alsa-utils ;;
        jq)         echo app-misc/jq ;;
        curl)       echo net-misc/curl ;;
    esac
}

install_deps() {
    if deps_present; then
        echo "Dependencies already installed."
        return 0
    fi

    detect_pkg_manager
    local pkgs p
    read -r -a pkgs <<<"$(missing_pkgs)"
    echo "Installing dependencies ($PKG_MGR): ${pkgs[*]}"

    case "$PKG_MGR" in
        apt)
            $SUDO apt-get update
            $SUDO apt-get install -y "${pkgs[@]}"
            ;;
        dnf)
            if [ "$NEEDS_EPEL" -eq 1 ]; then $SUDO dnf install -y epel-release || true; fi
            $SUDO dnf install -y "${pkgs[@]}" || die "Package install failed. On RHEL/Rocky/Alma, mpv comes from RPM Fusion:
  $SUDO crb enable
  $SUDO dnf install -y https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-\$(rpm -E %rhel).noarch.rpm
Then re-run the installer."
            ;;
        pacman)
            # No -y: never do a partial or full system upgrade behind the user's back
            $SUDO pacman -S --needed --noconfirm "${pkgs[@]}" \
                || die "Package install failed. If packages were not found, update the system first: $SUDO pacman -Syu"
            ;;
        zypper)
            $SUDO zypper --non-interactive install "${pkgs[@]}"
            ;;
        apk)
            $SUDO apk add -U "${pkgs[@]}" \
                || die "Package install failed. mpv is in the 'community' repository; enable it in /etc/apk/repositories and re-run."
            ;;
        xbps)
            $SUDO xbps-install -Sy "${pkgs[@]}"
            ;;
        emerge)
            local atoms=()
            for p in "${pkgs[@]}"; do atoms+=("$(gentoo_atom "$p")"); done
            $SUDO emerge --noreplace "${atoms[@]}"
            ;;
    esac

    deps_present || die "Some dependencies are still missing (need: mpv, jq, curl, amixer, aplay)."
}

# ---------- init system ----------

UNSUPPORTED_INIT="Unsupported init system (supported: systemd, OpenRC, runit, dinit).
You can still run the player by hand: $INSTALL_DIR/src/radio.sh
or register that script as a service of your init system yourself.
Set RADIO_INIT=systemd|openrc|runit|dinit to override detection."

# Sets INIT (and the runit paths). Returns 1 if the init system is unknown.
detect_init() {
    local pid1=""
    [ ! -r "$PID1_COMM" ] || pid1="$(cat "$PID1_COMM" 2>/dev/null || true)"

    if [ -n "${RADIO_INIT:-}" ]; then
        INIT="$RADIO_INIT"
    elif [ -d "$SYS_ROOT/run/systemd/system" ]; then
        INIT=systemd
    elif [ -d "$SYS_ROOT/run/openrc" ] || [ "$pid1" = openrc-init ]; then
        INIT=openrc
    elif [ "$pid1" = runit ] || [ "$pid1" = runit-init ]; then
        INIT=runit
    elif [ "$pid1" = dinit ]; then
        INIT=dinit
    else
        return 1
    fi

    case "$INIT" in
        systemd|openrc|dinit) ;;
        runit)
            if [ -d "$SYS_ROOT/etc/runit/sv" ]; then    # Artix
                SV_DIR="$SYS_ROOT/etc/runit/sv"; RUNSVDIR="$SYS_ROOT/run/runit/service"
            else                                        # Void and others
                SV_DIR="$SYS_ROOT/etc/sv"; RUNSVDIR="$SYS_ROOT/var/service"
            fi
            ;;
        *) return 1 ;;
    esac
}

# --- service definitions (printed to stdout) ---

render_systemd() {
    cat <<EOF
[Unit]
Description=Internet Radio Player
Wants=network-online.target
After=network-online.target sound.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$USER
SupplementaryGroups=audio
Environment="HOME=$HOME"
WorkingDirectory=$INSTALL_DIR
ExecStart="$INSTALL_DIR/src/radio.sh"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

render_openrc() {
    cat <<EOF
#!/sbin/openrc-run
description="Internet Radio Player"

supervisor=supervise-daemon
command="$INSTALL_DIR/src/radio.sh"
command_user="$USER:audio"
directory="$INSTALL_DIR"
supervise_daemon_args="--env HOME=$HOME"
respawn_delay=5
respawn_max=0
output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() {
    use net alsasound
}
EOF
}

render_runit_run() {
    cat <<EOF
#!/bin/sh
exec 2>&1
export HOME="$HOME"
cd "$INSTALL_DIR" || exit 1
exec chpst -u "$USER:audio" "$INSTALL_DIR/src/radio.sh"
EOF
}

render_runit_finish() {
    # runsv restarts immediately; wait like the other init systems do
    printf '#!/bin/sh\nsleep 5\n'
}

render_runit_log() {
    cat <<EOF
#!/bin/sh
mkdir -p "$RUNIT_LOG_DIR"
exec svlogd -tt "$RUNIT_LOG_DIR"
EOF
}

render_dinit() {
    cat <<EOF
type = process
command = /usr/bin/env "HOME=$HOME" "$INSTALL_DIR/src/radio.sh"
working-dir = $INSTALL_DIR
run-as = $USER
restart = true
restart-delay = 5
logfile = $LOG_FILE
EOF
}

# --- service operations ---

svc_exists() {
    case "$INIT" in
        systemd) [ -f "$SYSTEMD_UNIT" ] ;;
        openrc)  [ -f "$OPENRC_SCRIPT" ] ;;
        runit)   [ -d "$SV_DIR/$SVC" ] ;;
        dinit)   [ -f "$DINIT_SERVICE" ] ;;
    esac
}

prepare_log_file() {
    $SUDO touch "$LOG_FILE"
    $SUDO chown "$USER" "$LOG_FILE"
}

svc_write() {
    case "$INIT" in
        systemd)
            render_systemd | $SUDO tee "$SYSTEMD_UNIT" >/dev/null
            ;;
        openrc)
            prepare_log_file
            render_openrc | $SUDO tee "$OPENRC_SCRIPT" >/dev/null
            $SUDO chmod 755 "$OPENRC_SCRIPT"
            ;;
        runit)
            $SUDO mkdir -p "$SV_DIR/$SVC/log"
            render_runit_run    | $SUDO tee "$SV_DIR/$SVC/run" >/dev/null
            render_runit_finish | $SUDO tee "$SV_DIR/$SVC/finish" >/dev/null
            render_runit_log    | $SUDO tee "$SV_DIR/$SVC/log/run" >/dev/null
            $SUDO chmod 755 "$SV_DIR/$SVC/run" "$SV_DIR/$SVC/finish" "$SV_DIR/$SVC/log/run"
            ;;
        dinit)
            prepare_log_file
            render_dinit | $SUDO tee "$DINIT_SERVICE" >/dev/null
            ;;
    esac
}

svc_enable_start() {
    case "$INIT" in
        systemd)
            $SUDO systemctl daemon-reload
            $SUDO systemctl enable "$SVC"
            $SUDO systemctl restart "$SVC"
            ;;
        openrc)
            $SUDO rc-update add "$SVC" default >/dev/null 2>&1 || true
            $SUDO rc-service "$SVC" restart
            ;;
        runit)
            # runsvdir picks the link up within ~5 s and starts the service
            [ -e "$RUNSVDIR/$SVC" ] || $SUDO ln -s "$SV_DIR/$SVC" "$RUNSVDIR/$SVC"
            $SUDO sv up "$RUNSVDIR/$SVC" >/dev/null 2>&1 || true
            ;;
        dinit)
            $SUDO dinitctl reload "$SVC" >/dev/null 2>&1 || true
            $SUDO dinitctl enable "$SVC" >/dev/null 2>&1 || true
            $SUDO dinitctl start "$SVC"
            ;;
    esac
}

svc_stop() {
    svc_exists || return 0
    case "$INIT" in
        systemd) $SUDO systemctl stop "$SVC" 2>/dev/null || true ;;
        openrc)  $SUDO rc-service "$SVC" stop >/dev/null 2>&1 || true ;;
        runit)   [ ! -e "$RUNSVDIR/$SVC" ] || $SUDO sv down "$RUNSVDIR/$SVC" >/dev/null 2>&1 || true ;;
        dinit)   $SUDO dinitctl stop "$SVC" >/dev/null 2>&1 || true ;;
    esac
}

svc_restart() {
    case "$INIT" in
        systemd) $SUDO systemctl restart "$SVC" ;;
        openrc)  $SUDO rc-service "$SVC" restart ;;
        runit)   $SUDO sv restart "$RUNSVDIR/$SVC" ;;
        dinit)   $SUDO dinitctl restart "$SVC" ;;
    esac
}

svc_is_active() {
    case "$INIT" in
        systemd) systemctl is-active --quiet "$SVC" ;;
        openrc)  rc-service "$SVC" status >/dev/null 2>&1 ;;
        runit)   $SUDO sv status "$RUNSVDIR/$SVC" 2>/dev/null | grep -q '^run:' ;;
        dinit)   $SUDO dinitctl status "$SVC" 2>/dev/null | grep -q 'STARTED' ;;
    esac
}

svc_wait_active() {
    local _
    sleep 2
    for _ in 1 2 3 4 5 6 7 8; do
        svc_is_active && return 0
        sleep 1
    done
    return 1
}

svc_remove() {
    svc_exists || return 0
    case "$INIT" in
        systemd)
            $SUDO systemctl disable --now "$SVC" 2>/dev/null || true
            $SUDO rm -f "$SYSTEMD_UNIT"
            $SUDO systemctl daemon-reload
            ;;
        openrc)
            $SUDO rc-service "$SVC" stop >/dev/null 2>&1 || true
            $SUDO rc-update del "$SVC" default >/dev/null 2>&1 || true
            $SUDO rm -f "$OPENRC_SCRIPT" "$LOG_FILE"
            ;;
        runit)
            if [ -e "$RUNSVDIR/$SVC" ]; then
                $SUDO sv down "$RUNSVDIR/$SVC" >/dev/null 2>&1 || true
                $SUDO sv exit "$RUNSVDIR/$SVC" >/dev/null 2>&1 || true
                $SUDO rm -f "$RUNSVDIR/$SVC"
            fi
            $SUDO rm -rf "${SV_DIR:?}/$SVC" "$RUNIT_LOG_DIR"
            ;;
        dinit)
            $SUDO dinitctl stop "$SVC" >/dev/null 2>&1 || true
            $SUDO dinitctl disable "$SVC" >/dev/null 2>&1 || true
            $SUDO rm -f "$DINIT_SERVICE" "$LOG_FILE"
            ;;
    esac
}

svc_hints() {
    case "$INIT" in
        systemd)
            echo "Status    : systemctl status $SVC"
            echo "Logs      : sudo journalctl -u $SVC -f"
            ;;
        openrc)
            echo "Status    : rc-service $SVC status"
            echo "Logs      : tail -f $LOG_FILE"
            ;;
        runit)
            echo "Status    : $SUDO sv status $RUNSVDIR/$SVC"
            echo "Logs      : $SUDO tail -f $RUNIT_LOG_DIR/current"
            ;;
        dinit)
            echo "Status    : $SUDO dinitctl status $SVC"
            echo "Logs      : tail -f $LOG_FILE"
            ;;
    esac
}

# Older versions installed a systemd *user* service with lingering
remove_legacy_user_service() {
    [ -f "$LEGACY_USER_SERVICE" ] || return 0
    echo "Removing the old per-user service..."
    if command -v systemctl >/dev/null 2>&1; then
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        systemctl --user disable --now radio.service 2>/dev/null || true
    fi
    rm -f "$LEGACY_USER_SERVICE"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "If nothing else needs it, you can disable lingering: $SUDO loginctl disable-linger \"$USER\""
}

# ---------- --install ----------

do_install() {
    check_basics
    detect_sudo
    detect_init || die "$UNSUPPORTED_INIT"

    install_deps
    echo ""

    load_config
    detect_mixer

    echo "=============================================="
    echo "       InternetRadioServer Installer"
    echo "=============================================="
    echo "Init system: $INIT"
    echo ""
    ask_settings

    # Stop old service, back up old install
    svc_stop
    remove_legacy_user_service
    if [ -d "$INSTALL_DIR" ]; then
        local backup
        backup="${INSTALL_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
        echo "Old install moved to $backup"
        mv "$INSTALL_DIR" "$backup"
    fi
    mkdir -p "$INSTALL_DIR/src" "$INSTALL_DIR/conf"

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

# If the user has a running session (PipeWire/PulseAudio), let mpv use it;
# otherwise mpv falls back to plain ALSA
RUNTIME_DIR="/run/user/$(id -u)"
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "$RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="$RUNTIME_DIR"
fi

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

# If the network is not ready, mpv exits and the service manager restarts it after 5 s
exec mpv --no-video --no-terminal --audio-display=no \
    --volume="$VOLUME" --network-timeout=15 \
    --cache=yes --cache-secs=10 \
    "$STREAM_URL"
EOF
    chmod 0755 "$INSTALL_DIR/src/radio.sh"

    check_stream
    add_audio_group

    echo "Creating $INIT service..."
    svc_write
    svc_enable_start

    echo ""
    if svc_wait_active; then
        echo "Done. Radio is playing."
    else
        echo "Installed, but the service is not running yet. Check the logs below."
    fi
    print_footer
}

# ---------- --configure ----------

do_configure() {
    check_basics
    command -v jq >/dev/null 2>&1 || die "jq not found. Run: bash setup_radio_server.sh --install"
    [ -f "$CONFIG" ] || die "No installation found. Run: bash setup_radio_server.sh --install"
    detect_sudo
    detect_init || die "$UNSUPPORTED_INIT"
    svc_exists || die "The $INIT service is not installed (older installation?). Run: bash setup_radio_server.sh --install"

    load_config
    detect_mixer

    echo "=============================================="
    echo "       InternetRadioServer Configuration"
    echo "=============================================="
    echo ""
    ask_settings

    write_config
    check_stream

    svc_restart || die "Could not restart the $SVC service."

    echo ""
    if svc_wait_active; then
        echo "Done. New settings are active."
    else
        echo "Settings saved, but the service is not running. Check the logs below."
    fi
    print_footer
}

# ---------- --uninstall ----------

do_uninstall() {
    check_basics
    detect_sudo
    if detect_init; then
        svc_remove
    else
        echo "Unknown init system, skipping service removal."
    fi
    remove_legacy_user_service
    rm -rf "$INSTALL_DIR"
    echo "Removed. Backups (${INSTALL_DIR}.backup.*) were not touched."
}

# ---------- main ----------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --install)    do_install ;;
        --configure)  do_configure ;;
        --uninstall)  do_uninstall ;;
        -h|--help|"") usage ;;
        *)            usage; exit 1 ;;
    esac
fi
