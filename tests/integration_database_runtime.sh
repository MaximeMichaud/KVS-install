#!/bin/bash
# shellcheck disable=SC2034  # Consumed by the sourced monitoring functions.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# This optional integration test uses a cached image and an isolated network.
# Run manually: tests/run.sh does not run it.
default_version=$(sed -n 's/^MARIADB_VERSION=//p' "$root/docker/.env.example")
export DATABASE_TEST_IMAGE="${DATABASE_TEST_IMAGE:-mariadb:$default_version}"
export DATABASE_TEST_ROOT_PASSWORD
DATABASE_TEST_ROOT_PASSWORD=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
export DATABASE_TEST_POOL="${DATABASE_TEST_POOL:-256M}"
export DATABASE_TEST_REDO="${DATABASE_TEST_REDO:-128M}"
umask 077
test_dir=$(mktemp -d /tmp/kvs-db-integration.XXXXXX)
export COMPOSE_PROJECT_NAME="kvs-db-runtime-$RANDOM"
cleanup() {
    docker compose -f "$test_dir/compose.yml" down -v >/dev/null 2>&1 || true
    rm -rf "$test_dir"
}
trap cleanup EXIT
mkdir -m 755 "$test_dir/init"
printf '%s\n' \
    'DOMAIN=fixture.example' \
    "MARIADB_ROOT_PASSWORD=$DATABASE_TEST_ROOT_PASSWORD" \
    "MARIADB_PASSWORD=$DATABASE_TEST_ROOT_PASSWORD" \
    "MARIADB_BUFFER_POOL_SIZE=$DATABASE_TEST_POOL" \
    "MARIADB_REDO_LOG_SIZE=$DATABASE_TEST_REDO" > "$test_dir/.env"
# Render the real service command from a fresh environment-file read. Only
# its argument list leaves the pipe; the full configuration is never saved.
production_command=$(
    (
        unset DOMAIN MARIADB_ROOT_PASSWORD MARIADB_PASSWORD
        unset MARIADB_BUFFER_POOL_SIZE MARIADB_REDO_LOG_SIZE
        docker compose --env-file "$test_dir/.env" \
            -f "$root/docker/docker-compose.yml" config --format json
    ) | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["services"]["mariadb"]["command"]))'
)
python3 - "$production_command" "$test_dir/compose.yml" "$DATABASE_TEST_POOL" "$DATABASE_TEST_REDO" <<'PY'
import json
import sys

command = json.loads(sys.argv[1])
assert isinstance(command, list), "MariaDB command must be an argument list"
assert f"--innodb-buffer-pool-size={sys.argv[3]}" in command, "Production Compose lost the buffer pool setting"
assert f"--innodb-log-file-size={sys.argv[4]}" in command, "Production Compose lost the redo setting"
fixture = {
    "services": {
        "mariadb": {
            "image": "${DATABASE_TEST_IMAGE}",
            "network_mode": "none",
            "mem_limit": "1g",
            "command": command,
            "environment": {
                "MARIADB_ROOT_PASSWORD": "${DATABASE_TEST_ROOT_PASSWORD}",
                "MARIADB_DATABASE": "fixture",
            },
            "volumes": ["./init:/docker-entrypoint-initdb.d:ro", "data:/var/lib/mysql"],
        },
    },
    "volumes": {"data": {}},
}
with open(sys.argv[2], "w") as output:
    json.dump(fixture, output, indent=2)
    output.write("\n")
PY
docker image inspect "$DATABASE_TEST_IMAGE" >/dev/null
python3 - "$test_dir/source.sql" <<'PY'
import sys
with open(sys.argv[1], 'w') as f:
    f.write('CREATE TABLE ktvs_videos (id INT PRIMARY KEY, title TEXT) ENGINE=InnoDB;\n')
    f.write('CREATE TABLE ktvs_options (variable VARCHAR(64) PRIMARY KEY,value TEXT) ENGINE=InnoDB;\n')
    f.write("INSERT INTO ktvs_videos VALUES (0,'runtime sentinel');\nSELECT SLEEP(20);\nSET autocommit=0;\n")
    for i in range(1,20000):
        f.write(f"INSERT INTO ktvs_videos VALUES ({i},'{('fixture ' * 20).strip()}');\n")
    f.write("COMMIT;\n")
PY
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
if command -v zstd >/dev/null; then
    import_prepare_dump "$test_dir/source.sql" ktvs_ 7.0.2 /var/www/kvs /var/www/kvs "$test_dir/init/10-kvs-import.sql.zst" runtime-roundtrip >/dev/null
else
    import_prepare_dump "$test_dir/source.sql" ktvs_ 7.0.2 /var/www/kvs /var/www/kvs "$test_dir/init/10-kvs-import.sql" runtime-roundtrip >/dev/null
    gzip "$test_dir/init/10-kvs-import.sql"
fi
# The official entrypoint reads this synthetic fixture as its mysql user.
chmod 644 "$test_dir/init/"*
cd "$test_dir"
export COMPOSE_FILE="$test_dir/compose.yml"
# shellcheck source=/dev/null
source "$root/docker/lib/database.sh"
DOMAIN=fixture
TABLES_PREFIX=ktvs_
IMPORT_DUMP_TABLES=2
[ "$(database_compose_memory_limit)" = 1073741824 ]
docker compose up -d --pull never >/dev/null
seen=no
for attempt in $(seq 1 30); do
    snapshot=$(database_import_snapshot) || true
    if [[ "$snapshot" == *$'tables\t2'* ]]; then seen=yes; break; fi
    sleep 1
done
[ "$seen" = yes ] || { docker compose logs --tail 30; exit 1; }
if database_root_query -h 127.0.0.1 --protocol=tcp -e 'SELECT 1' >/dev/null 2>&1; then
    echo 'FAIL: init replay already accepts TCP'; exit 1
fi
position=$(database_dump_position)
database_progress_line 0 "$snapshot" "$position"
expected_pool=$(numfmt --from=iec "$DATABASE_TEST_POOL")
expected_redo=$(numfmt --from=iec "$DATABASE_TEST_REDO")
[[ "$snapshot" == *$'pool\t'"$expected_pool"* ]]
initial_settings=$(database_root_query --batch --skip-column-names \
    -e 'SELECT @@GLOBAL.innodb_buffer_pool_size, @@GLOBAL.innodb_log_file_size, @@GLOBAL.innodb_flush_log_at_trx_commit;')
[ "$initial_settings" = "$(printf '%s\t%s\t1' "$expected_pool" "$expected_redo")" ]
[ -n "$position" ]
database_wait_ready 120
verify_database_state() {
    local actual expected
    actual=$(database_root_query --batch --skip-column-names --database=fixture -e "
SELECT @@GLOBAL.innodb_buffer_pool_size,
       @@GLOBAL.innodb_log_file_size,
       @@GLOBAL.innodb_flush_log_at_trx_commit,
       (SELECT value FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT'),
       (SELECT COUNT(*) FROM ktvs_videos),
       (SELECT title FROM ktvs_videos WHERE id=0);")
    expected=$(printf '%s\t%s\t1\truntime-roundtrip\t20000\truntime sentinel' "$expected_pool" "$expected_redo")
    [ "$actual" = "$expected" ] || {
        printf 'FAIL: Runtime settings or persisted import data differ: %s\n' "$actual" >&2
        return 1
    }
}
verify_database_state
version=$(database_root_query --batch --skip-column-names -e 'SELECT VERSION();')
# A real restart discards runtime SET GLOBAL values. Read all settings and
# imported data through a new client after bounded TCP readiness succeeds.
docker compose restart --timeout 30 mariadb >/dev/null
database_wait_ready 120
verify_database_state
echo "PASS: MariaDB $version uses the production Compose command during replay and after restart: $DATABASE_TEST_POOL pool, $DATABASE_TEST_REDO redo, durable commits, completion marker and 20,000 rows with the sentinel preserved."
