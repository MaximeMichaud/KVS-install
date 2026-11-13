#!/bin/bash
# The PHP-FPM and cron Dockerfiles install the FFmpeg packages of their build
# stage through "RUN --mount=type=bind,from=ffmpeg-build", which only
# BuildKit runs. With DOCKER_BUILDKIT=0, or without the buildx plugin, Docker
# Compose builds with the legacy builder: it compiles FFmpeg for many minutes
# and then stops on that step with "the --mount option requires BuildKit".
# The pre-flight checks now refuse both cases, before anything is changed,
# whenever the stack builds its images, and only then: a stack that runs the
# images of a kvsctl release builds none.
set -uo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kvs-buildkit-preflight.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

awk '
    $0 == "preflight_checks() {" || $0 == "preflight_kernel_writeback_status() {" ||
        $0 == "docker_is_the_snap() {" || $0 == "prompt_read() {" { capture = 1 }
    capture { print }
    capture && /^}$/ { capture = 0 }
' "$ROOT_DIR/docker/setup.sh" > "$WORK/preflight.sh"
grep -q '^preflight_checks() {' "$WORK/preflight.sh" || fail "preflight_checks is not defined in docker/setup.sh"

# The Dockerfiles this check exists for still need BuildKit.
for dockerfile in php cron; do
    grep -q '^RUN --mount=type=bind,from=ffmpeg-build,' "$ROOT_DIR/docker/${dockerfile}/Dockerfile" ||
        fail "docker/${dockerfile}/Dockerfile no longer mounts the FFmpeg packages; revisit this check"
done

# workdir <kind>: the docker directory the setup runs from. "checkout" has no
# kvsctl file, "adopted" the record of kvsctl adopt (the stack still builds
# its images), "release" the release override that clears every build.
workdir() {
    rm -rf "$WORK/root"
    mkdir -p "$WORK/root/docker"
    case "$1" in
        adopted|release)
            mkdir -p "$WORK/root/kvsctl"
            printf '{}\n' > "$WORK/root/kvsctl/state.json"
            ;;
    esac
    if [ "$1" = release ]; then
        printf 'services: {}\n' > "$WORK/root/docker/docker-compose.release.yml"
    fi
}

# preflight <kind> <buildx: present|missing> <DOCKER_BUILDKIT, "unset" for
# none> [PREFLIGHT_BYPASS] [DEV_MODE]: the checks under set -e, as the setup
# runs them, on a host whose only possible problem is BuildKit. Prints the
# output, then exit=<status>.
preflight() {
    workdir "$1"
    # shellcheck disable=SC2016
    (
        cd "$WORK/root/docker" || exit 1
        if [ "$3" = unset ]; then
            unset DOCKER_BUILDKIT
        else
            export DOCKER_BUILDKIT=$3
        fi
        bash -c '
            set -e
            source "$1"
            # shellcheck disable=SC2034
            RED="" GREEN="" YELLOW="" CYAN="" NC="" IMPORT_MODE=false HEADLESS=y
            BUILDX=$2 PREFLIGHT_BYPASS=$3 DEV_MODE=$4
            docker() {
                printf "%s\n" "$*" >> "$DOCKER_LOG"
                case "$1" in
                    --version) echo "Docker version 29.0.0, build test" ;;
                    compose) echo "Docker Compose version v2.40.0" ;;
                    buildx)
                        [ "$BUILDX" = present ] || return 1
                        echo "github.com/docker/buildx v0.30.0 test"
                        ;;
                esac
            }
            free() {
                echo "               total        used        free      shared  buff/cache   available"
                echo "Mem:            8000        1000        5000           0        2000        7000"
                echo "Swap:           2048           0        2048"
            }
            uname() { echo 7.2.9; }
            curl() { :; }
            unzip() { :; }
            ss() { :; }
            preflight_free_disk_gb() { echo "40 /"; }
            check_internet() { return 0; }
            preflight_checks
            echo "the setup went on"
        ' _ "$WORK/preflight.sh" "$2" "${4:-}" "${5:-}" 2>&1
    )
    printf '\nexit=%s\n' "$?"
}
export DOCKER_LOG="$WORK/docker.log"

# refused <reason> <preflight arguments...>
refused() {
    local reason=$1 out
    shift
    out=$(preflight "$@" < /dev/null)
    grep -qx 'exit=1' <<< "$out" || fail "$* must stop the setup, got: $out"
    grep -Fq "$reason" <<< "$out" || fail "$* must say why it stops, got: $out"
    grep -Fq 'Critical requirements missing. Cannot continue.' <<< "$out" ||
        fail "$* must be a critical failure that no bypass skips, got: $out"
    if grep -q 'the setup went on' <<< "$out"; then fail "$* must not go on"; fi
}

# accepted <expected BuildKit line, or "none"> <preflight arguments...>
accepted() {
    local line=$1 out
    shift
    out=$(preflight "$@" < /dev/null)
    grep -qx 'exit=0' <<< "$out" || fail "$* must go on, got: $out"
    grep -q 'the setup went on' <<< "$out" || fail "$* must go on, got: $out"
    if [ "$line" = none ]; then
        if grep -Eq 'buildx|BuildKit|DOCKER_BUILDKIT' <<< "$out"; then
            fail "$* builds nothing and must not check BuildKit, got: $out"
        fi
    else
        grep -Fxq "$line" <<< "$out" || fail "$* must say BuildKit is there, got: $out"
    fi
}

buildx_ok='✓ Docker buildx installed: the images build with BuildKit'
buildx_missing='✗ Docker buildx not installed: Docker Compose needs it to build the PHP-FPM and cron images with BuildKit'

# A checkout and an adopted stack build their images: buildx is required,
# whatever DOCKER_BUILDKIT says, because Compose without it does not use
# BuildKit even when asked to.
for kind in checkout adopted; do
    accepted "$buildx_ok" "$kind" present unset
    accepted "$buildx_ok" "$kind" present 1
    accepted "$buildx_ok" "$kind" present true
    for value in unset 1 true; do
        refused "$buildx_missing" "$kind" missing "$value"
    done
done
grep -Fxq 'buildx version' "$DOCKER_LOG" || fail "the check must ask the buildx plugin itself"
pass "a stack that builds its images needs the buildx plugin"

# DOCKER_BUILDKIT set to a false value, as Docker parses it, selects the
# legacy builder even with buildx installed.
for value in 0 f F false FALSE False; do
    refused "✗ DOCKER_BUILDKIT=${value} selects the legacy builder, which cannot build the PHP-FPM and cron images" \
        checkout present "$value"
done
refused '✗ DOCKER_BUILDKIT=0 selects the legacy builder' adopted present 0
pass "DOCKER_BUILDKIT=0 is refused before the build"

# Neither --dev nor PREFLIGHT_BYPASS lets a build that cannot succeed start.
refused "$buildx_missing" checkout missing unset y
refused "$buildx_missing" checkout missing unset '' true
refused '✗ DOCKER_BUILDKIT=0 selects the legacy builder' checkout present 0 y true
pass "the BuildKit check cannot be bypassed"

# The images of a kvsctl release are pulled, never built: nothing to check.
: > "$DOCKER_LOG"
accepted none release missing unset
accepted none release missing 0
accepted none release present unset
if grep -q '^buildx' "$DOCKER_LOG"; then fail "a release stack must not probe buildx"; fi
pass "a stack that runs the images of a release does not need BuildKit"
