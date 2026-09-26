#!/bin/bash
# shellcheck disable=SC2034  # Consumed by the sourced monitoring functions.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# This optional integration test uses a cached image and an isolated network.
# Run manually; tests/run.sh does not require Docker.
export DATABASE_TEST_IMAGE="${DATABASE_TEST_IMAGE:-mariadb:11.4}"
docker image inspect "$DATABASE_TEST_IMAGE" >/dev/null
test_dir=$(mktemp -d /tmp/kvs-db-integration.XXXXXX)
export COMPOSE_PROJECT_NAME="kvs-db-runtime-$RANDOM"
cleanup() {
    docker compose -f "$test_dir/compose.yml" down -v >/dev/null 2>&1 || true
    rm -rf "$test_dir"
}
trap cleanup EXIT
mkdir "$test_dir/init"
cat > "$test_dir/compose.yml" <<'YAML'
services:
  mariadb:
    image: ${DATABASE_TEST_IMAGE:-mariadb:11.4}
    network_mode: none
    mem_limit: 1g
    command: ["--innodb-buffer-pool-size=256M"]
    environment:
      MARIADB_ALLOW_EMPTY_ROOT_PASSWORD: 'yes'  # pragma: allowlist secret
      MARIADB_ROOT_PASSWORD: ''
      MARIADB_DATABASE: fixture
    volumes:
      - ./init:/docker-entrypoint-initdb.d:ro
      - data:/var/lib/mysql
volumes:
  data:
YAML
python3 - "$test_dir/init/10-kvs-import.sql" <<'PY'
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
import_prepare_dump "$test_dir/init/10-kvs-import.sql" ktvs_ 7.0.2 /var/www/kvs /var/www/kvs "$test_dir/prepared.sql" runtime-roundtrip >/dev/null
mv "$test_dir/prepared.sql" "$test_dir/init/10-kvs-import.sql"
gzip "$test_dir/init/10-kvs-import.sql"
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
[[ "$snapshot" == *$'pool\t268435456'* ]]
[ -n "$position" ]
database_wait_ready 120
marker=$(database_root_query --batch --skip-column-names --database=fixture -e "SELECT value FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';")
[ "$marker" = runtime-roundtrip ]
rows=$(database_root_query --batch --skip-column-names --database=fixture -e 'SELECT COUNT(*) FROM ktvs_videos;')
[ "$rows" = 20000 ]
echo "PASS: real MariaDB replay, socket monitoring, compressed reader position, 256 MiB pool, TCP readiness and persisted completion marker ($rows rows)."
