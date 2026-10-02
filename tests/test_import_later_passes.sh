#!/bin/bash
# Later passes of an import from the old server. A site directory that
# already holds an earlier pass from the same old server is not measured
# again by the exporter, on any pass. IMPORT_FILES_ONLY=yes is a pass that
# brings the site files up to date and stops there: no dump is received;
# the database, its volume, a dump an earlier run staged, .env and the
# containers stay as they are; and the pass never vouches for a dump it
# did not receive.
# shellcheck disable=SC2034,SC2329,SC2030,SC2031,SC2016
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETUP="$ROOT_DIR/docker/setup.sh"
TEST_DIR=$(mktemp -d /tmp/kvs-later-passes.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/native-import.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); echo "ok $passed - $*"; }
# provided <output>: the code under test called no function the test
# neither extracted nor stubbed.
provided() {
    if grep -F 'command not found' "$1"; then fail 'a function the test does not provide was called'; fi
}

# extract <function...>: the functions of setup.sh, with /var/www/ moved
# under the test directory.
extract() {
    local name
    for name in "$@"; do
        awk -v signature="$name() {" '$0 == signature { capture = 1 } capture { print } capture && /^}$/ { exit }' "$SETUP"
    done | sed "s|/var/www/|$TEST_DIR/www/|g"
}

# An empty site directory for example.test and the directory of the
# source records; A and B are two old servers.
fresh_destination() {
    rm -rf "$TEST_DIR/www" "$TEST_DIR/import"
    mkdir -p "$TEST_DIR/www/example.test" "$TEST_DIR/import"
}
A=ssh://root@old.test:22/var/www/site
B=ssh://root@other.test:22/var/www/site
IMPORT_MARKER_DIR="$TEST_DIR/import"
marker="$TEST_DIR/import/example.test.source"

# The exporter measures nothing with skip, and the budget otherwise.
(
    import_ssh() { printf '%s\n' "$@" > "$TEST_DIR/ssh-args"; cat > /dev/null; }
    : > "$TEST_DIR/exporter"
    import_remote_detect "$TEST_DIR/exporter" /var/www/site "$TEST_DIR/report" skip
    grep -Fxq -- --no-size "$TEST_DIR/ssh-args" || fail "skip must ask the exporter not to measure: $(tr '\n' ' ' < "$TEST_DIR/ssh-args")"
    if grep -Fxq -- --size-timeout "$TEST_DIR/ssh-args"; then fail 'skip must not pass a budget'; fi
    import_remote_detect "$TEST_DIR/exporter" /var/www/site "$TEST_DIR/report" 300
    grep -A1 -Fx -- --size-timeout "$TEST_DIR/ssh-args" | grep -Fxq 300 || fail 'a budget must reach the exporter'
    if grep -Fxq -- --no-size "$TEST_DIR/ssh-args"; then fail 'a budget must not skip the measure'; fi
)
pass 'the exporter is asked to skip the size measure, or given the budget'

# import_inspect_remote against a stub exporter: the budget it hands over
# and the tools, rewrites and take-over it asks for land in calls. It runs
# in a directory without .env.
extract import_save_nginx_config import_remote_size_text import_remote_earlier_pass import_inspect_remote > "$TEST_DIR/inspect.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/inspect.sh"
inspect() {
    local status=0

    mkdir -p "$TEST_DIR/inspect-cwd" "$TEST_DIR/logs"
    (
        cd "$TEST_DIR/inspect-cwd"
        LOG_DIR="$TEST_DIR/logs" HEADLESS=y RED='' GREEN='' YELLOW='' CYAN='' NC=''
        DOMAIN=example.test IMPORT_STAGING="$TEST_DIR/import" IMPORT_MARKER_DIR="$TEST_DIR/import"
        IMPORT_TRANSFER_JOBS=4 IMPORT_SIZE_TIMEOUT=300 IMPORT_REMOTE_PASSWORD=fixture
        IMPORT_REMOTE_HOST=old.test IMPORT_REMOTE_PORT=22 IMPORT_REMOTE_USER=root IMPORT_REMOTE_DIR=${FIXTURE_DIR-/var/www/site}
        IMPORT_SSH_KEY='' IMPORT_SSH_ACCEPT_NEW=y IMPORT_EXCLUDE='' IMPORT_INCLUDE=''
        IMPORT_DATABASE_FORMAT=auto IMPORT_REMOTE_SUDO_ERROR='' IMPORT_EXPORTER="$ROOT_DIR/kvs-export.sh"
        IMPORT_NGINX_REWRITES=${FIXTURE_REWRITES:-} IMPORT_MODE=true IMPORT_REUSE_SITE_DIR=${FIXTURE_REUSE:-}
        import_ensure_tool() { echo "tool $1" >> "$TEST_DIR/calls"; }
        import_ssh_setup() { IMPORT_SSH_TARGET=root@old.test; }
        import_ssh_close() { return 0; }
        import_remote_privileges() { IMPORT_REMOTE_PRIVILEGES=root; }
        import_remote_show_entries() { return 0; }
        import_remote_show_servers() { return 0; }
        import_remote_load_excludes() { return 0; }
        import_remote_free_space_check() { return 0; }
        import_prepare_source_nginx_rewrites() { echo rewrites >> "$TEST_DIR/calls"; }
        import_take_over_site() { echo take-over >> "$TEST_DIR/calls"; }
        import_remote_detect() {
            echo "budget $4" >> "$TEST_DIR/calls"
            printf 'kvs_export=1\nsite_dir=/var/www/site\nproject_path=/var/www/site\nkvs_version=7.0.2\n' > "$3"
            printf 'tables_prefix=ktvs_\ndb_ok=%s\nrsync=yes\ncompressor=zstd\ndomain=example.test\n' "${FIXTURE_DB_OK:-yes}" >> "$3"
        }
        : > "$TEST_DIR/calls"
        import_inspect_remote
    ) > "$TEST_DIR/inspect.out" 2>&1 || status=$?
    provided "$TEST_DIR/inspect.out"
    return "$status"
}
budget() { sed -n 's/^budget //p' "$TEST_DIR/calls"; }

# The size of a site that already holds an earlier pass from the same old
# server is not measured, on any pass.
fresh_destination
rmdir "$TEST_DIR/www/example.test"
inspect || fail "a fresh destination failed: $(cat "$TEST_DIR/inspect.out")"
[ "$(budget)" = 300 ] || fail "a fresh destination must be measured: $(budget)"
mkdir -p "$TEST_DIR/www/example.test"
printf '%s\n' "$A" > "$marker"
inspect || fail "an empty destination failed: $(cat "$TEST_DIR/inspect.out")"
[ "$(budget)" = 300 ] || fail "a destination with nothing in it must be measured: $(budget)"
echo video > "$TEST_DIR/www/example.test/video.mp4"
inspect || fail "a later pass failed: $(cat "$TEST_DIR/inspect.out")"
[ "$(budget)" = skip ] || fail "a later pass from the same source must not be measured: $(budget)"
grep -Fq 'its size is not measured' "$TEST_DIR/inspect.out" || fail 'the skipped measure must be explained'
FIXTURE_DIR='' inspect || fail "a later pass with the site directory searched failed: $(cat "$TEST_DIR/inspect.out")"
[ "$(budget)" = skip ] || fail "a later pass from the same old server, its site directory searched, must not be measured: $(budget)"
printf 'ssh://root@old.test:22/var/www/site2\n' > "$marker"
inspect && fail 'another site directory of the same old server must be refused'
[ "$(budget)" = 300 ] || fail "another site directory must be measured before it is refused: $(budget)"
printf '%s\n' "$B" > "$marker"
inspect && fail 'another old server must be refused'
[ "$(budget)" = 300 ] || fail "another old server must be measured before it is refused: $(budget)"
pass 'the size is measured unless the site directory holds an earlier pass from the same old server'

# IMPORT_FILES_ONLY: yes or no, nothing else, and never written to .env.
parse=$(awk '/^case "\$\{IMPORT_FILES_ONLY:-\}" in$/ { capture = 1 } capture { print } capture && /^esac$/ { exit }' "$SETUP")
[ -n "$parse" ] || fail 'setup.sh must read IMPORT_FILES_ONLY'
for value in y Y yes YES true; do
    [ "$(IMPORT_FILES_ONLY=$value bash -c "$parse"$'\necho "$IMPORT_FILES_ONLY"')" = yes ] || fail "'$value' must turn the pass of the files alone on"
done
for value in '' n N no NO false; do
    [ "$(IMPORT_FILES_ONLY=$value bash -c "$parse"$'\necho "$IMPORT_FILES_ONLY"')" = no ] || fail "'$value' must leave the pass of the files alone off"
done
if IMPORT_FILES_ONLY=maybe bash -c "$parse" > "$TEST_DIR/parse.out" 2>&1; then fail 'an unknown value was accepted'; fi
grep -Fq 'IMPORT_FILES_ONLY must be yes or no' "$TEST_DIR/parse.out" || fail 'an unknown value must be explained'
grep -Fq 'IMPORT_FILES_ONLY goes with IMPORT_REMOTE_HOST' "$SETUP" || fail 'the other sources must be refused'
grep -Fq 'IMPORT_FILES_ONLY receives no dump and loads none' "$SETUP" || fail 'IMPORT_REUSE_DUMP must be refused with it'
grep -Fq 'cannot be combined with IMPORT_FILES_ONLY' "$SETUP" || fail '--resume-import must refuse it'
if grep -Eq 'set_env_value[^#]*IMPORT_FILES_ONLY' "$SETUP"; then fail 'IMPORT_FILES_ONLY must never reach .env'; fi
grep -Fq 'IMPORT_FILES_ONLY=yes Bring the site files up to date' "$SETUP" || fail 'the usage must document IMPORT_FILES_ONLY'
pass 'IMPORT_FILES_ONLY is yes or no, with the old server only, and documented'

# The pass ends before anything that writes .env, picks images, stops
# containers or deletes a volume: right after the domain is known.
branch=$(grep -n '^    import_files_only$' "$SETUP" | cut -d: -f1)
[ -n "$branch" ] || fail 'the main flow must run import_files_only'
sed -n "$((branch - 1))p;$((branch + 1))p" "$SETUP" | tr '\n' ' ' | grep -Fq 'if [ "$IMPORT_FILES_ONLY" = yes ]; then     exit 0' ||
    fail 'the pass of the files alone must exit right after it'
for later in '^PREVIOUS_DOMAIN=\$\(sed' '^set_env_value DOMAIN "\$DOMAIN"$' '^select_import_source$' '^import_require_empty_volume$' \
    'docker compose down 2>/dev/null' '^import_fetch_source$' '^import_stage_dump$'; do
    line=$(grep -En -- "$later" "$SETUP" | head -n 1 | cut -d: -f1)
    [ -n "$line" ] && [ "$line" -gt "$branch" ] || fail "the pass of the files alone must end before '$later'"
done
validated=$(grep -n 'ERROR: Invalid domain format: \$DOMAIN' "$SETUP" | tail -n 1 | cut -d: -f1)
[ "$validated" -lt "$branch" ] || fail 'the domain must be validated before the pass of the files alone'
pass 'the pass of the files alone ends before .env, the images, the containers and the volume are touched'

# A dump an earlier run staged next to the record, whole.
make_dump() {
    mkdir -p "$TEST_DIR/import"
    {
        echo 'CREATE TABLE `ktvs_options` (`variable` varchar(64));'
        echo '-- Dump completed on 2026-10-02'
    } | gzip > "$TEST_DIR/import/example.test.sql.gz"
}
# reuse: whether a later pass with IMPORT_REUSE_DUMP=yes takes that dump.
reuse() {
    import_reuse_dump "$TEST_DIR/import/example.test.sql.gz" "$TEST_DIR/www/example.test" "$1" ktvs_ > "$TEST_DIR/reuse.out" 2>&1
}

# A run of source A received its dump, recorded A, and stopped during the
# files: the pass of the files alone keeps the record as it is, and the
# dump stays reusable.
fresh_destination
make_dump
touch -d '2 minutes ago' "$TEST_DIR/import/example.test.sql.gz"
printf '%s\n' "$A" > "$marker"
touch -d '1 minute ago' "$marker"
before=$(stat -c %Y "$marker")
import_mark_destination_files_only "$TEST_DIR/www/example.test" "$A" "$TEST_DIR/import/example.test"
[ "$(cat "$marker")" = "$A" ] && [ "$(stat -c %Y "$marker")" = "$before" ] || fail 'the record of the same source must keep its time'
reuse "$A" || fail "a dump received before the record must stay reusable: $(cat "$TEST_DIR/reuse.out")"
pass 'the record of the same source keeps its time and its dump stays reusable'

# A dump newer than the record came from a run that stopped between its
# dump and its record, possibly one pointed at another old server: the
# pass of the files alone must not make it look older than the record.
fresh_destination
printf '%s\n' "$A" > "$marker"
touch -d '2 minutes ago' "$marker"
make_dump
reuse "$A" && fail 'the fixture dump must start out refused'
import_mark_destination_files_only "$TEST_DIR/www/example.test" "$A" "$TEST_DIR/import/example.test"
if reuse "$A"; then fail 'the pass of the files alone vouched for a dump it did not receive'; fi
grep -Fq 'arrived after the last import' "$TEST_DIR/reuse.out" || fail "missing reason: $(cat "$TEST_DIR/reuse.out")"
# The plain record, written now, would have let that dump through.
import_mark_destination "$TEST_DIR/www/example.test" "$A"
reuse "$A" || fail 'the fixture must show what a plain record lets through'
pass 'a dump newer than the record stays refused after the pass of the files alone'

# No record yet, or the record of another source over an empty directory:
# the new record is dated before the dumps staged here.
for previous in none "$B"; do
    fresh_destination
    [ "$previous" = none ] || printf '%s\n' "$previous" > "$marker"
    make_dump
    touch -d '1 hour ago' "$TEST_DIR/import/example.test.sql.gz"
    import_mark_destination_files_only "$TEST_DIR/www/example.test" "$A" "$TEST_DIR/import/example.test"
    [ "$(cat "$marker")" = "$A" ] || fail "the record must name the source after $previous"
    [ "$marker" -ot "$TEST_DIR/import/example.test.sql.gz" ] || fail "a new record must be older than the staged dump (after $previous)"
    if reuse "$A"; then fail "a dump staged before the first record of A was taken as A's (after $previous)"; fi
done
fresh_destination
rm -rf "$TEST_DIR/www/example.test"
import_mark_destination_files_only "$TEST_DIR/www/example.test" "$A" "$TEST_DIR/import/example.test"
[ -d "$TEST_DIR/www/example.test" ] && [ "$(cat "$marker")" = "$A" ] || fail 'a new destination must get its record'
[ "$(($(date +%s) - $(stat -c %Y "$marker")))" -lt 60 ] || fail 'without a staged dump the record is dated now'
pass 'a new record is dated before the dumps staged next to it'

# import_fetch_remote with IMPORT_FILES_ONLY=yes: no dump, the staged one
# untouched, the files transferred, nothing set for a database load.
extract import_fetch_remote > "$TEST_DIR/fetch.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/fetch.sh"
(
    DOMAIN=example.test IMPORT_STAGING="$TEST_DIR/import" LOG_DIR="$TEST_DIR/logs"
    IMPORT_REMOTE_COMPRESSOR=gzip IMPORT_REMOTE_DATABASE_FORMAT=directory IMPORT_DATABASE_FORMAT=directory IMPORT_REMOTE_PORT=22
    IMPORT_REMOTE_DIR=/var/www/site IMPORT_REMOTE_RSYNC=yes IMPORT_EXPORTER=unused
    IMPORT_SSH_TARGET=root@old.test IMPORT_EXCLUDE_PATTERNS=() IMPORT_FILES_ONLY=yes IMPORT_REUSE_DUMP=no
    RED='' GREEN='' CYAN='' NC='' IMPORT_DB_DUMP='' IMPORT_RAW_DUMP='' IMPORT_SITE_DIR=''
    mkdir -p "$LOG_DIR"
    fresh_destination
    printf '%s\n' "$A" > "$marker"
    touch -d '1 minute ago' "$marker"
    make_dump
    cp "$TEST_DIR/import/example.test.sql.gz" "$TEST_DIR/staged.copy"
    import_native_target_supported() { return 1; }
    import_remote_dump() { echo dump >> "$TEST_DIR/calls"; }
    import_ssh_close() { return 0; }
    import_remote_files() { echo "files $2" >> "$TEST_DIR/calls"; echo video > "$2/video.mp4"; }
    : > "$TEST_DIR/calls"
    import_fetch_remote > "$TEST_DIR/fetch.out" 2>&1 || fail "the pass of the files alone failed: $(cat "$TEST_DIR/fetch.out")"
    provided "$TEST_DIR/fetch.out"
    [ "$(cat "$TEST_DIR/calls")" = "files $TEST_DIR/www/example.test" ] || fail "only the files may travel: $(cat "$TEST_DIR/calls")"
    cmp -s "$TEST_DIR/import/example.test.sql.gz" "$TEST_DIR/staged.copy" || fail 'the staged dump changed'
    [ -f "$TEST_DIR/www/example.test/video.mp4" ] || fail 'the files did not arrive'
    [ -z "$IMPORT_DB_DUMP$IMPORT_RAW_DUMP$IMPORT_SITE_DIR" ] || fail 'a pass of the files alone must not prepare a database load'
    grep -Fq 'No dump in a pass of the files alone' "$TEST_DIR/fetch.out" || fail 'the missing dump must be explained'
    if grep -Fq 'native directory import requires MariaDB 11.8' "$TEST_DIR/fetch.out"; then fail 'the database format must not matter without a dump'; fi
    [ "$(stat -c %Y "$marker")" -lt "$(($(date +%s) - 30))" ] || fail 'the record of the same source must keep its time'
    # The same function still exports a dump first on a full pass.
    : > "$TEST_DIR/calls"
    IMPORT_FILES_ONLY=no IMPORT_REMOTE_DATABASE_FORMAT=sql
    import_remote_dump() { echo dump >> "$TEST_DIR/calls"; printf 'new export\n' > "$3"; }
    import_fetch_remote > "$TEST_DIR/fetch.out" 2>&1 || fail "a full pass failed: $(cat "$TEST_DIR/fetch.out")"
    provided "$TEST_DIR/fetch.out"
    [ "$(paste -sd' ' "$TEST_DIR/calls")" = "dump files $TEST_DIR/www/example.test" ] || fail "a full pass must dump first: $(cat "$TEST_DIR/calls")"
)
pass 'the transfer of a pass of the files alone receives no dump and keeps the staged one'

# import_files_only from the inspection to the report, with the containers
# of the installation running: only docker ps is asked, .env stays as it
# is, the completed import and the running copy are pointed out.
extract import_files_only > "$TEST_DIR/files-only.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/files-only.sh"
(
    cd "$TEST_DIR"
    DOMAIN=example.test HEADLESS=y RED='' GREEN='' YELLOW='' CYAN='' NC=''
    IMPORT_DATABASE_FORMAT_REQUEST=auto IMPORT_LIB=unused
    printf 'DOMAIN=example.test\nCOMPOSE_PROJECT_NAME=kvs-example-test\nKVS_IMPORT_COMPLETED=2026-10-01T10:00:00Z\n' > .env
    cp .env env.copy
    import_inspect_remote() { echo inspect >> "$TEST_DIR/calls"; }
    import_fetch_remote() { echo fetch >> "$TEST_DIR/calls"; }
    docker() {
        echo "docker $*" >> "$TEST_DIR/docker-calls"
        [ "$1" = ps ] || return 1
        [ "${FIXTURE_RUNNING:-no}" = no ] || echo 0123456789ab
    }
    : > "$TEST_DIR/calls"
    : > "$TEST_DIR/docker-calls"
    FIXTURE_RUNNING=yes import_files_only > "$TEST_DIR/files-only.out" 2>&1 || fail "the pass failed: $(cat "$TEST_DIR/files-only.out")"
    provided "$TEST_DIR/files-only.out"
    [ "$(paste -sd' ' "$TEST_DIR/calls")" = 'inspect fetch' ] || fail "the pass must inspect then fetch: $(cat "$TEST_DIR/calls")"
    if grep -v '^docker ps -q --filter label=com.docker.compose.project=kvs-example-test$' "$TEST_DIR/docker-calls"; then
        fail 'the pass of the files alone may only look at the containers'
    fi
    cmp -s .env env.copy || fail '.env changed'
    grep -Fq 'An import completed here on 2026-10-01T10:00:00Z' "$TEST_DIR/files-only.out" || fail 'the completed import must be pointed out'
    grep -Fq 'Never run this once the site is live here' "$TEST_DIR/files-only.out" || fail 'the risk after the cutover must be spelled out'
    grep -Fq 'no dump was received, the database and the containers were left as they were' "$TEST_DIR/files-only.out" || fail 'missing report'
    grep -Fq 'The containers of kvs-example-test still run on these files' "$TEST_DIR/files-only.out" || fail 'the running copy must be pointed out'
    : > "$TEST_DIR/calls"
    FIXTURE_RUNNING=no import_files_only > "$TEST_DIR/files-only.out" 2>&1
    provided "$TEST_DIR/files-only.out"
    if grep -Fq 'still run on these files' "$TEST_DIR/files-only.out"; then fail 'no running copy, no warning'; fi
    # Another domain's installation: its completion and its containers are not this site's.
    : > "$TEST_DIR/calls"
    DOMAIN=other.test FIXTURE_RUNNING=yes import_files_only > "$TEST_DIR/files-only.out" 2>&1
    provided "$TEST_DIR/files-only.out"
    if grep -Eq 'An import completed here|still run on these files' "$TEST_DIR/files-only.out"; then
        fail "another domain's installation was taken for this one"
    fi
    # Interactive runs confirm first; no stops before the transfer.
    : > "$TEST_DIR/calls"
    unset HEADLESS
    (import_files_only < <(echo n)) > "$TEST_DIR/files-only.out" 2>&1 || fail 'a cancelled pass must end quietly'
    provided "$TEST_DIR/files-only.out"
    grep -Fq 'Cancelled.' "$TEST_DIR/files-only.out" || fail "a cancelled pass must say so: $(cat "$TEST_DIR/files-only.out")"
    [ "$(cat "$TEST_DIR/calls")" = inspect ] || fail "a cancelled pass must not transfer: $(cat "$TEST_DIR/calls")"
)
pass 'the pass of the files alone reports, looks at the containers only, and keeps .env'

# The inspection of a pass of the files alone: no take-over, no source
# rewrites, no database needed.
fresh_destination
printf '%s\n' "$A" > "$marker"
echo video > "$TEST_DIR/www/example.test/video.mp4"
FIXTURE_DB_OK=no inspect && fail 'a full pass must refuse a database that does not answer'
IMPORT_FILES_ONLY=yes FIXTURE_DB_OK=no inspect || fail "a pass of the files alone needs no database: $(cat "$TEST_DIR/inspect.out")"
if grep -Fxq 'tool zstd' "$TEST_DIR/calls"; then fail 'a pass of the files alone needs no dump compressor'; fi
IMPORT_FILES_ONLY=yes FIXTURE_REWRITES=source inspect || fail "source rewrites failed: $(cat "$TEST_DIR/inspect.out")"
if grep -Fxq rewrites "$TEST_DIR/calls"; then fail 'a pass of the files alone writes no rewrites'; fi
FIXTURE_REWRITES=source inspect || fail "source rewrites failed on a full pass: $(cat "$TEST_DIR/inspect.out")"
grep -Fxq rewrites "$TEST_DIR/calls" || fail 'a full pass must still check the source rewrites'
mkdir -p "$TEST_DIR/www/dev.example.test"
rm -f "$marker"
rm -rf "$TEST_DIR/www/example.test"
if IMPORT_FILES_ONLY=yes FIXTURE_REUSE="$TEST_DIR/www/dev.example.test" inspect; then fail 'a pass of the files alone took a site over'; fi
grep -Fq 'IMPORT_FILES_ONLY does not take over' "$TEST_DIR/inspect.out" || fail "missing reason: $(cat "$TEST_DIR/inspect.out")"
if grep -Fxq take-over "$TEST_DIR/calls"; then fail 'the take-over ran'; fi
FIXTURE_REUSE="$TEST_DIR/www/dev.example.test" inspect || true
grep -Fxq take-over "$TEST_DIR/calls" || fail 'a full pass must still take the site over'
pass 'the inspection of a pass of the files alone takes nothing over, writes no rewrites and needs no database'

echo "All $passed tests of the later passes passed."
