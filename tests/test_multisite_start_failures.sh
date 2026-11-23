#!/bin/bash
# A start that fails must leave the site's cron as it found it.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/docker"
(cd "$root/docker" && cp --parents images.lock bin/resolve-bases.sh lib/kvs-php.sh init/lib/kvs-archive.sh \
    multi-site/site-manager.sh multi-site/docker-compose.site.yml.template "$work/docker")
cd "$work/docker"
manager=$PWD/multi-site/site-manager.sh
real_docker=$(type -P docker)
export work real_docker KVS_WEBROOT_BASE="$work/www" KVS_ADMIN_PASSWORD=fixture
mkdir -p kvs-archive
printf 'archive\n' | zip -q kvs-archive/KVS_media.zip -
# shellcheck disable=SC2329  # Used by the manager.
chown() { :; }
# Compose renders the site's configuration itself; the engine is this state file.
# shellcheck disable=SC2329  # Used by the manager.
docker() {
    printf '%s\n' "$*" >> "$work/calls"
    case "$*" in
        'ps --format {{.Names}}') echo kvs-caddy ;;
        'ps '*|'volume '*) return 0 ;;
        'compose --profile setup config --format json kvs-init') "$real_docker" "$@" ;;
        'compose ps --status running --quiet cron')
            [[ ! -e $work/fail-ps ]] || return 1
            if [[ $(cat "$work/cron") == running ]]; then echo 0123456789ab; fi ;;
        'compose stop cron') echo stopped > "$work/cron" ;;
        'compose up -d mariadb') if [[ -e $work/fail-db ]]; then return 42; fi ;;
        'compose exec -T mariadb healthcheck.sh --connect --innodb_initialized') return 0 ;;
        'compose --profile setup run --rm --no-deps phpmyadmin-init') return 0 ;;
        'compose --profile setup run --rm --no-deps kvs-init') if [[ -e $work/fail-init ]]; then return 43; fi ;;
        'compose start cron')
            [[ ! -e $work/fail-cron-start ]] || return 44
            echo running > "$work/cron" ;;
        'compose up -d') echo running > "$work/cron" ;;
        'exec kvs-caddy caddy reload '*) return 0 ;;
        *) echo "Unexpected Docker call: $*" >&2; return 90 ;;
    esac
}
export -f docker chown
bash "$manager" add media.example > "$work/add"

# start <cron state before> <failure markers...>: sets rc, leaves the log in $work/start.
start() {
    local marker
    echo "$1" > "$work/cron"
    shift
    rm -f "$work"/fail-*
    for marker in "$@"; do touch "$work/fail-$marker"; done
    : > "$work/calls"
    rc=0
    bash "$manager" start media.example > "$work/start" 2>&1 || rc=$?
}
expect() {
    local label=$1 status=$2 cron=$3
    [[ $rc == "$status" && $(cat "$work/cron") == "$cron" ]] ||
        { cat "$work/start"; echo "FAIL: $label: status $rc, cron $(cat "$work/cron"); expected $status, $cron"; exit 1; }
}
restarts() { grep -cFx 'compose start cron' "$work/calls" || true; }

# A cron that ran before the start runs again after MariaDB or the init fails.
start running db
expect "MariaDB failure" 42 running
grep -Fq 'cron of media.example ran before this start and has been started again' "$work/start"
if grep -Fq 'is stopped:' "$work/start"; then echo "FAIL: reported a restarted cron as stopped"; exit 1; fi
start running init
expect "init failure" 43 running
# The stop still precedes the init, and the restart follows its failure.
[[ $(grep -nFx -e 'compose stop cron' -e 'compose --profile setup run --rm --no-deps kvs-init' -e 'compose start cron' "$work/calls" |
    cut -d: -f2- | tr '\n' ';') == 'compose stop cron;compose --profile setup run --rm --no-deps kvs-init;compose start cron;' ]] ||
    { cat "$work/calls"; echo "FAIL: cron was not stopped for the init, then started"; exit 1; }

# A cron that did not run (a new site, or one the operator stopped) is not
# started behind a failed init: the notice still tells how to start it.
start stopped init
expect "cron stopped before" 43 stopped
[[ $(restarts) == 0 ]] || { echo "FAIL: started a cron that did not run before"; exit 1; }
grep -Fq 'cron of media.example is stopped:' "$work/start"

# Unknown state, or a restart that fails: the notice remains.
start running init ps
expect "state not readable" 43 stopped
[[ $(restarts) == 0 ]]
grep -Fq 'cron of media.example is stopped:' "$work/start"
start running init cron-start
expect "restart failed" 43 stopped
[[ $(restarts) == 1 ]]
grep -Fq 'cron of media.example is stopped:' "$work/start"

# A start that succeeds needs no restart of its own: "up -d" starts cron.
start running
expect "successful start" 0 running
[[ $(restarts) == 0 ]]
if grep -Fq 'cron of media.example' "$work/start"; then echo "FAIL: cron notice after a successful start"; exit 1; fi
echo "PASS: a failed start restores a cron that was running and reports one it leaves stopped"
