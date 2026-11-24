#!/bin/bash
# A start that fails, or that cannot run its init, must leave the site's cron as it found it.
set -euo pipefail
export CADDY_TLS_MODE=internal
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/docker"
(cd "$root/docker" && cp --parents images.lock bin/resolve-bases.sh lib/host-validation.sh lib/kvs-php.sh init/lib/kvs-archive.sh \
    multi-site/site-manager.sh multi-site/docker-compose.site.yml.template "$work/docker")
cd "$work/docker"
manager=$PWD/multi-site/site-manager.sh
real_docker=$(type -P docker)
export work real_docker KVS_WEBROOT_BASE="$work/www" KVS_ADMIN_PASSWORD=fixture
mkdir -p kvs-archive
python3 "$root/tests/fixtures/kvs-prefix-archive.py" kvs-archive/KVS_media.zip
# shellcheck disable=SC2329  # Used by the manager.
chown() { :; }
# Compose renders the site's configuration itself; the engine is this state file.
# shellcheck disable=SC2329  # Used by the manager.
docker() {
    printf '%s\n' "$*" >> "$work/calls"
    case "$*" in
        'ps --format {{.Names}}') echo kvs-caddy ;;
        'inspect --format '*ACME_EMAIL*' kvs-caddy') echo ACME_EMAIL=admin@example.com ;;
        'ps '*|'volume '*) return 0 ;;
        'compose --profile setup config --format json kvs-init') "$real_docker" "$@" ;;
        'compose ps --status running --quiet cron')
            [[ ! -e $work/fail-ps ]] || return 1
            if [[ $(cat "$work/cron") == running ]]; then echo 0123456789ab; fi ;;
        'compose stop cron')
            if [[ -e $work/fail-signal ]]; then
                # Signal the manager while it waits for an external Compose
                # process. $$ is the manager even when it runs Docker from a
                # subshell that closes its lock descriptors.
                bash -c '
                    kill -s "$(cat "$work/fail-signal")" "$1"
                    sleep 0.2
                    echo stopped > "$work/cron"
                    touch "$work/stop-finished"
                ' _ "$$"
            else
                echo stopped > "$work/cron"
            fi
            if [[ -e $work/fail-stop ]]; then return 45; fi ;;
        'compose up -d mariadb')
            if [[ -n $(trap -p HUP INT TERM) ]]; then echo "Signal handlers outlived the cron stop" >&2; return 90; fi
            if [[ -e $work/fail-db ]]; then return 42; fi ;;
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
    if [[ -n ${SIGNAL:-} ]]; then echo "$SIGNAL" > "$work/fail-signal"; fi
    : > "$work/calls"
    rc=0
    env --default-signal=HUP --default-signal=INT --default-signal=TERM bash "$manager" start media.example > "$work/start" 2>&1 || rc=$?
}
expect() {
    local label=$1 status=$2 cron=$3
    [[ $rc == "$status" && $(cat "$work/cron") == "$cron" ]] ||
        { cat "$work/start"; echo "FAIL: $label: status $rc, cron $(cat "$work/cron"); expected $status, $cron"; exit 1; }
}
restarts() { grep -cFx 'compose start cron' "$work/calls" || true; }

# Stop can change the container and then fail or be interrupted.
for failure in stop HUP INT TERM; do
    case "$failure" in
        stop) status=45 ;;
        HUP) status=129 ;;
        INT) status=130 ;;
        TERM) status=143 ;;
    esac
    for initial in running stopped; do
        if [[ $failure == stop ]]; then
            start "$initial" stop
        else
            rm -f "$work/stop-finished"
            SIGNAL=$failure start "$initial"
            # A premature exit can leave the stop running after the manager.
            for ((i=0; i<200; i++)); do
                [[ ! -e $work/stop-finished ]] || break
                sleep 0.01
            done
            [[ -e $work/stop-finished ]] || { echo "The stop never finished"; exit 1; }
        fi
        expect "$initial before $failure" "$status" "$initial"
        if [[ $initial == running ]]; then
            [[ $(restarts) == 1 ]]
        else
            [[ $(restarts) == 0 ]]
        fi
        if grep -Fxq 'compose up -d mariadb' "$work/calls"; then exit 1; fi
    done
done
start running stop cron-start
expect "restart failure after a failed stop" 45 stopped
grep -Fq 'Could not restart the previously running cron' "$work/start"
grep -Fq 'docker compose start cron' "$work/start"

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

# If the state is unknown, leave cron alone.
start running init ps
expect "state not readable" 1 running
[[ $(restarts) == 0 ]]
if grep -Fxq 'compose stop cron' "$work/calls"; then exit 1; fi
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
printf '%s\n' "\$config['tables_prefix']='ktvs_';" > "$webroot/admin/include/setup.php"
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
unmarked_refused() {
    start running
    expect "$1" 1 running
    grep -Fq "The webroot $webroot contains files but has no setup.php or extraction marker" "$work/start"
    if grep -Fxq -e 'compose stop cron' -e 'compose up -d mariadb' "$work/calls"; then
        echo "FAIL: $1: a service was touched for an unmarked webroot"; exit 1
    fi
    [[ -f $webroot/operator-file ]]
}
touch "$webroot/operator-file"
unmarked_refused "unmarked files without an archive"
mv "$work/moved.zip" kvs-archive/KVS_media.zip
unmarked_refused "unmarked files with an archive directory"
legacy_compose "$webroot:/var/www/kvs" "$PWD/kvs-archive/KVS_media.zip:/kvs-archive/KVS_site.zip:ro"
unmarked_refused "unmarked files with a file bind"
# A failed listing must not masquerade as an empty directory.
(
    # shellcheck disable=SC2329  # Used by the manager.
    find() {
        if [[ $1 == "$work/www/media.example/" ]]; then return 73; fi
        command find "$@"
    }
    export -f find
    start running
    expect "unreadable contents" 1 running
    grep -Fq "Could not inspect the webroot $webroot" "$work/start"
    if grep -Fxq -e 'compose stop cron' -e 'compose up -d mariadb' "$work/calls"; then exit 1; fi
)
touch "$webroot/.kvs-extraction-in-progress"
accepted "marked partial extraction with a file bind"
rm "$webroot/.kvs-extraction-in-progress"
legacy_compose "$webroot:/var/www/kvs"
unmarked_refused "unmarked files without an archive bind"
mv kvs-archive/KVS_media.zip "$work/moved.zip"
rm "$webroot/operator-file"
# A Compose file that binds no webroot gives nothing to judge by.
legacy_compose ../../../kvs-archive:/kvs-archive:ro
accepted "no webroot bind"
# With the archive back, the empty webroot is installed from it.
legacy_compose "$webroot:/var/www/kvs" ../../../kvs-archive:/kvs-archive:ro
mv "$work/moved.zip" kvs-archive/KVS_media.zip
accepted "archive present"
echo "PASS: a failed start restores a cron that was running, and a start that lacks its archive leaves cron alone"

# Exercise the effective webroot for every archive mount layout.
webroot_failure() {
    start running
    expect "$1" 1 running
    grep -Fq "$2" "$work/start" || { cat "$work/start"; exit 1; }
    if grep -Fxq -e 'compose stop cron' -e 'compose up -d mariadb' "$work/calls"; then exit 1; fi
}
for layout in none file directory; do
    binds=("$webroot:/var/www/kvs")
    case "$layout" in
        file) binds+=("$PWD/kvs-archive/KVS_media.zip:/kvs-archive/KVS_site.zip:ro") ;;
        directory) binds+=("../../../kvs-archive:/kvs-archive:ro") ;;
    esac
    legacy_compose "${binds[@]}"
    rmdir "$webroot"
    touch "$webroot"
    webroot_failure "$layout with a regular file webroot" "Webroot $webroot is not a directory"
    rm "$webroot"
    mkdir "$webroot"
    touch "$webroot/.kvs-extraction-complete"
    webroot_failure "$layout with a stale completion marker" "Completion marker in $webroot has no setup.php"
    rm "$webroot/.kvs-extraction-complete"
    mkdir "$webroot/.kvs-extraction-complete.tmp.fixture"
    webroot_failure "$layout with an unusable temporary marker" 'temporary marker is a directory'
    rmdir "$webroot/.kvs-extraction-complete.tmp.fixture"
    touch "$webroot/.kvs-extraction-complete.tmp.fixture"
    if [[ $layout == none ]]; then
        webroot_failure "fresh webroot without a mount" "No KVS archive mount"
        touch "$webroot/.kvs-extraction-in-progress"
        webroot_failure "interrupted webroot without a mount" "No KVS archive mount"
        rm "$webroot/.kvs-extraction-in-progress"
    else
        accepted "$layout with a temporary marker file"
    fi
    mkdir -p "$webroot/admin/include"
    touch "$webroot/admin/include/setup.php"
    accepted "$layout with an installed site"
    rm -r "$webroot/admin" "$webroot/.kvs-extraction-complete.tmp.fixture"
done
