#!/bin/sh
# Prepares a test image (runs as root during `docker build`):
#   - sudo, bash and procps tools
#   - an unprivileged user "tester" with passwordless sudo (the installer refuses root)
#   - ALSA "null" default output, so mpv can play without a sound card
#   - with $1 = systemd|openrc|runit|dinit: make that init system boot inside a container
set -eu

INIT="${1:-none}"
. /etc/os-release

case "$ID" in
    debian|ubuntu)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y sudo procps
        [ "$INIT" != systemd ] || apt-get install -y systemd systemd-sysv dbus
        ;;
    fedora|rocky|almalinux)
        dnf install -y sudo procps-ng
        ;;
    arch|artix)
        pacman -Syu --noconfirm --needed sudo procps-ng
        ;;
    opensuse*)
        zypper --non-interactive install sudo procps shadow
        ;;
    alpine)
        # No "shadow" on purpose: the installer must cope with BusyBox addgroup
        apk add --no-cache bash sudo
        [ "$INIT" != openrc ] || apk add --no-cache openrc
        ;;
    void)
        xbps-install -Syu xbps
        xbps-install -Syu
        xbps-install -y sudo bash procps-ng
        ;;
    *)
        echo "prep.sh: unknown distribution $ID" >&2
        exit 1
        ;;
esac

if command -v useradd >/dev/null 2>&1; then
    useradd -m -s /bin/bash tester
else
    adduser -D -s /bin/bash tester
fi
echo 'tester ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers

printf 'pcm.!default { type null }\n' > /etc/asound.conf

case "$INIT" in
    systemd)
        # Nothing to log in to; keep boot quick
        systemctl mask getty.target console-getty.service systemd-logind.service >/dev/null 2>&1 || true
        ;;
    openrc)
        sed -i 's/^#\{0,1\}rc_sys=.*/rc_sys="docker"/' /etc/rc.conf
        grep -q '^rc_sys=' /etc/rc.conf || echo 'rc_sys="docker"' >> /etc/rc.conf
        echo 'rc_provide="loopback net"' >> /etc/rc.conf
        [ ! -f /etc/inittab ] || sed -i '/getty/d' /etc/inittab
        rm -f /etc/runlevels/*/agetty* /etc/runlevels/*/udev* 2>/dev/null || true
        ;;
    runit)
        rm -f /etc/runit/runsvdir/default/*getty* /etc/runit/runsvdir/default/udevd 2>/dev/null || true
        ;;
    dinit)
        # Artix's "boot" pulls in hardware services (udev, hwclock, fsck, ...) that cannot
        # work in a container; /etc/dinit.d overrides /usr/lib/dinit.d
        printf 'type = internal\nwaits-for.d = /etc/dinit.d/boot.d\n' > /etc/dinit.d/boot
        rm -f /etc/dinit.d/boot.d/* 2>/dev/null || true
        ;;
esac
