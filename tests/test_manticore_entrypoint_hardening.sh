#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${ROOT_DIR}/docker/manticore/docker-entrypoint.sh"
TEMPLATE="${ROOT_DIR}/docker/manticore/manticore.conf.template"
CRON_FILE="${ROOT_DIR}/docker/manticore/manticore-indexer.cron"
TEST_DIR=$(mktemp -d)
background_pids=()

cleanup() {
    local pid

    for pid in "${background_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v envsubst >/dev/null 2>&1 || fail "envsubst is required"
command -v flock >/dev/null 2>&1 || fail "flock is required"

DATA_DIR="${TEST_DIR}/var/lib/manticore"
mkdir -p "${TEST_DIR}/etc/manticoresearch" "${TEST_DIR}/var/log/manticore" \
    "$DATA_DIR" "${TEST_DIR}/var/run/manticore" "${TEST_DIR}/bin"
sed -e "s|/var/lib/manticore|${DATA_DIR}|g" "$TEMPLATE" \
    > "${TEST_DIR}/etc/manticoresearch/manticore.conf.template"
sed \
    -e "s|/etc/manticoresearch|${TEST_DIR}/etc/manticoresearch|g" \
    -e "s|/var/log/manticore|${TEST_DIR}/var/log/manticore|g" \
    -e "s|/var/lib/manticore|${DATA_DIR}|g" \
    -e "s|/var/run/manticore|${TEST_DIR}/var/run/manticore|g" \
    -e 's|exec /usr/local/bin/manticore-entrypoint.sh "$@"|exec "$@"|' \
    "$ENTRYPOINT" > "${TEST_DIR}/docker-entrypoint.sh"

export CHOWN_LOG="${TEST_DIR}/chown.log"
export CHMOD_LOG="${TEST_DIR}/chmod.log"
export GOSU_LOG="${TEST_DIR}/gosu.log"
export INDEXER_LOG="${TEST_DIR}/indexer.log"
export MARIADB_LOG="${TEST_DIR}/mariadb.log"
# One line per probe and per indexer run, in the order they happen.
export EVENTS_LOG="${TEST_DIR}/events.log"
export REBUILD_PARENT_LOG="${TEST_DIR}/rebuild-parent.log"
export SEARCHD_PROBES="${TEST_DIR}/searchd-probes"
export INDEXER_LOCK="${TEST_DIR}/var/run/manticore/indexer.lock"
# The files of the volume when the indexer starts.
export TEST_DATA_DIR="$DATA_DIR"
export INDEXER_SAW_LOG="${TEST_DIR}/indexer-saw.log"
# Whether the start said, while the indexer ran, that it builds on the
# request.
export INDEXER_SAW_REQUESTED_LOG="${TEST_DIR}/indexer-saw-requested.log"
# What a caller leaves in the volume to have the next start build every
# index before searchd answers, and what a build before searchd, or a
# rebuild behind it, that failed leaves for the health check and
# reconfigure.sh.
REBUILD_REQUEST="${DATA_DIR}/kvs-rebuild-before-start"
BUILD_FAILED="${TEST_DIR}/var/run/manticore/kvs-build-failed"
REBUILD_FAILED="${TEST_DIR}/var/run/manticore/kvs-rebuild-failed"
# What the start leaves while it builds on the request, for
# reconfigure.sh --manticore enable.
export REQUESTED_BUILD="${TEST_DIR}/var/run/manticore/kvs-requested-build"

mariadb() {
    local argument

    for argument in "$@"; do
        if [ "$argument" = 9306 ]; then
            # At some starts searchd offers TLS it cannot complete: a client
            # that accepts the offer fails, as the image's client does by
            # default.
            case " $* " in
                *' --skip-ssl '*) ;;
                *)
                    echo 'searchd probe: TLS accepted' >> "$EVENTS_LOG"
                    echo 'ERROR 2026 (HY000): TLS/SSL error: sslv3 alert handshake failure' >&2
                    return 1
                    ;;
            esac
            # The rebuild waits for searchd: TEST_SEARCHD_DOWN_PROBES first
            # probes find it down.
            echo probe >> "$SEARCHD_PROBES"
            if [ "$(wc -l < "$SEARCHD_PROBES")" -le "${TEST_SEARCHD_DOWN_PROBES:-0}" ]; then
                echo 'searchd probe: down' >> "$EVENTS_LOG"
                return 1
            fi
            echo 'searchd probe: up' >> "$EVENTS_LOG"
            return 0
        fi
    done
    printf 'password=%s\n' "${MYSQL_PWD:-<unset>}" >> "$MARIADB_LOG"
    printf 'argument=%s\n' "$@" >> "$MARIADB_LOG"
    return 0
}

indexer() {
    local lock_state=free rebuild_pid

    printf '%s %s\n' "${TEST_EFFECTIVE_USER:-unset}" "$*" >> "$INDEXER_LOG"
    ls -A "$TEST_DATA_DIR" > "$INDEXER_SAW_LOG"
    if [ -e "$REQUESTED_BUILD" ]; then
        echo present > "$INDEXER_SAW_REQUESTED_LOG"
    else
        echo absent > "$INDEXER_SAW_REQUESTED_LOG"
    fi
    if ! flock -n "$INDEXER_LOCK" true; then
        lock_state=held
    fi
    printf 'indexer %s (lock %s)\n' "$*" "$lock_state" >> "$EVENTS_LOG"
    if [ "$*" = '--all --rotate' ]; then
        # The parent of flock is the rebuild; its own parent tells whether it
        # was detached from the entrypoint.
        rebuild_pid=$(ps -o ppid= -p "$PPID" | tr -d ' ')
        ps -o ppid= -p "$rebuild_pid" | tr -d ' ' >> "$REBUILD_PARENT_LOG"
    fi
    [ "${TEST_EFFECTIVE_USER:-}" = manticore ] || return 91
    echo "indexer output for $*"
    # The real indexer exits 0 as long as one table was built, and tells a
    # table whose source failed only by this line.
    if [ "${TEST_INDEXER_TABLE_ERROR:-no}" = yes ]; then
        echo "ERROR: table 'example_com_searches': sql_query: Unknown column 'amount' in 'SELECT'"
    fi
    [ "${TEST_INDEXER_EXIT:-37}" = 0 ] && return 0
    echo "deterministic indexer failure" >&2
    return 37
}

service() {
    return 0
}

chown() {
    printf '%s\n' "$*" >> "$CHOWN_LOG"
}

chmod() {
    printf '%s\n' "$*" >> "$CHMOD_LOG"
    command chmod "$@"
}

gosu() {
    local target_user="${1:-}"

    printf '%s\n' "$*" >> "$GOSU_LOG"
    [ "$target_user" = manticore ] || return 92
    shift
    TEST_EFFECTIVE_USER="$target_user" "$@"
}

export -f mariadb indexer service chown chmod gosu

reset_logs() {
    rm -f "$CHOWN_LOG" "$CHMOD_LOG" "$GOSU_LOG" "$INDEXER_LOG" "$MARIADB_LOG" \
        "$EVENTS_LOG" "$REBUILD_PARENT_LOG" "$SEARCHD_PROBES" "$INDEXER_SAW_LOG" \
        "$INDEXER_SAW_REQUESTED_LOG" "${TEST_DIR}/var/log/manticore/indexer-init.log"
    touch "$EVENTS_LOG" "$INDEXER_LOG"
}

if output=$(
    reset_logs
    DOMAIN=example.com \
    MARIADB_PASSWORD=test-password \
    bash "${TEST_DIR}/docker-entrypoint.sh" true 2>&1
); then
    fail "a failed initial index build must stop the container"
fi

generated_config="${TEST_DIR}/etc/manticoresearch/manticore.conf"
# Manticore must receive these placeholders literally.
# shellcheck disable=SC2016
grep -Fq 'video_id BETWEEN $start AND $end' "$generated_config" ||
    fail "the video range placeholders were modified"
# shellcheck disable=SC2016
grep -Fq 'album_id BETWEEN $start AND $end' "$generated_config" ||
    fail "the album range placeholders were modified"
grep -Fq 'source example_com_videos' "$generated_config" ||
    fail "DOMAIN_SAFE was not substituted"
grep -Fq 'sql_pass = test-password' "$generated_config" ||
    fail "MARIADB_PASSWORD was not substituted"
# A '#' starts a comment in manticore.conf: the password reaches it escaped,
# the parser reads '\#' as the character (a raw one cut the password there).
(
    reset_logs
    DOMAIN=example.com MARIADB_PASSWORD='test#pass#word' bash "${TEST_DIR}/docker-entrypoint.sh" true >/dev/null 2>&1  # pragma: allowlist secret
) || true
grep -Fq 'sql_pass = test\#pass\#word' "$generated_config" ||
    fail "a '#' in MARIADB_PASSWORD must reach manticore.conf escaped: $(grep -F 'sql_pass' "$generated_config" | head -n 1)"
(
    reset_logs
    DOMAIN=example.com \
    MARIADB_PASSWORD=test-password \
    bash "${TEST_DIR}/docker-entrypoint.sh" true >/dev/null 2>&1
) || true
grep -Fq 'FROM ktvs_videos' "$generated_config" ||
    fail "the default table prefix ktvs_ was not applied"
if grep -Fq 'TABLES_PREFIX' "$generated_config"; then
    fail "the table prefix placeholder was left in the configuration"
fi
[ "$(stat -c %a "$generated_config")" = 600 ] ||
    fail "the generated Manticore configuration is not mode 600"

grep -Fxq -- "-R manticore:manticore ${DATA_DIR} ${TEST_DIR}/var/log/manticore" \
    "$CHOWN_LOG" || fail "Manticore data and log paths are not assigned to manticore"
grep -Fxq "manticore:manticore ${generated_config}" "$CHOWN_LOG" ||
    fail "the generated configuration is not assigned to manticore"
grep -Fxq "600 ${generated_config}" "$CHMOD_LOG" ||
    fail "the generated configuration did not receive mode 600"
grep -Fq 'manticore bash -o pipefail -c indexer --all' "$GOSU_LOG" ||
    fail "the initial index build does not pass through gosu manticore"
grep -Fxq 'manticore --all' "$INDEXER_LOG" ||
    fail "the initial indexer did not execute with the manticore identity"
grep -Fxq 'password=test-password' "$MARIADB_LOG" ||
    fail "the MariaDB readiness check did not authenticate through MYSQL_PWD"
if grep '^argument=' "$MARIADB_LOG" | grep -Fq 'test-password'; then
    fail "the MariaDB password was exposed through process arguments"
fi

grep -Fq 'Initial indexing failed' <<< "$output" ||
    fail "an indexer failure was not reported"
if grep -Fq 'Initial indexes built successfully' <<< "$output"; then
    fail "an indexer failure was reported as successful"
fi

# A first build that fails on one table, indexer exiting 0 as it built the
# others, lets searchd start with those and records why, for the health
# check and reconfigure.sh: stopping the start would have Docker start the
# container again at once and build every other table again, back to back,
# until the source is repaired.
output=$(
    reset_logs
    TEST_INDEXER_EXIT=0 TEST_INDEXER_TABLE_ERROR=yes \
    DOMAIN=example.com \
    MARIADB_PASSWORD=test-password \
    bash "${TEST_DIR}/docker-entrypoint.sh" true 2>&1
) || fail "a first build that failed on one table stopped the start: ${output}"
grep -Fq 'ERROR: Initial indexing failed on some tables' <<< "$output" ||
    fail "a table the first build could not build was not reported"
grep -Fq '=== Starting Manticore Search ===' <<< "$output" ||
    fail "searchd did not start with the tables the first build made"
if grep -Fq 'Initial indexes built successfully' <<< "$output"; then
    fail "a first build that failed on one table was reported as successful"
fi
[ "$(cat "$INDEXER_LOG")" = 'manticore --all' ] ||
    fail "a first build that failed on one table must be one build: $(cat "$INDEXER_LOG")"
[ "$(cat "$INDEXER_SAW_REQUESTED_LOG")" = absent ] ||
    fail "a first build said it builds on a request"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z Initial indexing failed on some tables' "$BUILD_FAILED" 2>/dev/null ||
    fail "a first build that failed on one table left no dated reason for the health check: $(cat "$BUILD_FAILED" 2>&1)"
[ ! -e "$REBUILD_FAILED" ] ||
    fail "a failed build before searchd was recorded as a failed rebuild behind it"
rm -f "$BUILD_FAILED"

# The prefix of an imported site reaches every query of the indexer.
prefixed=$(
    reset_logs
    TEST_INDEXER_EXIT=0 \
    DOMAIN=example.com \
    MARIADB_PASSWORD=test-password \
    TABLES_PREFIX=kvs7_ \
    bash "${TEST_DIR}/docker-entrypoint.sh" true 2>&1
)
grep -Fq 'Table prefix: kvs7_' <<< "$prefixed" ||
    fail "the table prefix was not announced"
grep -Fq 'FROM kvs7_videos' "$generated_config" ||
    fail "a custom table prefix was not applied to the video source"
grep -Fq 'FROM kvs7_albums' "$generated_config" ||
    fail "a custom table prefix was not applied to the album source"
if grep -Fq 'ktvs_' "$generated_config"; then
    fail "the default prefix survived a custom one"
fi
if DOMAIN=example.com MARIADB_PASSWORD=test-password TABLES_PREFIX='kt vs;' \
    bash "${TEST_DIR}/docker-entrypoint.sh" true >/dev/null 2>&1; then
    fail "a prefix that is not an identifier must stop the container"
fi

# The files a finished build leaves for each table of the configuration: the
# header (.sph) is the newest of them, as indexer writes it last. searchd
# touches the .spl lock at every start, after the header.
tables=(example_com_videos example_com_albums example_com_searches)
write_built_tables() {
    local table

    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR"
    for table in "${tables[@]}"; do
        printf 'data\n' > "${DATA_DIR}/${table}.spa"
        printf 'data\n' > "${DATA_DIR}/${table}.spd"
        printf 'header\n' > "${DATA_DIR}/${table}.sph"
        : > "${DATA_DIR}/${table}.spl"
        touch -d '2026-01-01 10:00:00' "${DATA_DIR}/${table}.spa" "${DATA_DIR}/${table}.spd"
        touch -d '2026-01-01 10:05:00' "${DATA_DIR}/${table}.sph"
        touch -d '2026-01-01 11:00:00' "${DATA_DIR}/${table}.spl"
    done
}

# Runs the entrypoint with a stand-in for searchd, and waits for the line
# the rebuild prints when it ends.
run_with_built_tables() {
    local attempt

    reset_logs
    DOMAIN=example.com MARIADB_PASSWORD=test-password \
        bash "${TEST_DIR}/docker-entrypoint.sh" sleep 30 > "${TEST_DIR}/entrypoint.out" 2>&1 &
    entrypoint_pid=$!
    background_pids+=("$entrypoint_pid")
    for attempt in $(seq 1 100); do
        if grep -Eq 'Indexes rebuilt in the background|Background index rebuild failed' \
            "${TEST_DIR}/entrypoint.out"; then
            return 0
        fi
        sleep 0.1
    done
    cat "${TEST_DIR}/entrypoint.out" >&2
    fail "the background rebuild did not report after ${attempt} attempts"
}

# Tables a previous start built are served at once: searchd starts without
# a build and the rebuild runs behind it, once searchd answers, under the
# lock of the hourly rotation, as the manticore user. The failures an
# earlier start recorded go as this one begins.
write_built_tables
printf 'an earlier start failed\n' > "$REBUILD_FAILED"
printf 'an earlier build before searchd failed\n' > "$BUILD_FAILED"
: > "$REQUESTED_BUILD"
TEST_INDEXER_EXIT=0 TEST_SEARCHD_DOWN_PROBES=1 run_with_built_tables
fast_output=$(cat "${TEST_DIR}/entrypoint.out")
grep -Fq 'Indexes found from a previous start' <<< "$fast_output" ||
    fail "tables built by a previous start were not recognised"
if grep -Fq 'Building initial indexes' <<< "$fast_output"; then
    fail "tables built by a previous start were built again before searchd"
fi
grep -Fq 'Indexes rebuilt in the background' <<< "$fast_output" ||
    fail "a successful background rebuild was not reported"
grep -Fq '=== Starting Manticore Search ===' <<< "$fast_output" ||
    fail "searchd was not started while the rebuild runs"
[ "$(cat "$EVENTS_LOG")" = "$(printf '%s\n' \
    'searchd probe: down' 'searchd probe: up' 'indexer --all --rotate (lock held)')" ] ||
    fail "the rebuild must wait for searchd, then rotate under the lock: $(cat "$EVENTS_LOG")"
grep -Fxq 'manticore --all --rotate' "$INDEXER_LOG" ||
    fail "the background rebuild does not run as the manticore user"
grep -Fq "manticore flock ${INDEXER_LOCK} bash -c indexer --all --rotate" "$GOSU_LOG" ||
    fail "the background rebuild does not take the indexer lock as manticore"
grep -Fxq 'indexer output for --all --rotate' "${TEST_DIR}/var/log/manticore/indexer-init.log" ||
    fail "the background rebuild output does not reach indexer-init.log"
rebuild_parent=$(cat "$REBUILD_PARENT_LOG")
[ -n "$rebuild_parent" ] && [ "$rebuild_parent" != "$entrypoint_pid" ] ||
    fail "the background rebuild is a child of the process that becomes searchd"
[ ! -e "$REBUILD_FAILED" ] ||
    fail "a start whose rebuild succeeded keeps a failure: $(cat "$REBUILD_FAILED")"
[ ! -e "$BUILD_FAILED" ] ||
    fail "a start kept the failure of an earlier build before searchd: $(cat "$BUILD_FAILED")"
[ ! -e "$REQUESTED_BUILD" ] ||
    fail "a start that serves the kept indexes says it builds on a request, as an earlier start left it"
[ "$(cat "$INDEXER_SAW_REQUESTED_LOG")" = absent ] ||
    fail "the rebuild behind searchd ran while the start said it builds on a request"
if grep -Fq 'searchd probe: TLS accepted' "$EVENTS_LOG"; then
    fail "the rebuild waits for searchd with a client that accepts TLS"
fi
kill "$entrypoint_pid" 2>/dev/null || true

# A failed rebuild leaves searchd on the previous files and says so, in the
# log and in the file the health check and reconfigure.sh read: an indexer
# that fails, or one that exits 0 with a table it could not build.
for failure in exit table; do
    write_built_tables
    case "$failure" in
        exit) run_with_built_tables ;;
        table) TEST_INDEXER_EXIT=0 TEST_INDEXER_TABLE_ERROR=yes run_with_built_tables ;;
    esac
    failed_output=$(cat "${TEST_DIR}/entrypoint.out")
    grep -Fq 'ERROR: Background index rebuild failed' <<< "$failed_output" ||
        fail "a failed background rebuild was not reported (${failure})"
    grep -Fq '=== Starting Manticore Search ===' <<< "$failed_output" ||
        fail "a failed background rebuild stopped searchd from starting (${failure})"
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z Background index rebuild failed' "$REBUILD_FAILED" 2>/dev/null ||
        fail "a failed background rebuild left no dated reason for the health check (${failure}): $(cat "$REBUILD_FAILED" 2>&1)"
    kill "$entrypoint_pid" 2>/dev/null || true
done

# A rebuild requested because the database changed under the kept indexes
# runs before searchd starts, whatever the volume holds: the files of the
# previous build go first, so none is served, and the request goes once
# the build made every table.
write_built_tables
touch "${DATA_DIR}/example_com_videos.new.spa" "${DATA_DIR}/example_com_albums.tmp.spd"
: > "$REBUILD_REQUEST"
rm -f "$REQUESTED_BUILD"
requested_output=$(
    reset_logs
    TEST_INDEXER_EXIT=0 DOMAIN=example.com MARIADB_PASSWORD=test-password \
        bash "${TEST_DIR}/docker-entrypoint.sh" true 2>&1
) || fail "a requested rebuild that succeeded stopped the start: ${requested_output}"
grep -Fq 'A rebuild from the current database was requested' <<< "$requested_output" ||
    fail "a requested rebuild was not announced"
if grep -Fq 'Indexes found from a previous start' <<< "$requested_output"; then
    fail "the kept indexes were served although a rebuild was requested"
fi
[ "$(cat "$INDEXER_LOG")" = 'manticore --all' ] ||
    fail "a requested rebuild must be one build before searchd: $(cat "$INDEXER_LOG")"
[ "$(cat "$INDEXER_SAW_LOG")" = kvs-rebuild-before-start ] ||
    fail "a requested rebuild must start from no file of the kept tables, the indexer saw: $(cat "$INDEXER_SAW_LOG")"
[ "$(grep -c '^searchd probe' "$EVENTS_LOG")" = 0 ] ||
    fail "a requested rebuild ran behind searchd instead of before it"
grep -Fq '✓ Indexes rebuilt from the current database' <<< "$requested_output" ||
    fail "a requested rebuild that succeeded was not reported"
[ ! -e "$REBUILD_REQUEST" ] || fail "a requested rebuild that succeeded kept the request"
# While it builds, and only then, the start says it builds on the request:
# run again meanwhile, reconfigure.sh --manticore enable waits for it.
[ "$(cat "$INDEXER_SAW_REQUESTED_LOG")" = present ] ||
    fail "a requested rebuild did not say, while it built, that it builds on the request"
[ ! -e "$REQUESTED_BUILD" ] || fail "a requested rebuild that ended still says it builds"
grep -Fq '=== Starting Manticore Search ===' <<< "$requested_output" ||
    fail "searchd did not start after a requested rebuild"

# A requested rebuild that builds no table stops the container before
# searchd, as a first build that builds none does, and keeps the request:
# the next start drops what is left and tries again.
write_built_tables
: > "$REBUILD_REQUEST"
if requested_output=$(
    reset_logs
    TEST_INDEXER_EXIT=37 DOMAIN=example.com MARIADB_PASSWORD=test-password \
        bash "${TEST_DIR}/docker-entrypoint.sh" true 2>&1
); then
    fail "a requested rebuild that built no table let searchd start"
fi
grep -Fq 'ERROR: The requested index rebuild failed, the next start tries again' <<< "$requested_output" ||
    fail "a requested rebuild that built no table was not reported"
if grep -Fq '=== Starting Manticore Search ===' <<< "$requested_output"; then
    fail "searchd started after a requested rebuild built no table"
fi
[ -e "$REBUILD_REQUEST" ] || fail "a requested rebuild that built no table dropped the request"
[ "$(cat "$INDEXER_SAW_REQUESTED_LOG")" = present ] ||
    fail "a requested rebuild that built no table did not say, while it built, that it builds on the request"
[ ! -e "$REQUESTED_BUILD" ] || fail "a requested rebuild that built no table still says it builds"
[ "$(cat "$INDEXER_SAW_LOG")" = kvs-rebuild-before-start ] ||
    fail "a requested rebuild that built no table started from kept files: $(cat "$INDEXER_SAW_LOG")"

# One that fails on one table lets searchd start with the tables it built:
# the one it could not build is not served at all, since its files of the
# previous database went first. The request stays, so the next start builds
# every table again, and the reason is recorded for the health check.
write_built_tables
: > "$REBUILD_REQUEST"
requested_output=$(
    reset_logs
    TEST_INDEXER_EXIT=0 TEST_INDEXER_TABLE_ERROR=yes \
        DOMAIN=example.com MARIADB_PASSWORD=test-password \
        bash "${TEST_DIR}/docker-entrypoint.sh" true 2>&1
) || fail "a requested rebuild that failed on one table stopped the start: ${requested_output}"
grep -Fq 'ERROR: The requested index rebuild failed on some tables' <<< "$requested_output" ||
    fail "a requested rebuild that failed on one table was not reported"
grep -Fq '=== Starting Manticore Search ===' <<< "$requested_output" ||
    fail "searchd did not start with the tables the requested rebuild made"
[ "$(cat "$INDEXER_LOG")" = 'manticore --all' ] ||
    fail "a requested rebuild that failed on one table must be one build: $(cat "$INDEXER_LOG")"
[ "$(cat "$INDEXER_SAW_LOG")" = kvs-rebuild-before-start ] ||
    fail "the table the requested rebuild could not build kept its files of the previous database: $(cat "$INDEXER_SAW_LOG")"
[ -e "$REBUILD_REQUEST" ] || fail "a requested rebuild that failed on one table dropped the request"
[ ! -e "$REQUESTED_BUILD" ] || fail "a requested rebuild that failed on one table still says it builds"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z The requested index rebuild failed on some tables' "$BUILD_FAILED" 2>/dev/null ||
    fail "a requested rebuild that failed on one table left no dated reason for the health check: $(cat "$BUILD_FAILED" 2>&1)"
rm -f "$REBUILD_REQUEST" "$BUILD_FAILED"

# A searchd that never answers ends the wait after 300 probes, 2 s apart,
# with an error and no indexer run. A sleep that returns at once, on the
# PATH of this run only, keeps the test short.
write_built_tables
mkdir -p "${TEST_DIR}/fastbin"
printf '#!/bin/sh\nexit 0\n' > "${TEST_DIR}/fastbin/sleep"
command chmod 0755 "${TEST_DIR}/fastbin/sleep"
reset_logs
PATH="${TEST_DIR}/fastbin:${PATH}" TEST_SEARCHD_DOWN_PROBES=100000 \
    DOMAIN=example.com MARIADB_PASSWORD=test-password \
    bash "${TEST_DIR}/docker-entrypoint.sh" true > "${TEST_DIR}/entrypoint.out" 2>&1
for attempt in $(seq 1 300); do
    if grep -Fq 'searchd did not answer' "${TEST_DIR}/entrypoint.out"; then
        break
    fi
    sleep 0.1
done
grep -Fq 'ERROR: searchd did not answer within 10 minutes' "${TEST_DIR}/entrypoint.out" ||
    fail "a searchd that never answers was not reported after ${attempt} attempts"
[ "$(wc -l < "$SEARCHD_PROBES")" -eq 300 ] ||
    fail "the rebuild must probe searchd 300 times, it probed $(wc -l < "$SEARCHD_PROBES") times"
[ ! -s "$INDEXER_LOG" ] || fail "an indexer ran although searchd never answered"
for attempt in $(seq 1 50); do
    [ -s "$REBUILD_FAILED" ] && break
    sleep 0.1
done
grep -Fq 'searchd did not answer within 10 minutes' "$REBUILD_FAILED" 2>/dev/null ||
    fail "a rebuild that never ran left no reason for the health check"

# A table without a complete build is built before searchd starts: no
# header (first start, a table added to the configuration, or a first build
# cut short), an empty one, or a data file newer than the header, which a
# rebuild in place cut short leaves.
for damage in missing-header empty-header newer-data; do
    write_built_tables
    case "$damage" in
        missing-header) rm -f "${DATA_DIR}/example_com_albums.sph" ;;
        empty-header) : > "${DATA_DIR}/example_com_albums.sph" ;;
        newer-data) touch -d '2026-01-01 10:06:00' "${DATA_DIR}/example_com_searches.spd" ;;
    esac
    blocking_output=$(
        reset_logs
        TEST_INDEXER_EXIT=0 DOMAIN=example.com MARIADB_PASSWORD=test-password \
            bash "${TEST_DIR}/docker-entrypoint.sh" true 2>&1
    ) || fail "the initial build failed (${damage})"
    grep -Fq 'Building initial indexes' <<< "$blocking_output" ||
        fail "a table without a complete build was not built before searchd (${damage})"
    [ "$(cat "$INDEXER_LOG")" = 'manticore --all' ] ||
        fail "the build before searchd must be the only indexer run (${damage}): $(cat "$INDEXER_LOG")"
    if grep -Fq 'Indexes found from a previous start' <<< "$blocking_output"; then
        fail "a table without a complete build was served (${damage})"
    fi
done

# The hourly rotation runs as the manticore user, takes the lock of the
# entrypoint's rebuild without waiting, and clears only the rotation files
# another user left: those of a manual indexer run as root, which searchd
# cannot open. A rotation that rebuilt every table clears the failure a
# rebuild at the start recorded.
entrypoint_lock=$(sed -n 's/^INDEXER_LOCK=//p' "$ENTRYPOINT")
[ "$entrypoint_lock" = /var/run/manticore/indexer.lock ] ||
    fail "the entrypoint does not define its indexer lock"
entrypoint_failure=$(sed -n 's/^REBUILD_FAILED=//p' "$ENTRYPOINT")
[ "$entrypoint_failure" = /var/run/manticore/kvs-rebuild-failed ] ||
    fail "the entrypoint does not define where a failed rebuild is recorded"
entrypoint_build_failure=$(sed -n 's/^BUILD_FAILED=//p' "$ENTRYPOINT")
[ "$entrypoint_build_failure" = /var/run/manticore/kvs-build-failed ] ||
    fail "the entrypoint does not define where a failed build before searchd is recorded"
# docker/lib/manticore.sh reads, from outside the container, the files the
# entrypoint writes.
for file in REBUILD_REQUEST BUILD_FAILED REBUILD_FAILED REQUESTED_BUILD; do
    defined=$(sed -n "s/^${file}=//p" "$ENTRYPOINT")
    [ -n "$defined" ] && [ "$defined" = "$(sed -n "s/^MANTICORE_${file}=//p" "${ROOT_DIR}/docker/lib/manticore.sh")" ] ||
        fail "docker/lib/manticore.sh does not read the ${file} file the entrypoint writes"
done
cron_command=$(sed -n 's/^0 \* \* \* \* manticore //p' "$CRON_FILE")
[ -n "$cron_command" ] ||
    fail "the hourly rotation must run every hour as the manticore user"
grep -Fq "flock -n -E 75 ${entrypoint_lock} sh -c \"find /var/lib/manticore -name '*.new.*' ! -user manticore -delete; /usr/bin/indexer --rotate --all " \
    <<< "$cron_command" ||
    fail "the hourly rotation must clear stale rotation files and rotate under the entrypoint's lock"
grep -Fq "rm -f ${entrypoint_failure};" <<< "$cron_command" ||
    fail "the hourly rotation does not clear the failure the entrypoint records"

cat > "${TEST_DIR}/bin/indexer" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$CRON_INDEXER_LOG"
echo "indexer output for $*"
if [ "${CRON_INDEXER_TABLE_ERROR:-no}" = yes ]; then
    echo "ERROR: table 'example_com_searches': sql_query: Unknown column 'amount' in 'SELECT'"
fi
exit "${CRON_INDEXER_EXIT:-0}"
MOCK
command chmod 0755 "${TEST_DIR}/bin/indexer"
export CRON_INDEXER_LOG="${TEST_DIR}/cron-indexer.log"
cron_log="${TEST_DIR}/var/log/manticore/indexer-cron.log"
test_cron_command=$(
    sed -e "s|/var/run/manticore|${TEST_DIR}/var/run/manticore|g" \
        -e "s|/var/log/manticore|${TEST_DIR}/var/log/manticore|g" \
        -e "s|/var/lib/manticore|${DATA_DIR}|g" \
        -e "s|/usr/bin/indexer|${TEST_DIR}/bin/indexer|g" \
        -e "s|! -user manticore|! -user $(id -un)|" <<< "$cron_command"
)
write_built_tables
touch "${DATA_DIR}/example_com_videos.new.spa"
printf 'a start-up rebuild failed\n' > "$REBUILD_FAILED"

# While the rebuild holds the lock, the hour is skipped and logged. With -o
# the lock stays with flock alone, which lets it go once its sleep ends.
flock -o "$INDEXER_LOCK" sleep 30 &
holder_pid=$!
background_pids+=("$holder_pid")
for attempt in $(seq 1 50); do
    if ! flock -n "$INDEXER_LOCK" true; then
        break
    fi
    sleep 0.1
done
[ "$attempt" -lt 50 ] || fail "the test could not take the indexer lock"
sh -c "$test_cron_command" || fail "a skipped hourly rotation must exit cleanly"
grep -q 'an index rebuild holds the lock, this hourly rotation is skipped$' "$cron_log" ||
    fail "a skipped hourly rotation was not logged"
[ ! -e "$CRON_INDEXER_LOG" ] || fail "the hourly rotation started an indexer under a held lock"
[ -e "${DATA_DIR}/example_com_videos.new.spa" ] ||
    fail "the hourly rotation cleared rotation files under a held lock"
[ -e "$REBUILD_FAILED" ] || fail "a skipped hourly rotation cleared a recorded failure"
pkill -P "$holder_pid" -x sleep 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true

# A rotation that fails leaves the recorded failure for the health check,
# and so does one that exits 0 with a table it could not build.
for failure in exit table; do
    case "$failure" in
        exit) CRON_INDEXER_EXIT=1 sh -c "$test_cron_command" ;;
        table) CRON_INDEXER_TABLE_ERROR=yes sh -c "$test_cron_command" ;;
    esac || fail "a failed hourly rotation must exit cleanly (${failure})"
    grep -Fxq -- '--rotate --all' "$CRON_INDEXER_LOG" ||
        fail "the hourly rotation did not run the indexer once the lock was free (${failure})"
    [ -e "$REBUILD_FAILED" ] || fail "a failed hourly rotation cleared a recorded failure (${failure})"
    rm -f "$CRON_INDEXER_LOG"
done
grep -Fq "ERROR: table 'example_com_searches'" "$cron_log" ||
    fail "the output of a failed hourly rotation does not reach indexer-cron.log"
# The failure of an hour is only logged: it records nothing for the health
# check, which an hour that meets MariaDB restarting would otherwise turn
# unhealthy, and the README says so.
saved_failure=$(cat "$REBUILD_FAILED")
rm -f "$REBUILD_FAILED" "$BUILD_FAILED"
for failure in exit table; do
    case "$failure" in
        exit) CRON_INDEXER_EXIT=1 sh -c "$test_cron_command" ;;
        table) CRON_INDEXER_TABLE_ERROR=yes sh -c "$test_cron_command" ;;
    esac || fail "a failed hourly rotation must exit cleanly (${failure})"
    [ ! -e "$REBUILD_FAILED" ] && [ ! -e "$BUILD_FAILED" ] ||
        fail "a failed hourly rotation recorded a failure for the health check (${failure})"
done
rm -f "$CRON_INDEXER_LOG"
printf '%s\n' "$saved_failure" > "$REBUILD_FAILED"
grep -Fq "an hourly rebuild that fails is only written to \`/var/log/manticore/indexer-cron.log\`" \
    <(tr -d '\r' < "${ROOT_DIR}/README.md") ||
    fail "README does not say that a failed hourly rebuild is only logged"

# Once the lock is free, the hour rotates and keeps the files of its own
# user; its success clears the failure of the rebuild behind searchd, not
# the one of a build before it: searchd does not take a table it started
# without from a rotation.
printf 'a build before searchd failed\n' > "$BUILD_FAILED"
sh -c "$test_cron_command" || fail "the hourly rotation failed"
grep -Fxq -- '--rotate --all' "$CRON_INDEXER_LOG" ||
    fail "the hourly rotation did not run the indexer once the lock was free"
grep -Fxq 'indexer output for --rotate --all' "$cron_log" ||
    fail "the hourly rotation output does not reach indexer-cron.log"
[ -e "${DATA_DIR}/example_com_videos.new.spa" ] ||
    fail "the hourly rotation cleared a rotation file of its own user"
[ ! -e "$REBUILD_FAILED" ] || fail "a successful hourly rotation kept the recorded failure"
[ -e "$BUILD_FAILED" ] || fail "an hourly rotation cleared the failure of a build before searchd"

# The plugin configuration follows the hints KVS gives for Manticore: the
# external search is used always and completely replaces the internal
# search, otherwise every hit is listed twice (Manticore's and MySQL's).
plugin_script="${ROOT_DIR}/docker/init/docker-entrypoint.d/80-manticore.sh"
for key in enable_external_search enable_external_search_albums enable_external_search_searches; do
    grep -Fq "'${key}' => 1," "$plugin_script" ||
        fail "the plugin must use the external search always (${key})"
done
for key in display_results display_results_albums display_results_searches; do
    grep -Fq "'${key}' => 0," "$plugin_script" ||
        fail "the external search must completely replace the internal search (${key})"
done
if grep -Fq "'disable_internal_fallback'" "$plugin_script"; then
    fail "the internal fallback must keep its default so KVS still answers while Manticore is down"
fi

echo "PASS: Manticore entrypoint hardening"
