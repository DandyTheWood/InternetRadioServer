#!/bin/bash
# Tests narrow PATH on purpose; SUDO is read by the sourced installer
# shellcheck disable=SC2123,SC2034
# Dependency installation per package manager

PKGS="mpv alsa-utils jq curl"

install_on() {    # install_on ID [ID_LIKE]
    fake_os_release "$1" "${2:-}"
    deps_installed_by_package_manager
    SUDO=sudo
    run install_deps
}

test_deps_already_present_skips_package_manager() {
    deps_present() { return 0; }
    SUDO=sudo
    run install_deps
    assert_status 0
    assert_output_contains "already installed"
    assert_no_calls
}

test_deps_present_checks_every_tool() {
    PATH=/nonexistent
    mpv() { :; }; jq() { :; }; curl() { :; }; amixer() { :; }; aplay() { :; }
    deps_present || fail "all tools are present"
    unset -f aplay
    if deps_present; then fail "aplay is missing"; fi
    restore_path
}

test_deps_apt() {
    install_on debian
    assert_status 0
    assert_called "apt-get update"
    assert_called "apt-get install -y $PKGS"
    assert_call_order "apt-get update" "apt-get install -y $PKGS"
}

test_deps_fedora() {
    install_on fedora
    assert_status 0
    assert_called "dnf install -y $PKGS"
    assert_not_called "dnf install -y epel-release"
}

test_deps_rocky_enables_epel_first() {
    install_on rocky "rhel centos fedora"
    assert_status 0
    assert_call_order "dnf install -y epel-release" "dnf install -y $PKGS"
}

test_deps_rhel_failure_explains_rpm_fusion() {
    fake_os_release rocky "rhel centos fedora"
    all_deps_missing
    dnf() { _mock_call dnf "$@"; [ "$3" = epel-release ]; }
    SUDO=sudo
    run install_deps
    assert_status 1
    assert_output_contains "rpmfusion"
    assert_output_contains "sudo crb enable"
    assert_output_contains "dnf install -y https://mirrors.rpmfusion.org/"
}

test_deps_pacman_never_upgrades_system() {
    install_on arch
    assert_status 0
    assert_called "pacman -S --needed --noconfirm $PKGS"
    assert_no_call_matching '^pacman -S[a-z]*y'
}

test_deps_pacman_failure_suggests_syu() {
    fake_os_release manjaro arch
    all_deps_missing
    mock_rc pacman 1
    SUDO=sudo
    run install_deps
    assert_status 1
    assert_output_contains "pacman -Syu"
}

test_deps_zypper() {
    install_on opensuse-tumbleweed "opensuse suse"
    assert_status 0
    assert_called "zypper --non-interactive install $PKGS"
}

test_deps_apk() {
    install_on alpine
    assert_status 0
    assert_called "apk add -U $PKGS"
}

test_deps_apk_failure_mentions_community_repo() {
    fake_os_release alpine
    all_deps_missing
    mock_rc apk 1
    SUDO=sudo
    run install_deps
    assert_status 1
    assert_output_contains "community"
}

test_deps_xbps() {
    install_on void
    assert_status 0
    assert_called "xbps-install -Sy $PKGS"
}

test_deps_emerge_uses_categories() {
    install_on gentoo
    assert_status 0
    assert_called "emerge --noreplace media-video/mpv media-sound/alsa-utils app-misc/jq net-misc/curl"
}

test_deps_installs_only_missing_packages() {
    fake_os_release rocky "rhel centos fedora"
    deps_installed_by_package_manager
    missing_pkgs() { echo "mpv jq"; }
    SUDO=sudo
    run install_deps
    assert_status 0
    assert_called "dnf install -y mpv jq"
}

test_deps_emerge_only_missing_atoms() {
    fake_os_release gentoo
    deps_installed_by_package_manager
    missing_pkgs() { echo "alsa-utils"; }
    SUDO=sudo
    run install_deps
    assert_called "emerge --noreplace media-sound/alsa-utils"
}

# ---------- missing_pkgs ----------

only_commands() {    # only_commands CMD... : exactly these commands exist
    PATH=/nonexistent
    unset -f mpv jq curl amixer aplay
    local c
    for c in "$@"; do eval "$c() { :; }"; done
}

test_missing_pkgs_none() {
    only_commands mpv jq curl amixer aplay
    assert_eq "$(missing_pkgs)" ""
}

test_missing_pkgs_all() {
    only_commands
    assert_eq "$(missing_pkgs)" "mpv alsa-utils jq curl"
}

test_missing_pkgs_keeps_existing_curl() {
    # RHEL-like systems ship curl-minimal; installing "curl" would conflict with it
    only_commands curl
    assert_eq "$(missing_pkgs)" "mpv alsa-utils jq"
}

test_missing_pkgs_alsa_needs_both_tools() {
    only_commands mpv jq curl amixer
    assert_eq "$(missing_pkgs)" "alsa-utils"
}

test_deps_runs_through_sudo() {
    install_on debian
    assert_called "sudo apt-get install -y $PKGS"
}

test_deps_still_missing_after_install_dies() {
    fake_os_release debian
    all_deps_missing
    SUDO=sudo
    run install_deps
    assert_status 1
    assert_output_contains "still missing"
}
