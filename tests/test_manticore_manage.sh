#!/bin/bash
# shellcheck disable=SC2329  # The stubs stand in for functions of reconfigure.sh.
# reconfigure.sh --manticore enable|disable switches search on an installed
# site through docker/lib/manticore.sh, whose init container switches the
# KVS plugin with "docker compose run --build": Docker Compose has that flag
# from 2.13.0 on, so an older one is refused before anything changes, where
# enable used to stop on it once the indexes were built. And the manticore
# image is built only where Compose builds it: on a stack kvsctl installed a
# release on, docker-compose.release.yml pins the image of the release and
# clears its build section, and the build only printed Compose's "No
# services to build" warning.
# The docker CLI is a stand-in that logs every call and answers as a stack
# whose Manticore is ready; it hands "config" to the real Docker Compose,
# which renders copies of the real compose files without a daemon.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-manticore-manage.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Settings exported by the caller would hide what the files say.
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME
REAL_DOCKER=$(type -P docker) || fail 'docker is required to render the compose files'
export REAL_DOCKER TEST_CALLS="$TEST_DIR/calls"

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_CALLS"
case "$*" in
    'compose version') echo "Docker Compose version v${TEST_COMPOSE_VERSION}" ;;
    'compose --profile manticore config manticore') exec "$REAL_DOCKER" "$@" ;;
    'compose --profile manticore ps -a -q manticore') echo c0ffee ;;
    'inspect --format {{.RestartCount}} {{.State.Status}} c0ffee') echo '0 running' ;;
    # The three tables, and no build of an earlier request still running,
    # no failure recorded.
    'compose --profile manticore exec -T manticore mysql '*) printf '%s\n' example_com_videos example_com_albums example_com_searches ;;
    'compose --profile manticore exec -T manticore sh -c '* | 'compose --profile manticore exec -T manticore cat '*) exit 1 ;;
esac
exit 0
MOCK
chmod +x "$TEST_DIR/bin/docker"

# The docker directory of an installation: a copy of the real one with an
# .env. A release stack also has the override kvsctl lays with a release,
# which pins the manticore image and clears its build section as
# kvsctl-release writes it, and names it in COMPOSE_FILE. The other one
# keeps an override of its own, which kvsctl loads before the release
# override, and which builds MariaDB, a service manticore depends on.
make_stack() {
    local kind="$1" dir="$TEST_DIR/$1"

    mkdir -p "$dir"
    cp -R "$ROOT_DIR/docker/." "$dir/"
    printf '%s\n' DOMAIN=example.com SITE_PREFIX=kvs-example MARIADB_ROOT_PASSWORD=root-password \
        MARIADB_PASSWORD=site-password > "$dir/.env"
    case "$kind" in
        release | release-override)
            cat > "$dir/docker-compose.release.yml" <<EOF
services:
  manticore:
    build: !reset null
    image: "ghcr.io/example/kvs-install/manticore:26.10.0@sha256:$(printf 'a%.0s' {1..64})"
EOF
            ;;
    esac
    case "$kind" in
        release) echo 'COMPOSE_FILE=docker-compose.yml:docker-compose.release.yml' >> "$dir/.env" ;;
        release-override)
            printf '%s\n' services: '  mariadb:' '    build: ./mariadb' > "$dir/docker-compose.override.yml"
            echo 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.release.yml' >> "$dir/.env"
            ;;
    esac
}
make_stack plain
make_stack release
make_stack release-override

# manage <stack> <Compose version> <action>: manticore_manage as
# reconfigure.sh runs it, from the docker directory with .env loaded and
# its own helpers for .env, which only record here.
manage() {
    rm -f "$TEST_CALLS"
    (
        cd "$TEST_DIR/$1"
        # shellcheck source=/dev/null
        source .env
        export TEST_COMPOSE_VERSION="$2" PATH="$TEST_DIR/bin:$PATH"
        add_compose_profile() { echo "profile added: $1"; }
        remove_compose_profile() { echo "profile removed: $1"; }
        set_env_value() { echo "set: $1=$2"; }
        # shellcheck source=/dev/null
        source "$ROOT_DIR/docker/lib/manticore.sh"
        manticore_manage "$3"
    ) > "$TEST_DIR/out" 2>&1
}
called() { grep -Fxq -- "$1" "$TEST_CALLS"; }
build_call='compose --profile manticore build manticore'

# A stack that builds its images builds the manticore image first.
manage plain 5.5.1 enable || fail "enable failed on a stack that builds its images: $(cat "$TEST_DIR/out")"
called "$build_call" || fail "enable must build the manticore image of a stack that builds it: $(cat "$TEST_CALLS")"
grep -Fq 'Manticore enabled.' "$TEST_DIR/out" || fail "enable did not finish: $(cat "$TEST_DIR/out")"

# A release stack runs the image of the release: nothing to build, even
# when a service manticore depends on builds.
for stack in release release-override; do
    manage "$stack" 5.5.1 enable || fail "enable failed on a $stack stack: $(cat "$TEST_DIR/out")"
    if called "$build_call"; then
        fail "enable built the manticore image of a $stack stack, whose image the release pins: $(cat "$TEST_DIR/out")"
    fi
    called 'compose --profile manticore up -d --no-deps manticore' ||
        fail "enable did not start Manticore on a $stack stack: $(cat "$TEST_CALLS")"
    grep -Fq 'Manticore enabled.' "$TEST_DIR/out" || fail "enable did not finish on a $stack stack: $(cat "$TEST_DIR/out")"
done
echo 'PASS: enable builds the manticore image only where Compose builds it'

# A Compose without "run --build" is refused before anything changes, with
# the version found and the one needed.
for action in enable disable; do
    if manage plain 2.12.2 "$action"; then
        fail "$action accepted Docker Compose 2.12.2, which has no run --build: $(cat "$TEST_DIR/out")"
    fi
    grep -Fq "ERROR: --manticore $action needs Docker Compose 2.13.0 or newer, the first whose docker compose run takes --build; found 2.12.2. Nothing was changed." "$TEST_DIR/out" ||
        fail "the refusal of $action must name both versions: $(cat "$TEST_DIR/out")"
    [ "$(cat "$TEST_CALLS")" = 'compose version' ] ||
        fail "$action ran more than the version check on Docker Compose 2.12.2: $(cat "$TEST_CALLS")"
done
manage plain 2.13.0 disable || fail "disable failed on Docker Compose 2.13.0: $(cat "$TEST_DIR/out")"
called 'compose --profile setup run --rm --no-deps --build -T -e ENABLE_MANTICORE=false --entrypoint bash kvs-init /init/docker-entrypoint.d/80-manticore.sh' ||
    fail "disable did not switch the KVS plugin back: $(cat "$TEST_CALLS")"
grep -Fq 'Manticore disabled.' "$TEST_DIR/out" || fail "disable did not finish: $(cat "$TEST_DIR/out")"
echo 'PASS: enable and disable need the Docker Compose of run --build, and say so before anything changes'
