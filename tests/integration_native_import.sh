#!/bin/bash
# Optional real-database coverage; no image pulls or remote Docker connections.
# shellcheck disable=SC2016  # PHP and SQL fixtures contain literal dollar signs.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${DATABASE_TEST_IMAGE:-mariadb:12.3.3}
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
test_dir=$(mktemp -d /tmp/kvs-native-integration.XXXXXX)
fixture="kvs-native-test-$RANDOM-$$"
password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
containers=()
volumes=()

cleanup() {
    local status=$? item
    if [ "$status" -ne 0 ]; then
        for item in "$test_dir/portable.err" "$test_dir/native.err" "$test_dir/rejected.log"; do
            [ ! -f "$item" ] || tail -n 20 "$item" >&2
        done
        for item in "${containers[@]}"; do docker logs --tail 30 "$item" >&2 2>/dev/null || true; done
    fi
    for item in "${containers[@]}"; do docker rm -f "$item" >/dev/null 2>&1 || true; done
    for item in "${volumes[@]}"; do docker volume rm "$item" >/dev/null 2>&1 || true; done
    rm -rf "$test_dir"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

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
    local container=$1 init_dir=${2:-} database=${3:-old_source}
    local -a mounts=()
    [ -z "$init_dir" ] || mounts=(-v "$init_dir:/docker-entrypoint-initdb.d:ro")
    containers+=("$container")
    volumes+=("$container")
    docker volume create "$container" >/dev/null
    docker run -d --name "$container" --network none --memory 1g --cpus 2 \
        -e "MARIADB_ROOT_PASSWORD=$password" -e "MARIADB_DATABASE=$database" \
        -v "$container:/var/lib/mysql" "${mounts[@]}" "$image" \
        --innodb-buffer-pool-size=128M >/dev/null
}

source_container="$fixture-source"
start_database "$source_container"
wait_ready "$source_container"
version=$(query "$source_container" -e 'SELECT VERSION();')
query "$source_container" old_source <<'SQL'
CREATE TABLE ktvs_videos (
    id INT PRIMARY KEY,
    label VARCHAR(100) NOT NULL,
    payload BLOB,
    optional_value TEXT,
    legacy_label VARCHAR(20) CHARACTER SET latin1,
    UNIQUE KEY label_key(label),
    KEY optional_key(optional_value(20))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO ktvs_videos VALUES
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
readback_sql="SELECT id,HEX(label),COALESCE(HEX(payload),'NULL'),COALESCE(HEX(optional_value),'NULL'),COALESCE(HEX(legacy_label),'NULL') FROM ktvs_videos ORDER BY id;
SELECT TABLE_NAME,INDEX_NAME,COLUMN_NAME,NON_UNIQUE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX;"
query "$source_container" old_source -e "$readback_sql" > "$test_dir/expected.txt"

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
define('DB_DEVICE','old_source');
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
[ "$insert_count" -lt 20 ] || fail "inherited option files produced $insert_count INSERTs for 2,003 rows"
grep -iEq '^SET[[:space:]]+(@OLD_AUTOCOMMIT=@@AUTOCOMMIT,[[:space:]]*)?(@@)?AUTOCOMMIT=0;' "$test_dir/portable.sql" || fail 'portable dump lost transaction grouping'
grep -q '^COMMIT;' "$test_dir/portable.sql" || fail 'portable dump lost transaction commits'
grep -q '^SET AUTOCOMMIT=@OLD_AUTOCOMMIT;' "$test_dir/portable.sql" || fail 'portable dump did not restore autocommit'
grep -q 'ALTER TABLE `ktvs_videos` DISABLE KEYS' "$test_dir/portable.sql" || fail 'portable dump lost key batching'
query "$source_container" -e 'CREATE DATABASE portable_check;'
query "$source_container" portable_check < "$test_dir/portable.sql"
query "$source_container" portable_check -e "$readback_sql" > "$test_dir/portable-actual.txt"
diff -u "$test_dir/expected.txt" "$test_dir/portable-actual.txt"
echo "PASS: MariaDB $version portable export overrides inherited slow dump options (INSERT count: $insert_count; rows: 2,003)."

timeout 60 docker exec "$source_container" bash /tmp/kvs-export.sh --no-size --gzip --database-format=directory dump /tmp/kvs-fixture-site \
    > "$test_dir/native.mariadb.tar.gz" 2> "$test_dir/native.err"
docker rm -f "$source_container" >/dev/null

# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
# shellcheck source=/dev/null
source "$root/docker/lib/native-import.sh"
inspection=$(native_import_inspect "$test_dir/native.mariadb.tar.gz" ktvs_)
[ "$(import_field "$inspection" 1)" = 4 ] || fail 'native inspection lost one of the four tables'

mkdir "$test_dir/unpacked"
tar -xzf "$test_dir/native.mariadb.tar.gz" -C "$test_dir/unpacked" --no-same-owner
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
    "$test_dir/rejected-stage" rejected new-site.example 4 >> "$test_dir/rejected.log" 2>&1; then
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
    "$test_dir/init/10-kvs-import-native" native-roundtrip new-site.example 4 >/dev/null
target_container="$fixture-target"
start_database "$target_container" "$test_dir/init" new-site.example
wait_ready "$target_container"
query "$target_container" new-site.example -e "$readback_sql" > "$test_dir/actual.txt"
diff -u "$test_dir/expected.txt" "$test_dir/actual.txt"
[ "$(query "$target_container" new-site.example -e "SELECT value FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';")" = native-roundtrip ] || fail 'completion marker was not persisted'
[ "$(query "$target_container" new-site.example -e "SELECT value FROM ktvs_options WHERE variable='INITIAL_VERSION';")" = 7.0.2 ] || fail 'KVS version was not recorded'
[ "$(query "$target_container" new-site.example -e "SELECT value FROM ktvs_options WHERE variable='fixture';")" = 'native roundtrip' ] || fail 'source option data was not preserved'
[ "$(query "$target_container" new-site.example -e 'SELECT path FROM ktvs_admin_servers;')" = /var/www/kvs/contents ] || fail 'storage path was not rewritten'
[ "$(query "$target_container" new-site.example -e 'SELECT path FROM ktvs_admin_conversion_servers;')" = /var/www/kvs/conversion ] || fail 'conversion path was not rewritten'
[ "$(query "$target_container" -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='old_source';")" = 0 ] || fail 'the source database name leaked into the destination'
docker rm -f "$target_container" >/dev/null
echo "PASS: MariaDB $version native entrypoint import preserves text, binary bytes, NULLs and indexes; remaps the database and paths; persists the final marker."

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
