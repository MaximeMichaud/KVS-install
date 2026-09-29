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

# Format 2 retains generated and invisible fields in their ordinal positions.
special_fixture() {
    fixture
    sed -i -e 's/^format=1$/format=2/' -e 's/^tables=2$/tables=3/' \
        "$TEST_DIR/source/kvs-native-export.manifest"
    cat > "$TEST_DIR/source/data/ktvs_videos.sql" <<'SQL'
CREATE TABLE `ktvs_videos` (
  `video_id` bigint NOT NULL PRIMARY KEY,
  `tenant_id` bigint NOT NULL,
  `title` text,
  `title_len` int GENERATED ALWAYS AS (CHAR_LENGTH(`title`)) STORED,
  UNIQUE KEY `by_tenant` (`video_id`, `tenant_id`)
) ENGINE=InnoDB;
SQL
    cat > "$TEST_DIR/source/data/ktvs_plugin_rows.sql" <<'SQL'
CREATE TABLE `ktvs_plugin_rows` (
  `row_id` bigint NOT NULL PRIMARY KEY,
  `video_id` bigint DEFAULT NULL,
  `tenant_id` bigint DEFAULT NULL,
  `parent_id` bigint DEFAULT NULL,
  `measure` bigint GENERATED ALWAYS AS (`video_id` + 1) STORED,
  `hidden_value` varchar(32) INVISIBLE DEFAULT 'private',
  CONSTRAINT `fk_composite` FOREIGN KEY (`video_id`, `tenant_id`) REFERENCES `ktvs_videos` (`video_id`, `tenant_id`),
  CONSTRAINT `fk_self` FOREIGN KEY (`parent_id`) REFERENCES `ktvs_plugin_rows` (`row_id`)
) ENGINE=InnoDB;
SQL
    printf '1\t7\tfixture title\t13\n' > "$TEST_DIR/source/data/ktvs_videos.txt"
    printf '1\t1\t7\t\\N\t2\tprivate\n' > "$TEST_DIR/source/data/ktvs_plugin_rows.txt"
}
special_fixture
hash_fixture
pack_fixture
[ "$(native_import_inspect "$TEST_DIR/fixture.mariadb.tar.gz" ktvs_)" = $'3\t\t0\tyes' ] || fail 'format 2 inspection'
prepare_fixture special >/dev/null
[ -r "$TEST_DIR/init/special/runtime.sh" ] || fail 'native runtime was not staged'
sed -i 's/^format=2$/format=3/' "$TEST_DIR/source/kvs-native-export.manifest"
hash_fixture
pack_fixture
reject_fixture future_format
special_fixture
sed -i 's/REFERENCES `ktvs_videos`/REFERENCES `ktvs_missing`/' "$TEST_DIR/source/data/ktvs_plugin_rows.sql"
hash_fixture
pack_fixture
reject_fixture missing_reference
special_fixture
sed -i 's/REFERENCES `ktvs_videos`/REFERENCES `old_source`.`ktvs_videos`/' "$TEST_DIR/source/data/ktvs_plugin_rows.sql"
hash_fixture
pack_fixture
reject_fixture external_reference
special_fixture
awk '/CONSTRAINT `fk_composite`/ { printf "%s ", $0; next } { print }' \
    "$TEST_DIR/source/data/ktvs_plugin_rows.sql" > "$TEST_DIR/compact.sql"
mv "$TEST_DIR/compact.sql" "$TEST_DIR/source/data/ktvs_plugin_rows.sql"
hash_fixture
pack_fixture
prepare_fixture compact_foreign_keys >/dev/null
sed -i 's/REFERENCES `ktvs_plugin_rows`/REFERENCES `ktvs_missing`/' "$TEST_DIR/source/data/ktvs_plugin_rows.sql"
hash_fixture
pack_fixture
reject_fixture missing_second_reference

# Exercise the published hook and staged runtime at the SQL/loader boundary.
reset_hook() {
    local stage="${1:-good}"
    rm -rf "$TEST_DIR/hook-state"
    mkdir "$TEST_DIR/hook-state"
    HOOK_STATE="$TEST_DIR/hook-state"
    : > "$HOOK_STATE/events"
    : > "$HOOK_STATE/columns"
    : > "$HOOK_STATE/keys"
    printf '%s' 'STRICT_TRANS_TABLES' > "$HOOK_STATE/sql-mode"
    LOADER_FAIL=no LOADER_WARNINGS=0 LOADER_SKIPPED=0 RESTORED_TABLES=2 MISSING_CAPABILITY=no
    SPECIAL_SQL_FAIL=no SPECIAL_WARNINGS=0 PRECREATE_FAIL=no COLUMN_MISMATCH=no FK_MISMATCH=no ORPHAN=no
    MODE_ACTIVATION_FAIL=no MODE_RESTORE_FAIL=no
    sed "s|^native_import_root=.*|native_import_root=$TEST_DIR/init/$stage|" \
        "$TEST_DIR/init/$stage.sh" > "$TEST_DIR/hook.sh"
}
mariadb-import() {
    if [[ "$*" == *--help* ]]; then
        [ "${MISSING_CAPABILITY:-no}" = no ] || return 0
        echo '  --innodb-optimize-keys'; return 0
    fi
    local count
    printf 'loader\n' >> "$HOOK_STATE/events"
    count=$(grep -c '^loader$' "$HOOK_STATE/events")
    printf '%s\n' "$@" > "$HOOK_STATE/loader.$count.args"
    case ",$(cat "$HOOK_STATE/sql-mode")," in
        *,NO_AUTO_VALUE_ON_ZERO,*) ;;
        *) echo 'Loader lost NO_AUTO_VALUE_ON_ZERO' >&2; return 98 ;;
    esac
    [ "${LOADER_FAIL:-no}" = no ] || return 7
    echo "new-site.example.ktvs_videos: Records: 1 Deleted: 0 Skipped: ${LOADER_SKIPPED:-0} Warnings: ${LOADER_WARNINGS:-0}"
}
docker_process_sql() {
    local query='' input count mode
    local -a sql_args=("$@")
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -e ]; then query=$2; break; fi
        shift
    done
    if [ -z "$query" ]; then
        input=$(cat)
        if [[ "$input" == *KVS_INSTALL_IMPORT* ]]; then
            printf 'finalize\n' >> "$HOOK_STATE/events"
            printf '%s\n' "$input" > "$HOOK_STATE/finalization.executed"
        else
            printf 'precreate\n' >> "$HOOK_STATE/events"
            printf '%s\n' "$input" > "$HOOK_STATE/precreation.executed"
            [ "$PRECREATE_FAIL" != yes ] || return 8
        fi
        return 0
    fi
    case "$query" in
        *'LOAD DATA INFILE '*)
            printf 'generated-sql\n' >> "$HOOK_STATE/events"
            count=$(grep -c '^generated-sql$' "$HOOK_STATE/events")
            printf '%s\n' "$query" > "$HOOK_STATE/generated.$count.sql"
            printf '%s\n' "${sql_args[@]}" > "$HOOK_STATE/generated.$count.args"
            [ "$SPECIAL_SQL_FAIL" != yes ] || return 9
            printf '%s\n' "$SPECIAL_WARNINGS"
            ;;
        'SELECT @@GLOBAL.sql_mode;') cat "$HOOK_STATE/sql-mode" ;;
        "SET GLOBAL sql_mode=CONCAT_WS("*)
            printf 'mode-enable\n' >> "$HOOK_STATE/events"
            mode=$(cat "$HOOK_STATE/sql-mode")
            printf '%s' "${mode:+$mode,}NO_AUTO_VALUE_ON_ZERO" > "$HOOK_STATE/sql-mode"
            [ "$MODE_ACTIVATION_FAIL" != yes ] || return 8
            printf '1\n'
            ;;
        "SET GLOBAL sql_mode='"*)
            printf 'mode-restore\n' >> "$HOOK_STATE/events"
            [ "$MODE_RESTORE_FAIL" != yes ] || return 8
            mode=${query#"SET GLOBAL sql_mode='"}
            mode=${mode%%\'*}
            printf '%s' "$mode" > "$HOOK_STATE/sql-mode"
            printf '%s\n' "$mode"
            ;;
        *'FROM information_schema.COLUMNS c'*)
            printf 'columns\n' >> "$HOOK_STATE/events"
            count=$(grep -c '^columns$' "$HOOK_STATE/events")
            cat "$HOOK_STATE/columns"
            if [ "$COLUMN_MISMATCH" = yes ] && [ "$count" -gt 1 ]; then printf 'changed\n'; fi
            ;;
        *'FROM information_schema.KEY_COLUMN_USAGE k'*)
            printf 'keys\n' >> "$HOOK_STATE/events"
            count=$(grep -c '^keys$' "$HOOK_STATE/events")
            cat "$HOOK_STATE/keys"
            if [ "$FK_MISMATCH" = yes ] && [ "$count" -gt 1 ]; then printf 'changed\n'; fi
            ;;
        *'SELECT COUNT(*) FROM information_schema.TABLES'*)
            printf 'count\n' >> "$HOOK_STATE/events"
            printf '%s\n' "$RESTORED_TABLES"
            ;;
        *'SELECT EXISTS('*'NOT EXISTS('*)
            printf 'foreign-key-check\n' >> "$HOOK_STATE/events"
            printf '%s\n' "$query" >> "$HOOK_STATE/fk-checks.sql"
            if [ "$ORPHAN" = yes ]; then printf '1\n'; else printf '0\n'; fi
            ;;
        *) printf 'Unexpected SQL: %s\n' "$query" >&2; return 97 ;;
    esac
}
run_hook() (
    # shellcheck source=/dev/null
    source "$TEST_DIR/hook.sh"
)
assert_arg() {
    grep -Fxq -- "$2" "$HOOK_STATE/loader.$1.args" || fail "loader $1 missing exact argument $2"
}
assert_no_marker() {
    [ ! -e "$HOOK_STATE/finalization.executed" ] || fail "$1 wrote a completion marker"
}
reset_hook
run_hook > "$TEST_DIR/success.log"
assert_arg 1 "--dir=$TEST_DIR/init/good/data"
assert_arg 1 --parallel=4
grep -Fq 'CREATE TABLE `ktvs_videos`' "$HOOK_STATE/precreation.executed" || fail 'table definitions were not precreated'
tail -n 1 "$HOOK_STATE/finalization.executed" | grep -Fq "'KVS_INSTALL_IMPORT', 'unit-marker'" || fail 'successful hook did not finalize'
[ "$(head -n 1 "$HOOK_STATE/events")" = precreate ] || fail 'loader ran before schema creation'
[ "$(tail -n 1 "$HOOK_STATE/events")" = finalize ] || fail 'completion marker was not the final operation'
[ "$(cat "$HOOK_STATE/sql-mode")" = STRICT_TRANS_TABLES ] || fail 'success changed persistent SQL mode'
for failure in loader warnings skipped count capability precreate mode-activation mode-restore; do
    reset_hook
    case "$failure" in
        loader) LOADER_FAIL=yes ;;
        warnings) LOADER_WARNINGS=1 ;;
        skipped) LOADER_SKIPPED=1 ;;
        count) RESTORED_TABLES=1 ;;
        capability) MISSING_CAPABILITY=yes ;;
        precreate) PRECREATE_FAIL=yes ;;
        mode-activation) MODE_ACTIVATION_FAIL=yes ;;
        mode-restore) MODE_RESTORE_FAIL=yes ;;
    esac
    if run_hook > "$TEST_DIR/$failure.log" 2>&1; then fail "$failure failure was ignored"; fi
    assert_no_marker "$failure"
    if [[ "$failure" = capability || "$failure" = precreate || "$failure" = mode-activation ]]; then
        [ ! -e "$HOOK_STATE/loader.1.args" ] || fail "$failure still started a loader"
    fi
    if [ "$failure" != mode-restore ]; then
        [ "$(cat "$HOOK_STATE/sql-mode")" = STRICT_TRANS_TABLES ] || fail "$failure failed to restore SQL mode"
    fi
done
for mode in '' 'NO_AUTO_VALUE_ON_ZERO,STRICT_TRANS_TABLES'; do
    reset_hook
    printf '%s' "$mode" > "$HOOK_STATE/sql-mode"
    run_hook > "$TEST_DIR/mode-success.log"
    [ "$(cat "$HOOK_STATE/sql-mode")" = "$mode" ] || fail 'SQL mode was not preserved exactly'
    if [ -n "$mode" ] && grep -q '^mode-enable\|^mode-restore' "$HOOK_STATE/events"; then
        fail 'already-enabled SQL mode was mutated'
    fi
done
echo 'PASS: native hook lifecycle, loader failures and SQL mode restoration'

special_metadata() {
    # Synthetic column metadata: hex-encoded varchar(32) and INVISIBLE.
    local hidden_column_metadata=$'ktvs_plugin_rows\t6\thidden_value\tvalue\t7661726368617228333229\t494E56495349424C45\t' # pragma: allowlist secret
    RESTORED_TABLES=3
    printf '%s\n' \
        $'ktvs_plugin_rows\t1\trow_id\tvalue\t626967696E74\t\t' \
        $'ktvs_plugin_rows\t2\tvideo_id\tvalue\t626967696E74\t\t' \
        $'ktvs_plugin_rows\t3\ttenant_id\tvalue\t626967696E74\t\t' \
        $'ktvs_plugin_rows\t4\tparent_id\tvalue\t626967696E74\t\t' \
        $'ktvs_plugin_rows\t5\tmeasure\tgenerated\t626967696E74\t53544F5245442047454E455241544544\t60766964656F5F696460202B2031' \
        "$hidden_column_metadata" \
        $'ktvs_videos\t1\tvideo_id\tvalue\t626967696E74\t\t' \
        $'ktvs_videos\t2\ttenant_id\tvalue\t626967696E74\t\t' \
        $'ktvs_videos\t3\ttitle\tvalue\t74657874\t\t' \
        $'ktvs_videos\t4\ttitle_len\tgenerated\t696E74\t53544F5245442047454E455241544544\t434841525F4C454E47544828607469746C656029' \
        > "$HOOK_STATE/columns"
    printf '%s\n' \
        $'ktvs_plugin_rows\tfk_composite\t1\tvideo_id\tnew-site.example\tktvs_videos\tvideo_id\tRESTRICT\tRESTRICT' \
        $'ktvs_plugin_rows\tfk_composite\t2\ttenant_id\tnew-site.example\tktvs_videos\ttenant_id\tRESTRICT\tRESTRICT' \
        $'ktvs_plugin_rows\tfk_self\t1\tparent_id\tnew-site.example\tktvs_plugin_rows\trow_id\tRESTRICT\tRESTRICT' \
        > "$HOOK_STATE/keys"
}

reset_hook special
special_metadata
run_hook > "$TEST_DIR/special-success.log"
[ "$(grep -c '^loader$' "$HOOK_STATE/events")" = 1 ] || fail 'generated tables were passed through mariadb-import'
[ "$(grep -c '^generated-sql$' "$HOOK_STATE/events")" = 2 ] || fail 'generated tables were not loaded through separate SQL sessions'
assert_arg 1 --parallel=4
assert_arg 1 --ignore-table=new-site.example.ktvs_plugin_rows
assert_arg 1 --ignore-table=new-site.example.ktvs_videos
if grep -q -- '^--columns=' "$HOOK_STATE/loader.1.args"; then fail 'ordinary tables received a generated mapping'; fi
for generated in 1 2; do
    if [ "$generated" = 1 ]; then
        generated_table=ktvs_plugin_rows
        generated_mapping='`row_id`,`video_id`,`tenant_id`,`parent_id`,@kvs_generated_5,`hidden_value`'
    else
        generated_table=ktvs_videos
        generated_mapping='`video_id`,`tenant_id`,`title`,@kvs_generated_4'
    fi
    {
        printf '\n'
        printf '%s\n' \
            'SET SESSION foreign_key_checks=0;' \
            'SET SESSION unique_checks=1;' \
            "SET SESSION time_zone='+00:00';" \
            "SET SESSION sql_mode=CONCAT_WS(',', NULLIF(@@SESSION.sql_mode,''), 'NO_AUTO_VALUE_ON_ZERO');"
        printf "LOAD DATA INFILE '%s' INTO TABLE \140%s\140 CHARACTER SET binary (%s);\n" \
            "$TEST_DIR/init/special/data/new-site.example/$generated_table.txt" "$generated_table" "$generated_mapping"
        printf 'SELECT @@warning_count;\n'
    } > "$HOOK_STATE/generated.expected.sql"
    cmp "$HOOK_STATE/generated.expected.sql" "$HOOK_STATE/generated.$generated.sql" ||
        fail "generated SQL for $generated_table lost its field mapping or session safeguards"
    grep -Fxq -- '--database=new-site.example' "$HOOK_STATE/generated.$generated.args" ||
        fail 'generated SQL did not select the destination schema'
done
[ "$(cat "$HOOK_STATE/sql-mode")" = STRICT_TRANS_TABLES ] || fail 'generated loading changed global SQL mode'
[ "$(grep -c '^mode-enable$' "$HOOK_STATE/events")" = 1 ] || fail 'generated loading unnecessarily changed global SQL mode'
[ "$(grep -c '^columns$' "$HOOK_STATE/events")" = 2 ] || fail 'generated definitions were not compared after loading'
[ "$(grep -c '^keys$' "$HOOK_STATE/events")" = 2 ] || fail 'foreign keys were not compared after loading'
[ "$(grep -c '^foreign-key-check$' "$HOOK_STATE/events")" = 2 ] || fail 'composite or self foreign key was not checked exactly once'
grep -Fq 'c.`video_id` IS NOT NULL AND c.`tenant_id` IS NOT NULL AND NOT EXISTS(SELECT 1 FROM `ktvs_videos` p WHERE p.`video_id`=c.`video_id` AND p.`tenant_id`=c.`tenant_id`)' \
    "$HOOK_STATE/fk-checks.sql" || fail 'nullable composite foreign key validation has wrong columns or NULL semantics'
grep -Fq 'FROM `ktvs_plugin_rows` c WHERE c.`parent_id` IS NOT NULL AND NOT EXISTS(SELECT 1 FROM `ktvs_plugin_rows` p WHERE p.`row_id`=c.`parent_id`)' \
    "$HOOK_STATE/fk-checks.sql" || fail 'self foreign key references the wrong table or column'
[ "$(tail -n 1 "$HOOK_STATE/events")" = finalize ] || fail 'special-table marker preceded validation'
echo 'PASS: format 2, per-table generated/invisible mappings and nullable composite/self foreign keys'

for failure in generated-sql generated-warnings generated-unverified column-mismatch foreign-key-mismatch orphan; do
    reset_hook special
    special_metadata
    case "$failure" in
        generated-sql) SPECIAL_SQL_FAIL=yes ;;
        generated-warnings) SPECIAL_WARNINGS=1 ;;
        generated-unverified) SPECIAL_WARNINGS='' ;;
        column-mismatch) COLUMN_MISMATCH=yes ;;
        foreign-key-mismatch) FK_MISMATCH=yes ;;
        orphan) ORPHAN=yes ;;
    esac
    if run_hook > "$TEST_DIR/$failure.log" 2>&1; then fail "$failure was ignored"; fi
    assert_no_marker "$failure"
    case "$failure" in
        generated-*) [ ! -e "$HOOK_STATE/generated.2.sql" ] || fail 'loading continued after generated SQL failure' ;;
    esac
done
echo 'PASS: generated SQL failures, warnings, metadata preservation and orphan failures prevent completion'

for failure in missing-ordinal bad-column unknown-kind repeated-table missing-table fk-ordinal fk-schema fk-column; do
    reset_hook special
    special_metadata
    case "$failure" in
        missing-ordinal) sed -i '/ktvs_plugin_rows\t2\t/d' "$HOOK_STATE/columns" ;;
        bad-column) sed -i 's/\trow_id\t/\trow`id\t/' "$HOOK_STATE/columns" ;;
        unknown-kind) sed -i 's/\tgenerated\t/\tunknown\t/' "$HOOK_STATE/columns" ;;
        repeated-table) first_column=$(head -n 1 "$HOOK_STATE/columns"); printf '%s\n' "$first_column" >> "$HOOK_STATE/columns" ;;
        missing-table) sed -i 's/^ktvs_plugin_rows/ktvs_missing/' "$HOOK_STATE/columns" ;;
        fk-ordinal) sed -i '/fk_composite\t1\t/d' "$HOOK_STATE/keys" ;;
        fk-schema) sed -i 's/new-site.example/other_database/' "$HOOK_STATE/keys" ;;
        fk-column) sed -i 's/\tvideo_id\tRESTRICT/\tbad`id\tRESTRICT/' "$HOOK_STATE/keys" ;;
    esac
    if run_hook > "$TEST_DIR/$failure.log" 2>&1; then fail "$failure metadata was accepted"; fi
    assert_no_marker "$failure"
    [ ! -e "$HOOK_STATE/loader.1.args" ] || fail "$failure metadata was rejected only after loading"
    [ ! -e "$HOOK_STATE/generated.1.sql" ] || fail "$failure metadata was rejected only after generated SQL loading"
done
echo 'PASS: malformed column and foreign-key metadata is rejected before data loading'
echo 'PASS: native bundle integrity, safe extraction, schema mapping, concurrency and completion gates'
