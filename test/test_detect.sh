#!/bin/bash
# Tests narrow PATH on purpose; SUDO is read by the sourced installer
# shellcheck disable=SC2123
# Detection of the package manager, init system and sudo/doas

# ---------- package manager ----------

expect_pkg_manager() {    # expect_pkg_manager PKG_MGR NEEDS_EPEL ID [ID_LIKE]
    fake_os_release "$3" "${4:-}"
    PKG_MGR=""
    NEEDS_EPEL=0
    detect_pkg_manager
    assert_eq "$PKG_MGR" "$1" "PKG_MGR for ID=$3"
    assert_eq "$NEEDS_EPEL" "$2" "NEEDS_EPEL for ID=$3"
}

test_pkg_debian_family() {
    expect_pkg_manager apt 0 debian
    expect_pkg_manager apt 0 ubuntu debian
    expect_pkg_manager apt 0 raspbian debian
    expect_pkg_manager apt 0 linuxmint "ubuntu debian"
    expect_pkg_manager apt 0 pop "ubuntu debian"
}

test_pkg_fedora_has_no_epel() {
    expect_pkg_manager dnf 0 fedora
}

test_pkg_rhel_family_needs_epel() {
    expect_pkg_manager dnf 1 rhel fedora
    expect_pkg_manager dnf 1 rocky "rhel centos fedora"
    expect_pkg_manager dnf 1 almalinux "rhel centos fedora"
    expect_pkg_manager dnf 1 centos "rhel fedora"
}

test_pkg_arch_family() {
    expect_pkg_manager pacman 0 arch
    expect_pkg_manager pacman 0 manjaro arch
    expect_pkg_manager pacman 0 endeavouros arch
    expect_pkg_manager pacman 0 artix arch
}

test_pkg_others() {
    expect_pkg_manager zypper 0 opensuse-tumbleweed "opensuse suse"
    expect_pkg_manager zypper 0 opensuse-leap "suse opensuse"
    expect_pkg_manager apk 0 alpine
    expect_pkg_manager xbps 0 void
    expect_pkg_manager emerge 0 gentoo
}

test_pkg_unknown_distro_falls_back_to_installed_tool() {
    fake_os_release someos
    unset -f "${PKG_COMMANDS[@]}"
    xbps-install() { :; }
    PATH=/nonexistent
    detect_pkg_manager
    restore_path
    assert_eq "$PKG_MGR" xbps
}

test_pkg_fallback_without_os_release() {
    rm -f "$RADIO_SYS_ROOT/etc/os-release"
    unset -f "${PKG_COMMANDS[@]}"
    zypper() { :; }
    PATH=/nonexistent
    detect_pkg_manager
    restore_path
    assert_eq "$PKG_MGR" zypper
}

test_pkg_unsupported_distro_dies() {
    fake_os_release someos
    unset -f "${PKG_COMMANDS[@]}"
    PATH=/nonexistent
    run detect_pkg_manager
    restore_path
    assert_status 1
    assert_output_contains "Unsupported distribution"
}

# ---------- init system ----------

test_init_systemd() {
    fake_systemd
    detect_init
    assert_eq "$INIT" systemd
}

test_init_systemd_wins_over_openrc_dir() {
    fake_systemd
    mkdir -p "$RADIO_SYS_ROOT/run/openrc"
    detect_init
    assert_eq "$INIT" systemd
}

test_init_openrc_by_run_dir() {
    mkdir -p "$RADIO_SYS_ROOT/run/openrc"
    fake_pid1 init    # Gentoo: sysvinit as PID 1, OpenRC as service manager
    detect_init
    assert_eq "$INIT" openrc
}

test_init_openrc_init_as_pid1() {
    fake_pid1 openrc-init
    detect_init
    assert_eq "$INIT" openrc
}

test_init_runit_void_paths() {
    fake_pid1 runit
    detect_init
    assert_eq "$INIT" runit
    assert_eq "$SV_DIR" "$RADIO_SYS_ROOT/etc/sv"
    assert_eq "$RUNSVDIR" "$RADIO_SYS_ROOT/var/service"
}

test_init_runit_artix_paths() {
    fake_pid1 runit
    mkdir -p "$RADIO_SYS_ROOT/etc/runit/sv"
    detect_init
    assert_eq "$SV_DIR" "$RADIO_SYS_ROOT/etc/runit/sv"
    assert_eq "$RUNSVDIR" "$RADIO_SYS_ROOT/run/runit/service"
}

test_init_dinit() {
    fake_pid1 dinit
    detect_init
    assert_eq "$INIT" dinit
}

test_init_unknown_returns_1() {
    fake_pid1 s6-svscan
    if detect_init; then fail "detect_init should fail, got INIT=$INIT"; fi
}

test_init_override_with_env() {
    fake_systemd
    RADIO_INIT=dinit detect_init
    assert_eq "$INIT" dinit
}

test_init_override_with_invalid_value() {
    if RADIO_INIT=upstart detect_init; then fail "upstart must not be accepted"; fi
}

# ---------- sudo / doas ----------

test_sudo_preferred() {
    doas() { :; }
    detect_sudo
    assert_eq "$SUDO" sudo
}

test_doas_when_no_sudo() {
    unset -f sudo
    doas() { :; }
    PATH=/nonexistent
    detect_sudo
    restore_path
    assert_eq "$SUDO" doas
}

test_no_sudo_nor_doas_dies() {
    unset -f sudo
    PATH=/nonexistent
    run detect_sudo
    restore_path
    assert_status 1
    assert_output_contains "sudo or doas is required"
}
