#!/bin/bash
# A start that fails, or that cannot run its init, must leave the site's cron as it found it.
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

# A site created before the file bind mounts the whole archive directory.
# With no archive in it, the init can only fail on a webroot it has to
# fill: start must say so while cron still runs.
site=$PWD/multi-site/sites/media.example
webroot=$work/www/media.example
legacy_compose() {
    printf 'services:\n  kvs-init:\n    image: fixture\n    volumes:\n' > "$site/docker-compose.yml"
    printf '      - %s\n' "$@" >> "$site/docker-compose.yml"
}
legacy_compose "$webroot:/var/www/kvs" ../../../kvs-archive:/kvs-archive:ro
sed -i '/^KVS_SITE_ARCHIVE=/d' "$site/.env"
rm "$site/archive.zip"
mv kvs-archive/KVS_media.zip "$work/moved.zip"
refused() {
    start running
    expect "$1" 1 running
    if grep -Fxq 'compose stop cron' "$work/calls"; then echo "FAIL: $1: cron was stopped for an init that cannot run"; exit 1; fi
    grep -Fq "No KVS archive in $PWD/kvs-archive, and $webroot holds no site yet" "$work/start" ||
        { cat "$work/start"; echo "FAIL: $1: the missing archive was not named"; exit 1; }
}
accepted() {
    start running
    expect "$1" 0 running
    grep -Fxq 'compose --profile setup run --rm --no-deps kvs-init' "$work/calls"
}
[[ -d $webroot && -z $(ls -A "$webroot") ]]
refused "empty webroot"
# Leftovers of an interrupted marker write are not a site.
touch "$webroot/.kvs-extraction-in-progress.tmp.Ab12Cd"
refused "empty webroot with a temporary marker"
rm "$webroot/.kvs-extraction-in-progress.tmp.Ab12Cd"
rmdir "$webroot"
refused "missing webroot"
# An interrupted extraction resumes from the archive, even with setup.php there.
mkdir -p "$webroot/admin/include"
touch "$webroot/admin/include/setup.php" "$webroot/.kvs-extraction-in-progress"
refused "interrupted extraction"
# An installed site needs no archive, with or without the completion marker.
rm "$webroot/.kvs-extraction-in-progress"
accepted "site installed before the markers"
touch "$webroot/.kvs-extraction-complete" "$webroot/.kvs-extraction-in-progress"
accepted "completed extraction"
# The webroot path can be a link to the site on another disk.
rm "$webroot/.kvs-extraction-complete" "$webroot/.kvs-extraction-in-progress"
mv "$webroot" "$work/disk2"
ln -s "$work/disk2" "$webroot"
accepted "installed site behind a linked webroot"
rm -r "$work/disk2"
mkdir "$work/disk2"
refused "empty linked webroot"
rm "$webroot"
rmdir "$work/disk2"
mkdir "$webroot"
# Files the init will not overwrite get its own diagnosis, not this one.
touch "$webroot/operator-file"
accepted "unmarked files"
rm "$webroot/operator-file"
# A Compose file that binds no webroot gives nothing to judge by.
legacy_compose ../../../kvs-archive:/kvs-archive:ro
accepted "no webroot bind"
# With the archive back, the empty webroot is installed from it.
legacy_compose "$webroot:/var/www/kvs" ../../../kvs-archive:/kvs-archive:ro
mv "$work/moved.zip" kvs-archive/KVS_media.zip
accepted "archive present"
echo "PASS: a failed start restores a cron that was running, and a start that lacks its archive leaves cron alone"
