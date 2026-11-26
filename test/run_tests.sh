#!/bin/bash
# Runs every test_* function from test/test_*.sh, each in a fresh bash process.
#
# Usage: bash test/run_tests.sh [name-filter]
#
# Nothing touches the real system: the installer is sourced inside a temporary
# sandbox (HOME and RADIO_SYS_ROOT point into it) and every system command
# (sudo, systemctl, package managers, ...) is replaced by a recording mock.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TEST_DIR")"
export TEST_DIR REPO_DIR

filter="${1:-}"
pass=0
fail=0
failed=()

command -v jq >/dev/null 2>&1 || { echo "jq is required to run the tests." >&2; exit 2; }

for suite in "$TEST_DIR"/test_*.sh; do
    echo "# $(basename "$suite")"
    tests="$(bash -c 'source "$1"; compgen -A function test_' _ "$suite")"

    for t in $tests; do
        [[ -z "$filter" || "$t" == *"$filter"* ]] || continue

        if out="$(bash -c '
                source "$TEST_DIR/lib.sh"
                source "$1"
                setup_sandbox
                trap teardown_sandbox EXIT
                "$2"
            ' _ "$suite" "$t" 2>&1)"; then
            pass=$((pass + 1))
            echo "  ok    $t"
        else
            fail=$((fail + 1))
            failed+=("$t")
            echo "  FAIL  $t"
            printf '%s\n' "$out" | sed 's/^/        /'
        fi
    done
done

echo ""
echo "$pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    printf '  - %s\n' "${failed[@]}"
    exit 1
fi
