#!/bin/bash
# shellcheck disable=SC2016,SC2034,SC2329
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/native-import.sh"
TEST_DIR=$(mktemp -d /tmp/kvs-native-unit.XXXXXX)
trap 'rm -rf -- "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

fixture() {
    rm -rf "$TEST_DIR/source"
    mkdir -p "$TEST_DIR/source/data"
    cat > "$TEST_DIR/source/kvs-native-export.manifest" <<'MANIFEST'
format=1
complete=yes
source_database=old_source
tables_prefix=ktvs_
kvs_version=7.0.2
tables=2
MANIFEST
    cat > "$TEST_DIR/source/data/ktvs_options.sql" <<'SQL'
CREATE TABLE `ktvs_options` (
  `variable` varchar(64) NOT NULL,
  `value` text,
  PRIMARY KEY (`variable`)
) ENGINE=InnoDB;
SQL
    cat > "$TEST_DIR/source/data/ktvs_videos.sql" <<'SQL'
CREATE TABLE `ktvs_videos` (
  `video_id` bigint PRIMARY KEY,
  `title` text,
  KEY `by_title` (`title`(20))
) ENGINE=InnoDB;
SQL
    printf 'INITIAL_VERSION\t7.0.2\n' > "$TEST_DIR/source/data/ktvs_options.txt"
    printf '1\tfixture title\n' > "$TEST_DIR/source/data/ktvs_videos.txt"
}

hash_fixture() {
    (cd "$TEST_DIR/source" && sha256sum kvs-native-export.manifest data/* > SHA256SUMS)
}

pack_fixture() {
    tar -czf "$TEST_DIR/fixture.mariadb.tar.gz" -C "$TEST_DIR/source" kvs-native-export.manifest SHA256SUMS data
}

prepare_fixture() {
    native_import_prepare "$TEST_DIR/fixture.mariadb.tar.gz" ktvs_ 7.0.2 /var/www/kvs /var/www/kvs \
        "$TEST_DIR/init/$1" unit-marker new-site.example "${2:-4}"
}

df() {
    if [ "${SIMULATE_FULL_STAGE:-no}" = yes ]; then
        printf 'Filesystem 1B-blocks Used Available Use%% Mounted on\nfixture 1000 1000 0 100%% /\n'
    else
        command df "$@"
    fi
}

reject_fixture() {
    local name="$1"
    if prepare_fixture "$name" > "$TEST_DIR/rejected.log" 2>&1; then fail "$name was accepted"; fi
    [ ! -e "$TEST_DIR/init/$name" ] && [ ! -e "$TEST_DIR/init/$name.sh" ] || fail "$name published staging files"
}

for value in 0 33 -1 '2;true' ''; do
    if [ -n "$value" ] && native_import_jobs "$value" >/dev/null 2>&1; then fail "invalid worker count $value"; fi
done
[ "$(native_import_jobs 32)" = 32 ] || fail 'explicit concurrency'
database_available_memory_mb() { echo 128; }
[ "$(native_import_jobs auto)" = 1 ] || fail 'small host automatic concurrency'
database_available_memory_mb() { echo 24576; }
jobs=$(native_import_jobs auto)
[ "$jobs" -ge 1 ] && [ "$jobs" -le 8 ] || fail 'automatic concurrency cap'

fixture
hash_fixture
pack_fixture
inspection=$(native_import_inspect "$TEST_DIR/fixture.mariadb.tar.gz" ktvs_)
[ "$inspection" = $'2\t\t0\tyes' ] || fail 'native inspection fields'
if native_import_inspect "$TEST_DIR/fixture.mariadb.tar.gz" other_ >/dev/null 2>&1; then fail 'wrong prefix accepted'; fi
prepare_fixture good >/dev/null
[ -f "$TEST_DIR/init/good/data/new-site.example/ktvs_videos.txt" ] || fail 'destination schema mapping'
[ ! -x "$TEST_DIR/init/good.sh" ] || fail 'entrypoint hook must be sourced'
[ "$(stat -c %a "$TEST_DIR/init/good/data/new-site.example/ktvs_videos.txt")" = 644 ] || fail 'mysql-readable payload mode'
grep -Fq 'SET autocommit=1;' "$TEST_DIR/init/good/finalize.sql" || fail 'finalization does not commit'
tail -n 1 "$TEST_DIR/init/good/finalize.sql" | grep -Fq "'KVS_INSTALL_IMPORT', 'unit-marker'" || fail 'completion marker must be last'
if prepare_fixture good >/dev/null 2>&1; then fail 'existing staging was overwritten'; fi
SIMULATE_FULL_STAGE=yes
reject_fixture full_stage
grep -q 'native import staging needs' "$TEST_DIR/rejected.log" || fail 'missing staging space diagnostic'
SIMULATE_FULL_STAGE=no

printf 'tampered\n' >> "$TEST_DIR/source/data/ktvs_videos.txt"
pack_fixture
reject_fixture tampered
fixture
hash_fixture
sed -i '/data\/ktvs_videos.txt$/d' "$TEST_DIR/source/SHA256SUMS"
pack_fixture
reject_fixture checksum_missing
fixture
printf '\ncomplete=yes\n' >> "$TEST_DIR/source/kvs-native-export.manifest"
hash_fixture
pack_fixture
reject_fixture duplicate_manifest
fixture
sed -i 's/complete=yes/complete=no/' "$TEST_DIR/source/kvs-native-export.manifest"
hash_fixture
pack_fixture
reject_fixture incomplete
fixture
sed -i 's/tables=2/tables=3/' "$TEST_DIR/source/kvs-native-export.manifest"
hash_fixture
pack_fixture
reject_fixture wrong_count
fixture
sed -i "s/\x60title\x60 text,/\x60title\x60 text COMMENT 'USE FUNCTION EVENT REFERENCES old_source.table',/" "$TEST_DIR/source/data/ktvs_videos.sql"
printf '\n/* CREATE VIEW fake; USE old_source; */\n' >> "$TEST_DIR/source/data/ktvs_videos.sql"
hash_fixture
pack_fixture
prepare_fixture literal_keywords >/dev/null
fixture
printf '\nCREATE VIEW `view_name` AS SELECT 1;\n' >> "$TEST_DIR/source/data/ktvs_videos.sql"
hash_fixture
pack_fixture
reject_fixture complex_schema
fixture
# shellcheck disable=SC2016
sed -i 's/CREATE TABLE `ktvs_videos`/CREATE TABLE `old_source`.`ktvs_videos`/' "$TEST_DIR/source/data/ktvs_videos.sql"
hash_fixture
pack_fixture
reject_fixture qualified_schema
fixture
hash_fixture
tar -czf "$TEST_DIR/fixture.mariadb.tar.gz" -C "$TEST_DIR/source" \
    --transform='s|data/ktvs_videos.txt|../outside.txt|' kvs-native-export.manifest SHA256SUMS data
reject_fixture traversal
[ ! -e "$TEST_DIR/outside.txt" ] || fail 'archive escaped extraction directory'
fixture
hash_fixture
tar -czf "$TEST_DIR/fixture.mariadb.tar.gz" -C "$TEST_DIR/source" kvs-native-export.manifest SHA256SUMS data data/ktvs_options.sql
reject_fixture duplicate_member
fixture
rm "$TEST_DIR/source/data/ktvs_videos.txt"
ln -s /etc/passwd "$TEST_DIR/source/data/ktvs_videos.txt"
hash_fixture
pack_fixture
reject_fixture symlink
fixture
rm "$TEST_DIR/source/data/ktvs_videos.txt"
ln "$TEST_DIR/source/data/ktvs_options.txt" "$TEST_DIR/source/data/ktvs_videos.txt"
hash_fixture
pack_fixture
reject_fixture hardlink

# Exercise the produced entrypoint hook with a loader and SQL client boundary.
# Only the container mount path is relocated into this private test directory.
sed "s|^native_import_root=.*|native_import_root=$TEST_DIR/init/good|" "$TEST_DIR/init/good.sh" > "$TEST_DIR/hook.sh"
mariadb-import() {
    if [[ "$*" == *--help* ]]; then
        [ "${MISSING_CAPABILITY:-no}" = no ] || return 0
        echo '  --innodb-optimize-keys'; return 0
    fi
    printf '%s\n' "$*" > "$TEST_DIR/loader.args"
    [ "${LOADER_FAIL:-no}" = no ] || return 7
    echo "new-site.example.ktvs_videos: Records: 1 Deleted: 0 Skipped: 0 Warnings: ${LOADER_WARNINGS:-0}"
}
docker_process_sql() {
    if [[ "$*" == *'-e '* ]]; then
        printf '%s\n' "${RESTORED_TABLES:-2}"
    else
        cat > "$TEST_DIR/finalization.executed"
    fi
}
run_hook() (
    # shellcheck source=/dev/null
    source "$TEST_DIR/hook.sh"
)
run_hook > "$TEST_DIR/success.log"
grep -Fq -- '--dir=' "$TEST_DIR/loader.args" || fail 'native directory loader not invoked'
grep -Fq -- '--parallel=4' "$TEST_DIR/loader.args" || fail 'concurrency not passed to loader'
tail -n 1 "$TEST_DIR/finalization.executed" | grep -Fq "'KVS_INSTALL_IMPORT', 'unit-marker'" || fail 'successful hook did not finalize'
rm "$TEST_DIR/finalization.executed"
for failure in loader warnings count capability; do
    LOADER_FAIL=no LOADER_WARNINGS=0 RESTORED_TABLES=2 MISSING_CAPABILITY=no
    case "$failure" in
        loader) LOADER_FAIL=yes ;;
        warnings) LOADER_WARNINGS=1 ;;
        count) RESTORED_TABLES=1 ;;
        capability) MISSING_CAPABILITY=yes ;;
    esac
    if run_hook > "$TEST_DIR/$failure.log" 2>&1; then fail "$failure failure was ignored"; fi
    [ ! -e "$TEST_DIR/finalization.executed" ] || fail "$failure failure wrote a completion marker"
done
echo 'PASS: native bundle integrity, safe extraction, schema mapping, concurrency and completion gates'
