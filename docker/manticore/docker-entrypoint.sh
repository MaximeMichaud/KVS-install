#!/bin/bash
set -e
set -o pipefail

echo "=== Manticore Search Init for KVS ==="

# Convert domain to safe index name (replace dots/dashes with underscores)
DOMAIN_SAFE="${DOMAIN//[.-]/_}"
export DOMAIN_SAFE

# The table prefix of the site, written to .env by the setup from the
# site's setup.php; it lands inside the indexer's SQL.
TABLES_PREFIX="${TABLES_PREFIX:-ktvs_}"
if [[ ! "$TABLES_PREFIX" =~ ^[A-Za-z0-9_]{1,32}$ ]]; then
    echo "ERROR: TABLES_PREFIX must be 1 to 32 identifier characters, got '$TABLES_PREFIX'" >&2
    exit 1
fi
export TABLES_PREFIX

echo "Domain: $DOMAIN"
echo "Index prefix: $DOMAIN_SAFE"
echo "Table prefix: $TABLES_PREFIX"

# Generate manticore.conf from template
echo "Generating configuration..."
# Keep the allowlist literal for envsubst.
# shellcheck disable=SC2016
# A '#' starts a comment in manticore.conf, so a password holding one was
# cut there and the indexer was refused; the parser reads '\#' as the
# character itself.
MARIADB_PASSWORD="${MARIADB_PASSWORD//\#/\\#}" \
    envsubst '${DOMAIN_SAFE} ${DOMAIN} ${MARIADB_PASSWORD} ${TABLES_PREFIX}' \
    < /etc/manticoresearch/manticore.conf.template \
    > /etc/manticoresearch/manticore.conf
chown -R manticore:manticore /var/lib/manticore /var/log/manticore
chown manticore:manticore /etc/manticoresearch/manticore.conf
chmod 600 /etc/manticoresearch/manticore.conf

# Wait for MariaDB to be ready
echo "Waiting for MariaDB..."
MAX_TRIES=30
TRIES=0
until MYSQL_PWD="$MARIADB_PASSWORD" \
    mariadb --skip-ssl-verify-server-cert -h mariadb -u "$DOMAIN" -e "SELECT 1" "$DOMAIN" >/dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    if [ $TRIES -ge $MAX_TRIES ]; then
        echo "ERROR: Cannot connect to MariaDB after 1 minute"
        exit 1
    fi
    echo "  Waiting... ($TRIES/$MAX_TRIES)"
    sleep 2
done
echo "✓ MariaDB is ready"

# The hourly rotation (manticore-indexer.cron) takes this lock as well, so
# two indexers never write the files of a table at the same time.
INDEXER_LOCK=/var/run/manticore/indexer.lock

# The indexes the manticore-data volume kept are served at once, which suits
# a restart but not a database replaced since they were built, nor search
# switched on again after a pause: whoever does that leaves this file in the
# volume (docker/lib/manticore.sh), and this start drops those indexes and
# builds every one from the database before searchd answers. It goes once
# that build made every table; until then each start builds them again.
REBUILD_REQUEST=/var/lib/manticore/kvs-rebuild-before-start

# Why a build failed, for the health check, which fails while either file is
# there, and for reconfigure.sh --manticore status. Each start removes both.
# A build before searchd that failed on some tables leaves the first: searchd
# starts without a table that has no files and does not take it from a later
# rotation, so only a start can clear it. A rebuild behind searchd that
# failed leaves the second, which an hourly rotation that rebuilt every table
# clears as well (manticore-indexer.cron).
BUILD_FAILED=/var/run/manticore/kvs-build-failed
REBUILD_FAILED=/var/run/manticore/kvs-rebuild-failed
# There while this start builds every table on the request: run again
# meanwhile, reconfigure.sh --manticore enable waits for this build instead
# of starting it over (lib/manticore.sh).
REQUESTED_BUILD=/var/run/manticore/kvs-requested-build
rm -f "$BUILD_FAILED" "$REBUILD_FAILED" "$REQUESTED_BUILD"

# Every table of the configuration, by the path of its files in the
# manticore-data volume.
mapfile -t TABLE_PATHS < <(
    sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' /etc/manticoresearch/manticore.conf
)

# indexer writes the header of a table (.sph) last, whether it builds the
# table in place or under .tmp names for a rotation. A header that is
# missing, or older than another file of the table, is what an interrupted
# build leaves behind. The .spl file is the lock searchd takes on the table.
table_is_built() {
    local path="$1" file

    [ -s "${path}.sph" ] || return 1
    for file in "${path}".sp*; do
        case "$file" in
            *.sph | *.spl) ;;
            *) if [ "$file" -nt "${path}.sph" ]; then return 1; fi ;;
        esac
    done
}

all_tables_built() {
    local path

    [ "${#TABLE_PATHS[@]}" -gt 0 ] || return 1
    for path in "${TABLE_PATHS[@]}"; do
        table_is_built "$path" || return 1
    done
}

# Removes every file of every table of the configuration from the volume.
drop_kept_tables() {
    local path

    for path in "${TABLE_PATHS[@]}"; do
        case "$path" in
            /var/lib/manticore/?*) rm -f -- "$path".* ;;
        esac
    done
}

# indexer exits 0 as long as one table was built: a table whose source
# failed, on a query a KVS update broke for instance, shows only as an ERROR
# line in the log of the build, and keeps the files it had.
build_log_clean() {
    ! grep -Eq '^(ERROR|FATAL):' /var/log/manticore/indexer-init.log
}

# Builds every table in place, before searchd starts. Fails only when
# indexer built no table at all, which stops the start: Docker starts the
# container again. A build that failed on some tables lets searchd serve the
# others instead, and records why: exiting would have Docker start it again
# at once and build every other table again, back to back, until the source
# is repaired.
build_before_searchd() {
    gosu manticore bash -o pipefail -c \
        'indexer --all 2>&1 | tee /var/log/manticore/indexer-init.log'
}

record_failure() {
    echo "ERROR: $2"
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" > "$1"
}

# Rebuilds every table while searchd serves the previous files. With
# --rotate, indexer builds under .tmp names and then signals searchd, which
# swaps the new files in: searchd has to be running for that, hence the wait.
# The client never asks searchd for TLS: it stays on the loopback, and at
# some starts searchd offers TLS it cannot complete, which fails every
# client that accepts the offer.
rebuild_in_background() {
    local tries=0

    until mariadb --skip-ssl --connect-timeout=5 -h 127.0.0.1 -P 9306 -e 'SHOW STATUS' >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$tries" -ge 300 ]; then
            record_failure "$REBUILD_FAILED" "searchd did not answer within 10 minutes, the indexes were not rebuilt (the hourly rotation rebuilds them)"
            return 1
        fi
        sleep 2
    done
    if gosu manticore flock "$INDEXER_LOCK" \
        bash -c 'indexer --all --rotate > /var/log/manticore/indexer-init.log 2>&1' &&
        build_log_clean; then
        echo "✓ Indexes rebuilt in the background and handed to searchd"
    else
        record_failure "$REBUILD_FAILED" "Background index rebuild failed, searchd keeps the previous files of every table it did not rebuild until the hourly rotation or a start rebuilds them (check /var/log/manticore/indexer-init.log)"
    fi
}

if [ -e "$REBUILD_REQUEST" ]; then
    # The database changed under the indexes the volume keeps: served, they
    # would answer from rows that are gone and miss the new ones, and a
    # table the build cannot make would keep its files from before. So they
    # go, and every table is built before searchd starts. Until searchd
    # answers, KVS falls back to its own search, as it does while Manticore
    # is down.
    echo "A rebuild from the current database was requested: the indexes the volume kept are dropped and every index is built before searchd starts (this may take a while)..."
    : > "$REQUESTED_BUILD"
    drop_kept_tables
    if ! build_before_searchd; then
        rm -f "$REQUESTED_BUILD"
        echo "ERROR: The requested index rebuild failed, the next start tries again (check /var/log/manticore/indexer-init.log)"
        exit 1
    fi
    rm -f "$REQUESTED_BUILD"
    if build_log_clean; then
        rm -f "$REBUILD_REQUEST"
        echo "✓ Indexes rebuilt from the current database"
    else
        record_failure "$BUILD_FAILED" "The requested index rebuild failed on some tables: searchd serves the others until a start builds every table (check /var/log/manticore/indexer-init.log)"
    fi
elif all_tables_built; then
    # The volume keeps every table from a previous start, so searchd serves
    # them right away: a recreated container, after an upgrade for instance,
    # does not wait for a full rebuild, which runs behind searchd instead.
    echo "Indexes found from a previous start: searchd serves them now and they are rebuilt in the background (log: /var/log/manticore/indexer-init.log)"
    # The subshell exits at once, which hands the rebuild over to Docker's
    # init (init: true) and lets it reap the rebuild. Left a child of this
    # shell, it would belong to searchd after the exec below, and searchd
    # never reaps it: it would stay a zombie.
    ( rebuild_in_background & )
else
    # A table without files (the first start, or a table added to the
    # configuration) is built before searchd starts.
    echo "Building initial indexes (this may take a while)..."
    if ! build_before_searchd; then
        echo "ERROR: Initial indexing failed (check /var/log/manticore/indexer-init.log)"
        exit 1
    fi
    if build_log_clean; then
        echo "✓ Initial indexes built successfully"
    else
        record_failure "$BUILD_FAILED" "Initial indexing failed on some tables: searchd serves the others, or the files an earlier build left, until a start builds every table (check /var/log/manticore/indexer-init.log)"
    fi
fi

# Start cron for hourly updates
echo "Starting cron for hourly index updates..."
service cron start || echo "⚠ Cron not available (may need to install)"

echo "=== Starting Manticore Search ==="

# Delegate the final launch to the upstream entrypoint. It fixes ownership of
# Manticore runtime paths and re-executes searchd as the manticore user through
# gosu, so Buddy inherits the same unprivileged UID/GID.
exec /usr/local/bin/manticore-entrypoint.sh "$@"
