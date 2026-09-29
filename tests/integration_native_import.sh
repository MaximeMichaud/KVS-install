#!/bin/bash
# Optional real-database coverage; no image pulls or remote Docker connections.
# shellcheck disable=SC2016  # PHP and SQL fixtures contain literal dollar signs.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${DATABASE_TEST_IMAGE:-mariadb:12.3.3}
source_image=${DATABASE_TEST_SOURCE_IMAGE:-$image}
source_database=source-site.example
target_database=dev.example.test
if [ -n "${DOCKER_CONTEXT:-}" ]; then
    endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
else
    endpoint=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}
fi
case "$endpoint" in
    unix://*) ;;
    *) echo 'ERROR: this integration test requires a local Docker socket' >&2; exit 1 ;;
esac
docker image inspect "$image" >/dev/null
docker image inspect "$source_image" >/dev/null
test_dir=$(mktemp -d /tmp/kvs-native-integration.XXXXXX)
fixture="kvs-native-test-$RANDOM-$$"
resource_label=org.kvs.native-integration
resource_token=${test_dir##*/}
password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
containers=()
volumes=()

cleanup() {
    local status=$? item
    if [ "$status" -ne 0 ]; then
        for item in "$test_dir/portable.err" "$test_dir/native.err" "$test_dir/orphan.err" \
            "$test_dir/rejected.log" "$test_dir/legacy-index.log" "$test_dir/constraint.err"; do
            [ ! -f "$item" ] || tail -n 20 "$item" >&2
        done
        for item in "${containers[@]}"; do docker logs --tail 30 "$item" >&2 2>/dev/null || true; done
    fi
    for item in "${containers[@]}"; do
        if [ "$(docker inspect --format "{{index .Config.Labels \"$resource_label\"}}" "$item" 2>/dev/null)" = "$resource_token" ]; then
            docker rm -f "$item" >/dev/null 2>&1 || true
        fi
    done
    for item in "${volumes[@]}"; do
        if [ "$(docker volume inspect --format "{{index .Labels \"$resource_label\"}}" "$item" 2>/dev/null)" = "$resource_token" ]; then
            docker volume rm "$item" >/dev/null 2>&1 || true
        fi
    done
    rm -rf "$test_dir"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

remove_test_container() {
    local container_id owned_id
    container_id=$(docker inspect --format '{{.Id}}' "$1")
    [ "$(docker inspect --format "{{index .Config.Labels \"$resource_label\"}}" "$container_id")" = "$resource_token" ] ||
        fail 'refusing to remove a container not created by this test'
    for owned_id in "${containers[@]}"; do
        if [ "$owned_id" = "$container_id" ]; then
            docker rm -f "$container_id" >/dev/null
            return 0
        fi
    done
    fail 'refusing to remove a container whose ID was not recorded by this test'
}

query() {
    local container=$1
    shift
    timeout 10 docker exec -i "$container" sh -c \
        'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --skip-ssl --connect-timeout=3 --batch --skip-column-names -u root "$@"' sh "$@"
}

wait_ready() {
    local container=$1 attempt
    for ((attempt = 0; attempt < 60; attempt++)); do
        if query "$container" --protocol=tcp -h 127.0.0.1 -e 'SELECT 1;' >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    docker logs --tail 30 "$container" >&2
    fail "$container did not become ready"
}

start_database() {
    local container=$1 init_dir=${2:-} database=${3:-$source_database} database_image=${4:-$image}
    local container_id volume_name
    local -a mounts=()
    [ -z "$init_dir" ] || mounts=(-v "$init_dir:/docker-entrypoint-initdb.d:ro")
    if docker inspect "$container" >/dev/null 2>&1 || docker volume inspect "$container" >/dev/null 2>&1; then
        fail "refusing to reuse an existing test container or volume: $container"
    fi
    volume_name=$(docker volume create --label "$resource_label=$resource_token" "$container")
    [ "$volume_name" = "$container" ] || fail 'Docker returned an unexpected volume name'
    [ "$(docker volume inspect --format "{{index .Labels \"$resource_label\"}}" "$volume_name")" = "$resource_token" ] ||
        fail 'refusing to use a volume not created by this test'
    volumes+=("$volume_name")
    container_id=$(docker create --name "$container" --label "$resource_label=$resource_token" \
        --network none --memory 1g --cpus 2 \
        -e "MARIADB_ROOT_PASSWORD=$password" -e "MARIADB_DATABASE=$database" \
        -v "$volume_name:/var/lib/mysql" "${mounts[@]}" "$database_image" \
        --innodb-buffer-pool-size=128M)
    [ "$(docker inspect --format "{{index .Config.Labels \"$resource_label\"}}" "$container_id")" = "$resource_token" ] ||
        fail 'refusing to use a container not created by this test'
    containers+=("$container_id")
    docker start "$container_id" >/dev/null
}

source_container="$fixture-source"
start_database "$source_container" '' "$source_database" "$source_image"
wait_ready "$source_container"
version=$(query "$source_container" -e 'SELECT VERSION();')
query "$source_container" "$source_database" <<'SQL'
SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'NO_AUTO_VALUE_ON_ZERO');
CREATE TABLE ktvs_videos (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    label VARCHAR(100) NOT NULL,
    payload BLOB,
    optional_value TEXT,
    legacy_label VARCHAR(20) CHARACTER SET latin1,
    UNIQUE KEY label_key(label),
    KEY optional_key(optional_value(20))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO ktvs_videos VALUES
    (0, 'zero identifier', UNHEX('00'), NULL, NULL),
    (1, CONVERT(0x636166c3a9 USING utf8mb4), UNHEX('00090a0d5cff'), NULL, CONVERT(0x636166e9 USING latin1)),
    (2, 'escaped', UNHEX(''), CONVERT(0x5c4e090a0d275c USING utf8mb4), NULL),
    (3, 'null binary', NULL, '', '');
INSERT INTO ktvs_videos SELECT seq+10, CONCAT('row-',seq), UNHEX('00ff'), REPEAT('data',10), 'plain' FROM seq_1_to_2000;
CREATE TABLE ktvs_options (variable VARCHAR(255) PRIMARY KEY, value TEXT NOT NULL) ENGINE=InnoDB;
INSERT INTO ktvs_options VALUES ('fixture','native roundtrip');
CREATE TABLE ktvs_admin_servers (server_id INT PRIMARY KEY, title VARCHAR(100), path VARCHAR(255), is_remote INT, urls TEXT) ENGINE=InnoDB;
INSERT INTO ktvs_admin_servers VALUES (1,'local','/srv/legacy/contents',0,'https://old.example/contents');
CREATE TABLE ktvs_admin_conversion_servers (server_id INT PRIMARY KEY, path VARCHAR(255)) ENGINE=InnoDB;
INSERT INTO ktvs_admin_conversion_servers VALUES (1,'/srv/legacy/conversion');
SQL
query "$source_container" "$source_database" < "$root/tests/fixtures/native-index-schema.sql"
query "$source_container" "$source_database" < "$root/tests/fixtures/native-relations-schema.sql"
index_tables=(ktvs_tags_videos ktvs_native_ai_primary_first ktvs_native_ai_primary_later \
    ktvs_native_ai_no_primary ktvs_native_ai_secondary_composite ktvs_native_ai_generated \
    ktvs_native_ai_ordinary_child ktvs_native_ai_protected_child)
readback_sql="SELECT id,HEX(label),COALESCE(HEX(payload),'NULL'),COALESCE(HEX(optional_value),'NULL'),COALESCE(HEX(legacy_label),'NULL') FROM ktvs_videos ORDER BY id;
SELECT TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX,COLUMN_NAME,NON_UNIQUE,INDEX_TYPE,COALESCE(SUB_PART,0),COALESCE(COLLATION,'') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX;
SELECT TABLE_NAME,COLUMN_NAME,COLUMN_TYPE,EXTRA,GENERATION_EXPRESSION FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND EXTRA LIKE '%GENERATED%' ORDER BY TABLE_NAME,ORDINAL_POSITION;
SELECT TABLE_NAME,CONSTRAINT_NAME,REFERENCED_TABLE_NAME,UPDATE_RULE,DELETE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA=DATABASE() ORDER BY TABLE_NAME,CONSTRAINT_NAME;
SELECT TABLE_NAME,CONSTRAINT_NAME,ORDINAL_POSITION,COLUMN_NAME,REFERENCED_TABLE_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=DATABASE() AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY TABLE_NAME,CONSTRAINT_NAME,ORDINAL_POSITION;
SELECT * FROM ktvs_fixture_a ORDER BY a_id;
SELECT * FROM ktvs_fixture_b ORDER BY b_id;
SELECT * FROM ktvs_fixture_c ORDER BY c_id;"
counter_sql=''
for table in "${index_tables[@]}"; do
    readback_sql+="SELECT '$table',t.* FROM \`$table\` t ORDER BY id;"
    counter_sql+="SELECT TABLE_NAME,AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='$table';"
done
query "$source_container" "$source_database" -e "$readback_sql" > "$test_dir/expected.txt"
query "$source_container" "$source_database" -e "$counter_sql" > "$test_dir/counters-expected.txt"
[ "$(query "$source_container" "$source_database" -e 'SELECT COUNT(*) FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA=DATABASE();')" = 6 ] || fail 'synthetic fixtures must contain six foreign keys'
[ "$(query "$source_container" "$source_database" -e "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND EXTRA LIKE '%GENERATED%';")" = 3 ] || fail 'synthetic fixtures must contain three generated columns'

mkdir -p "$test_dir/site/admin/include"
cat > "$test_dir/site/admin/include/setup.php" <<'PHP'
<?php
$config['project_path']='/srv/legacy';
$config['project_url']='https://old.example';
$config['tables_prefix']='ktvs_';
PHP
cat > "$test_dir/site/admin/include/version.php" <<'PHP'
<?php
/* Developed by Kernel Team. */
$config['project_version']='7.0.2';
PHP
cat > "$test_dir/site/admin/include/setup_db.php" <<PHP
<?php
define('DB_HOST','localhost');
define('DB_LOGIN','root');
define('DB_PASS','$password');
define('DB_DEVICE','$source_database');
PHP
docker cp "$test_dir/site" "$source_container:/tmp/kvs-fixture-site"
docker cp "$root/kvs-export.sh" "$source_container:/tmp/kvs-export.sh"
# Existing system options must not silently turn a portable dump into one-row INSERTs.
docker exec -i "$source_container" sh -c 'cat > /etc/mysql/conf.d/zz-fixture-dump.cnf' <<'CNF'
[mariadb-dump]
skip-extended-insert
skip-disable-keys
net-buffer-length=4096
CNF
timeout 60 docker exec "$source_container" bash /tmp/kvs-export.sh --no-size --gzip --database-format=sql dump /tmp/kvs-fixture-site \
    > "$test_dir/portable.sql.gz" 2> "$test_dir/portable.err"
gzip -dc "$test_dir/portable.sql.gz" > "$test_dir/portable.sql"
insert_count=$(grep -c '^INSERT INTO `ktvs_videos`' "$test_dir/portable.sql")
[ "$insert_count" -lt 20 ] || fail "inherited option files produced $insert_count INSERTs for 2,004 rows"
grep -iEq '^SET[[:space:]]+(@OLD_AUTOCOMMIT=@@AUTOCOMMIT,[[:space:]]*)?(@@)?AUTOCOMMIT=0;' "$test_dir/portable.sql" || fail 'portable dump lost transaction grouping'
grep -q '^COMMIT;' "$test_dir/portable.sql" || fail 'portable dump lost transaction commits'
grep -q '^SET AUTOCOMMIT=@OLD_AUTOCOMMIT;' "$test_dir/portable.sql" || fail 'portable dump did not restore autocommit'
grep -q 'ALTER TABLE `ktvs_videos` DISABLE KEYS' "$test_dir/portable.sql" || fail 'portable dump lost key batching'
query "$source_container" -e 'CREATE DATABASE portable_check;'
query "$source_container" portable_check < "$test_dir/portable.sql"
query "$source_container" portable_check -e "$readback_sql" > "$test_dir/portable-actual.txt"
diff -u "$test_dir/expected.txt" "$test_dir/portable-actual.txt"
echo "PASS: MariaDB $version portable export overrides inherited slow dump options (INSERT count: $insert_count; rows: 2,004)."

timeout 60 docker exec "$source_container" bash /tmp/kvs-export.sh --no-size --gzip --database-format=directory dump /tmp/kvs-fixture-site \
    > "$test_dir/native.mariadb.tar.gz" 2> "$test_dir/native.err"
# Produce a checksummed but inconsistent snapshot to exercise final FK checks.
query "$source_container" "$source_database" <<'SQL'
SET SESSION foreign_key_checks=0;
INSERT INTO ktvs_fixture_c VALUES (99,999,NULL);
SQL
timeout 60 docker exec "$source_container" bash /tmp/kvs-export.sh --no-size --gzip --database-format=directory dump /tmp/kvs-fixture-site \
    > "$test_dir/orphan.mariadb.tar.gz" 2> "$test_dir/orphan.err"
remove_test_container "$source_container"

# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
# shellcheck source=/dev/null
source "$root/docker/lib/native-import.sh"
inspection=$(native_import_inspect "$test_dir/native.mariadb.tar.gz" ktvs_)
[ "$(import_field "$inspection" 1)" = 15 ] || fail 'native inspection lost one of the fifteen tables'

mkdir "$test_dir/unpacked"
tar -xzf "$test_dir/native.mariadb.tar.gz" -C "$test_dir/unpacked" --no-same-owner
grep -Fxq "source_database=$source_database" "$test_dir/unpacked/kvs-native-export.manifest" ||
    fail 'native export replaced the SQL database name with its encoded filesystem name'

# The unprotected client removes the secondary key required by AUTO_INCREMENT.
legacy_container="$fixture-legacy-index"
start_database "$legacy_container" '' "$target_database"
wait_ready "$legacy_container"
mkdir -p "$test_dir/legacy-cli/$target_database"
cp "$test_dir/unpacked/data/ktvs_tags_videos.sql" "$test_dir/unpacked/data/ktvs_tags_videos.txt" \
    "$test_dir/legacy-cli/$target_database/"
docker cp "$test_dir/legacy-cli" "$legacy_container:/tmp/kvs-native-legacy"
if timeout 60 docker exec "$legacy_container" sh -c \
    'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-import --no-defaults --user=root --protocol=socket --dir=/tmp/kvs-native-legacy --parallel=1 --innodb-optimize-keys --verbose' \
    > "$test_dir/legacy-index.log" 2>&1; then
    echo 'INFO: this client already handles the secondary AUTO_INCREMENT index; preservation tests still run.'
else
    grep -Eq '(^|[^0-9])1075([^0-9]|$)' "$test_dir/legacy-index.log" || {
        cat "$test_dir/legacy-index.log" >&2
        fail 'the unprotected native loader failed for a reason other than AUTO_INCREMENT error 1075'
    }
    echo 'PASS: the unprotected native client reproduces error 1075 on the secondary AUTO_INCREMENT index.'
fi
remove_test_container "$legacy_container"

repack() {
    local directory=$1 output=$2
    (
        cd "$directory"
        sha256sum kvs-native-export.manifest data/* > SHA256SUMS
        tar -czf "$output" kvs-native-export.manifest SHA256SUMS data
    )
}
cp -a "$test_dir/unpacked" "$test_dir/incomplete"
sed -i 's/^complete=yes$/complete=no/' "$test_dir/incomplete/kvs-native-export.manifest"
repack "$test_dir/incomplete" "$test_dir/incomplete.mariadb.tar.gz"
if native_import_inspect "$test_dir/incomplete.mariadb.tar.gz" ktvs_ > "$test_dir/rejected.log" 2>&1; then
    fail 'an incomplete native bundle was accepted'
fi
cp -a "$test_dir/unpacked" "$test_dir/corrupt"
printf '\n-- corrupted schema\n' >> "$test_dir/corrupt/data/ktvs_videos.sql"
tar -czf "$test_dir/corrupt.mariadb.tar.gz" -C "$test_dir/corrupt" kvs-native-export.manifest SHA256SUMS data
if native_import_prepare "$test_dir/corrupt.mariadb.tar.gz" ktvs_ 7.0.2 /srv/legacy /var/www/kvs \
    "$test_dir/rejected-stage" rejected "$target_database" 4 >> "$test_dir/rejected.log" 2>&1; then
    fail 'a native bundle with invalid checksums was accepted'
fi
[ ! -e "$test_dir/rejected-stage.sh" ] || fail 'a corrupt native bundle published an initialization hook'
head -c 128 "$test_dir/native.mariadb.tar.gz" > "$test_dir/truncated.mariadb.tar.gz"
if native_import_inspect "$test_dir/truncated.mariadb.tar.gz" ktvs_ >> "$test_dir/rejected.log" 2>&1; then
    fail 'a truncated native bundle was accepted'
fi
echo 'PASS: incomplete, corrupted and truncated native exports are rejected before restoration.'

mkdir "$test_dir/init"
native_import_prepare "$test_dir/native.mariadb.tar.gz" ktvs_ 7.0.2 /srv/legacy /var/www/kvs \
    "$test_dir/init/10-kvs-import-native" native-roundtrip "$target_database" 4 >/dev/null
target_container="$fixture-target"
start_database "$target_container" "$test_dir/init" "$target_database"
wait_ready "$target_container"
target_version=$(query "$target_container" -e 'SELECT VERSION();')
query "$target_container" "$target_database" -e "$readback_sql" > "$test_dir/actual.txt"
diff -u "$test_dir/expected.txt" "$test_dir/actual.txt"
query "$target_container" "$target_database" -e "$counter_sql" > "$test_dir/counters-actual.txt"
diff -u "$test_dir/counters-expected.txt" "$test_dir/counters-actual.txt"
for table in ktvs_videos "${index_tables[@]}"; do
    [ "$(query "$target_container" "$target_database" -e "SELECT COUNT(*) FROM \`$table\` WHERE id=0;")" = 1 ] ||
        fail "$table silently renumbered an explicit AUTO_INCREMENT zero"
done
[ "$(query "$target_container" "$target_database" -e "SELECT value FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';")" = native-roundtrip ] || fail 'completion marker was not persisted'
[ "$(query "$target_container" "$target_database" -e "SELECT value FROM ktvs_options WHERE variable='INITIAL_VERSION';")" = 7.0.2 ] || fail 'KVS version was not recorded'
[ "$(query "$target_container" "$target_database" -e "SELECT value FROM ktvs_options WHERE variable='fixture';")" = 'native roundtrip' ] || fail 'source option data was not preserved'
[ "$(query "$target_container" "$target_database" -e 'SELECT path FROM ktvs_admin_servers;')" = /var/www/kvs/contents ] || fail 'storage path was not rewritten'
[ "$(query "$target_container" "$target_database" -e 'SELECT path FROM ktvs_admin_conversion_servers;')" = /var/www/kvs/conversion ] || fail 'conversion path was not rewritten'
[ "$(query "$target_container" -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$source_database';")" = 0 ] || fail 'the source database name leaked into the destination'

docker restart --time 30 "$target_container" >/dev/null
wait_ready "$target_container"
query "$target_container" "$target_database" -e "$readback_sql" > "$test_dir/restarted.txt"
diff -u "$test_dir/expected.txt" "$test_dir/restarted.txt"
query "$target_container" "$target_database" -e "$counter_sql" > "$test_dir/counters-restarted.txt"
diff -u "$test_dir/counters-expected.txt" "$test_dir/counters-restarted.txt"

expect_sql_error() {
    local code=$1 sql=$2
    if query "$target_container" "$target_database" -e "$sql" > "$test_dir/constraint.err" 2>&1; then
        fail "expected SQL error $code, but the write succeeded"
    fi
    grep -Eq "ERROR $code([[:space:]]|$)" "$test_dir/constraint.err" || {
        cat "$test_dir/constraint.err" >&2
        fail "the write failed for a reason other than SQL error $code"
    }
}
# Explicit small IDs in failed writes do not consume reserved counters.
expect_sql_error 1062 'INSERT INTO ktvs_tags_videos(id,tag_id,video_id) VALUES (7,99,99);'
expect_sql_error 1452 "INSERT INTO ktvs_native_ai_ordinary_child(id,tag_link,label) VALUES (99,999,'orphan');"
expect_sql_error 1452 "INSERT INTO ktvs_native_ai_generated(id,tenant_id,label,quantity,tag_link) VALUES (99,99,'orphan',2,999);"
expect_sql_error 1452 "INSERT INTO ktvs_native_ai_protected_child(id,group_id,child_link,label) VALUES (99,99,999,'orphan');"
expect_sql_error 1452 'INSERT INTO ktvs_fixture_b(b_id,a_id,a_x,x) VALUES (99,1,999,1);'
expect_sql_error 1452 'INSERT INTO ktvs_fixture_c VALUES (99,1,999);'

behavior=$(query "$target_container" "$target_database" <<'SQL'
START TRANSACTION;
UPDATE ktvs_fixture_a SET x=4 WHERE a_id=1;
UPDATE ktvs_fixture_b SET x=9 WHERE b_id=1;
SELECT CONCAT('arithmetic=',
 (SELECT doubled FROM ktvs_fixture_a WHERE a_id=1), ':',
 (SELECT doubled FROM ktvs_fixture_b WHERE b_id=1), ':',
 (SELECT a_x FROM ktvs_fixture_b WHERE b_id=1));
DELETE FROM ktvs_fixture_c WHERE c_id=1;
SELECT CONCAT('self-null=',parent_id IS NULL) FROM ktvs_fixture_c WHERE c_id=2;
DELETE FROM ktvs_fixture_a WHERE a_id=2;
SELECT CONCAT('cascade=',
 (SELECT COUNT(*) FROM ktvs_fixture_b WHERE b_id=2), ':',
 (SELECT COUNT(*) FROM ktvs_fixture_c WHERE c_id=2));
ROLLBACK;
SQL
)
[ "$behavior" = $'arithmetic=8:18:4\nself-null=1\ncascade=0:0' ] || fail "synthetic arithmetic or FK actions changed: $behavior"
query "$target_container" "$target_database" -e "$readback_sql" > "$test_dir/after-behavior.txt"
diff -u "$test_dir/expected.txt" "$test_dir/after-behavior.txt"

next_inserts=(
    'INSERT INTO ktvs_tags_videos(tag_id,video_id) VALUES (901,901);'
    "INSERT INTO ktvs_native_ai_primary_first(tenant_id,label) VALUES (901,'next identifier');"
    "INSERT INTO ktvs_native_ai_primary_later(tenant_id,label) VALUES (901,'next identifier');"
    "INSERT INTO ktvs_native_ai_no_primary(label) VALUES ('next identifier');"
    "INSERT INTO ktvs_native_ai_secondary_composite(tenant_id,label) VALUES (901,'next identifier');"
    "INSERT INTO ktvs_native_ai_generated(tenant_id,label,quantity,tag_link) VALUES (901,'next identifier',25,7);"
    "INSERT INTO ktvs_native_ai_ordinary_child(tag_link,label) VALUES (7,'next identifier');"
    "INSERT INTO ktvs_native_ai_protected_child(group_id,child_link,label) VALUES (901,7,'next identifier');"
)
for ((index=0; index<${#index_tables[@]}; index++)); do
    expected_id=$((1000 + index))
    actual_id=$(query "$target_container" "$target_database" -e "${next_inserts[$index]} SELECT LAST_INSERT_ID();")
    [ "$actual_id" = "$expected_id" ] || fail "${index_tables[$index]} allocated $actual_id instead of preserved counter $expected_id"
done
docker restart --time 30 "$target_container" >/dev/null
wait_ready "$target_container"
for ((index=0; index<${#index_tables[@]}; index++)); do
    table=${index_tables[$index]}
    [ "$(query "$target_container" "$target_database" -e "SELECT COUNT(*) FROM \`$table\` WHERE id IN (0,$((1000 + index)));")" = 2 ] ||
        fail "$table did not persist its zero and newly allocated identifier"
done
[ "$(query "$target_container" "$target_database" -e "SELECT doubled FROM ktvs_native_ai_generated WHERE label='next identifier';")" = 50 ] ||
    fail 'the protected AUTO_INCREMENT table lost its generated expression'
remove_test_container "$target_container"
echo "PASS: MariaDB $version -> $target_version preserves bytes, indexes, generated arithmetic, foreign keys, AUTO_INCREMENT zeros and reserved counters across restarts."

# Checksums are valid, but the SQL cannot execute: the runtime must fail closed.
cp -a "$test_dir/unpacked" "$test_dir/sql-failure"
sed -i 's/ENGINE=InnoDB/KVS_INVALID_SQL/g' "$test_dir/sql-failure/data/ktvs_videos.sql"
grep -q KVS_INVALID_SQL "$test_dir/sql-failure/data/ktvs_videos.sql" || fail 'the invalid SQL fixture was not constructed'
repack "$test_dir/sql-failure" "$test_dir/sql-failure.mariadb.tar.gz"
mkdir "$test_dir/failed-init"
native_import_prepare "$test_dir/sql-failure.mariadb.tar.gz" ktvs_ 7.0.2 /srv/legacy /var/www/kvs \
    "$test_dir/failed-init/10-kvs-import-native" must-not-exist failed-site.example 4 >/dev/null
failed_container="$fixture-failed"
start_database "$failed_container" "$test_dir/failed-init" failed-site.example
exited=no
for ((attempt = 0; attempt < 60; attempt++)); do
    if [ "$(docker inspect --format '{{.State.Status}}' "$failed_container")" = exited ]; then exited=yes; break; fi
    sleep 1
done
[ "$exited" = yes ] || fail 'a failed native restore did not stop initialization'
[ "$(docker inspect --format '{{.State.ExitCode}}' "$failed_container")" != 0 ] || fail 'a failed native restore returned success'
docker logs "$failed_container" > "$test_dir/failed-init.log" 2>&1
# Official entrypoint skips init on the next start; the marker must still be absent.
docker start "$failed_container" >/dev/null
wait_ready "$failed_container"
options_exists=$(query "$failed_container" -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='failed-site.example' AND TABLE_NAME='ktvs_options';")
if [ "$options_exists" = 1 ]; then
    [ "$(query "$failed_container" failed-site.example -e "SELECT COUNT(*) FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';")" = 0 ] || fail 'a failed restore wrote a completion marker'
fi
echo 'PASS: a SQL restore failure exits unsuccessfully and leaves no completion marker after restart.'

mkdir "$test_dir/orphan-init"
native_import_prepare "$test_dir/orphan.mariadb.tar.gz" ktvs_ 7.0.2 /srv/legacy /var/www/kvs \
    "$test_dir/orphan-init/10-kvs-import-native" must-not-exist orphan-site.example 4 >/dev/null
orphan_container="$fixture-orphan"
start_database "$orphan_container" "$test_dir/orphan-init" orphan-site.example
exited=no
for ((attempt = 0; attempt < 60; attempt++)); do
    if [ "$(docker inspect --format '{{.State.Status}}' "$orphan_container")" = exited ]; then exited=yes; break; fi
    sleep 1
done
[ "$exited" = yes ] || fail 'an inconsistent native restore did not stop initialization'
[ "$(docker inspect --format '{{.State.ExitCode}}' "$orphan_container")" != 0 ] || fail 'an inconsistent native restore returned success'
docker start "$orphan_container" >/dev/null
wait_ready "$orphan_container"
[ "$(query "$orphan_container" orphan-site.example -e 'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE();')" = 15 ] || fail 'orphan test failed before creating all tables'
[ "$(query "$orphan_container" orphan-site.example -e 'SELECT COUNT(*) FROM ktvs_fixture_c WHERE c_id=99 AND b_id=999;')" = 1 ] || fail 'orphan test failed before loading the inconsistent row'
[ "$(query "$orphan_container" orphan-site.example -e 'SELECT COUNT(*) FROM ktvs_videos;')" = 2004 ] || fail 'orphan test failed before completing ordinary table loading'
[ "$(query "$orphan_container" orphan-site.example -e 'SELECT COUNT(*) FROM ktvs_native_ai_generated;')" = 3 ] || fail 'orphan test failed before completing preserved-index table loading'
[ "$(query "$orphan_container" orphan-site.example -e "SELECT COUNT(*) FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';")" = 0 ] || fail 'an orphaned native restore wrote a completion marker'
echo 'PASS: a checksummed export with an orphan finishes loading but fails validation and never receives a completion marker, including after restart.'
