#!/bin/bash
# Installs the dependencies with the distribution's real package manager.
# Runs inside the container as the unprivileged user "tester" (see run.sh).
#
# Usage: check_deps.sh ok|rpmfusion
#   ok         install_deps must succeed right away
#   rpmfusion  install_deps must fail with instructions (RHEL family); the printed
#              commands are then executed and install_deps must succeed

set -uo pipefail

EXPECT="$1"
# shellcheck disable=SC1091
source /src/setup_radio_server.sh
set +e

FAILS=0
pass() { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else bad "$what"; return 1; fi; }
not() { ! "$@"; }

detect_sudo
detect_pkg_manager
echo "== $(. /etc/os-release && echo "$PRETTY_NAME"), package manager: $PKG_MGR"
check "dependencies are missing before the test" not deps_present

out="$( (install_deps) 2>&1 )"
rc=$?

if [ "$EXPECT" = rpmfusion ]; then
    check "install fails while RPM Fusion is not enabled" [ "$rc" -ne 0 ]
    check "error explains how to enable RPM Fusion" grep -qF rpmfusion <<<"$out"

    echo "== running the commands from the error message"
    while IFS= read -r line; do
        echo "  \$ $line"
        # dnf asks for confirmation; answer yes like a user would
        bash -c "$line" < <(yes) > /tmp/hint.log 2>&1
        check "hint command succeeds: $line" [ $? -eq 0 ] || tail -n 5 /tmp/hint.log | sed 's/^/        /'
    done < <(sed -n 's/^  \(sudo .*\)$/\1/p' <<<"$out")

    out="$( (install_deps) 2>&1 )"
    rc=$?
fi

check "install_deps exits 0 (got $rc)" [ "$rc" -eq 0 ]
[ "$rc" -eq 0 ] || tail -n 15 <<<"$out" | sed 's/^/        /'
check "mpv, jq, curl, amixer and aplay are installed" deps_present
deps_present && echo "  $(mpv --version | head -n1)"

exit $((FAILS > 0))
