#!/bin/bash
# Docker integration tests for setup_radio_server.sh
#
# Usage: bash test/docker/run.sh [deps|init|all] [name-filter]
#
#   deps  install the dependencies with each distribution's real package manager
#   init  boot a container with a real init system as PID 1 and run the whole
#         lifecycle: --install, playback, crash recovery, --configure,
#         container restart (autostart at boot), --uninstall
#
# Environment:
#   JOBS=6                 how many targets run in parallel
#   RADIO_TEST_STREAM=URL  stream to play (default: test/conf/radio.json)
#   KEEP=1                 keep containers after the run (for debugging)
#
# Isolation: containers never get --privileged and never see host devices, so they
# cannot touch your sound card; audio goes to an ALSA "null" device. systemd gets
# CAP_SYS_ADMIN only to remount its own, private cgroup read-write.

set -uo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$DOCKER_DIR/../.." && pwd)"
MODE="${1:-all}"
FILTER="${2:-}"
JOBS="${JOBS:-6}"
STREAM="${RADIO_TEST_STREAM:-$(jq -r .stream_url "$REPO_DIR/test/conf/radio.json")}"
RUN_ID="$$"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/radio-docker.XXXXXX")"

# name | base image | deps: expected outcome, init: init system
DEPS_TARGETS=(
    "debian|debian:13|ok"
    "ubuntu|ubuntu:24.04|ok"
    "fedora|fedora:latest|ok"
    "rocky|rockylinux/rockylinux:9|rpmfusion"
    "arch|archlinux:latest|ok"
    "opensuse|opensuse/tumbleweed:latest|ok"
    "alpine|alpine:latest|ok"
    "void|ghcr.io/void-linux/void-glibc-full:latest|ok"
)
INIT_TARGETS=(
    "systemd-debian|debian:13|systemd"
    "openrc-alpine|alpine:latest|openrc"
    "runit-void|ghcr.io/void-linux/void-glibc-full:latest|runit"
    "dinit-artix|artixlinux/artixlinux:base-dinit|dinit"
    "openrc-artix|artixlinux/artixlinux:base-openrc|openrc"
    "runit-artix|artixlinux/artixlinux:base-runit|runit"
)

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
case "$MODE" in deps|init|all) ;; *) sed -n '2,20p' "$0"; exit 2 ;; esac

# ---------- helpers ----------

build_image() {    # build_image TAG BASE INIT
    printf 'FROM %s\nCOPY prep.sh /prep.sh\nRUN sh /prep.sh %s\n' "$2" "$3" \
        | docker build -t "$1" -f - "$DOCKER_DIR"
}

container_name() { echo "radio-test-$1-$RUN_ID"; }

cleanup() {
    [ "${KEEP:-0}" = 1 ] && return 0
    local t
    for t in "${INIT_TARGETS[@]}"; do
        docker rm -f "$(container_name "${t%%|*}")" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

wait_booted() {    # wait_booted CONTAINER INIT
    local probe _
    case "$2" in
        systemd) probe='s="$(systemctl is-system-running 2>/dev/null)"; [ "$s" = running ] || [ "$s" = degraded ]' ;;
        openrc)  probe='[ -e /run/openrc/softlevel ]' ;;
        runit)   probe='pgrep -x runsvdir >/dev/null' ;;
        dinit)   probe='[ -S /run/dinitctl ]' ;;
    esac
    for _ in $(seq 1 60); do
        if docker exec "$1" sh -c "$probe" >/dev/null 2>&1; then sleep 2; return 0; fi
        sleep 1
    done
    return 1
}

exec_as_tester() {    # exec_as_tester CONTAINER CMD...
    docker exec -u tester -e HOME=/home/tester -w /home/tester "$1" "${@:2}"
}

# ---------- jobs (output goes to $LOG_DIR/<job>.out, build logs to .build) ----------

job_deps() {    # job_deps NAME IMAGE EXPECT
    local tag="radio-test/deps-$1"
    build_image "$tag" "$2" none > "$LOG_DIR/deps-$1.build" 2>&1 \
        || { echo "  FAIL  image build (see $LOG_DIR/deps-$1.build)"; return 1; }
    docker run --rm --user tester -e HOME=/home/tester -v "$REPO_DIR:/src:ro" "$tag" \
        bash /src/test/docker/check_deps.sh "$3"
}

job_init() {    # job_init NAME IMAGE INIT
    local tag="radio-test/init-$1" c rc=0
    c="$(container_name "$1")"
    build_image "$tag" "$2" "$3" > "$LOG_DIR/init-$1.build" 2>&1 \
        || { echo "  FAIL  image build (see $LOG_DIR/init-$1.build)"; return 1; }

    local opts=(-d --name "$c" -v "$REPO_DIR:/src:ro") cmd=(/sbin/init)
    if [ "$3" = systemd ]; then
        opts+=(--cgroupns=private --cap-add SYS_ADMIN --tmpfs /run --tmpfs /run/lock)
        cmd=(sh -c 'mount -o remount,rw /sys/fs/cgroup && exec /sbin/init')
    fi
    docker run "${opts[@]}" "$tag" "${cmd[@]}" >/dev/null || { echo "  FAIL  container start"; return 1; }
    wait_booted "$c" "$3" || { echo "  FAIL  $3 did not boot"; docker logs "$c" 2>&1 | tail -n 20; return 1; }

    exec_as_tester "$c" bash /src/test/docker/check_init.sh "$3" "$STREAM" install || rc=1

    echo "== docker restart"
    docker restart -t 10 "$c" >/dev/null
    wait_booted "$c" "$3" || { echo "  FAIL  $3 did not boot after restart"; return 1; }
    exec_as_tester "$c" bash /src/test/docker/check_init.sh "$3" "$STREAM" reboot || rc=1
    return "$rc"
}

run_job() {    # run_job KIND NAME IMAGE ARG
    local id="$1-$2"
    "job_$1" "$2" "$3" "$4" > "$LOG_DIR/$id.out" 2>&1
    echo $? > "$LOG_DIR/$id.rc"
    if [ "$(cat "$LOG_DIR/$id.rc")" -eq 0 ]; then echo "  done  $id"; else echo "  FAIL  $id"; fi
}

# ---------- main ----------

selected=()
if [ "$MODE" != init ]; then for t in "${DEPS_TARGETS[@]}"; do selected+=("deps|$t"); done; fi
if [ "$MODE" != deps ]; then for t in "${INIT_TARGETS[@]}"; do selected+=("init|$t"); done; fi

echo "Logs: $LOG_DIR"
echo "Stream: $STREAM"
started=0
for s in "${selected[@]}"; do
    IFS='|' read -r kind name image arg <<<"$s"
    [[ -z "$FILTER" || "$kind-$name" == *"$FILTER"* ]] || continue
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
    echo "  start $kind-$name ($image)"
    run_job "$kind" "$name" "$image" "$arg" &
    started=$((started + 1))
done
wait
[ "$started" -gt 0 ] || { echo "No target matches '$FILTER'."; exit 2; }

echo ""
pass=0
fail=0
for rcfile in "$LOG_DIR"/*.rc; do
    id="$(basename "$rcfile" .rc)"
    echo "### $id"
    cat "$LOG_DIR/$id.out"
    echo ""
    if [ "$(cat "$rcfile")" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
done

echo "Targets: $pass passed, $fail failed  (logs: $LOG_DIR)"
for rcfile in "$LOG_DIR"/*.rc; do
    [ "$(cat "$rcfile")" -eq 0 ] || echo "  - $(basename "$rcfile" .rc)"
done
[ "$fail" -eq 0 ]
