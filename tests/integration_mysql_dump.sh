#!/bin/bash
# Pass one source_image from the tests workflow. Only --pull downloads images.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pull=false
if [[ ${1:-} == --pull ]]; then pull=true; shift; fi
unavailable() {
    if "$pull"; then fail "$*"; fi
    echo "SKIP: $*"
    exit 0
}
[[ $# != 0 ]] || unavailable 'pass a pinned MySQL source image from the tests workflow'
[[ $# == 1 && $1 =~ ^mysql:(8\.4|5\.7\.44)@sha256:[0-9a-f]{64}$ ]] || fail 'expected one pinned MySQL source image'
source_image=$1
dest_image=$("$root/docker/bin/resolve-bases.sh" --get mariadb 11.4)
docker info >/dev/null 2>&1 || unavailable 'the MySQL dump replay needs Docker'
for image in "$source_image" "$dest_image"; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        "$pull" || unavailable "image $image is missing locally"
        docker pull --platform linux/amd64 "$image"
    fi
done

work=$(mktemp -d)
src=''
dest=''
cleanup() {
    set +e
    for id in "$src" "$dest"; do
        if [[ -n $id ]]; then docker rm -fv "$id" >/dev/null; fi
    done
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
common=(--pull never --platform linux/amd64 --network none)
src=$(docker create "${common[@]}" -e MYSQL_ALLOW_EMPTY_PASSWORD=yes -e MYSQL_DATABASE=kvs "$source_image")
dest=$(docker create "${common[@]}" -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=yes -e MARIADB_DATABASE=kvs "$dest_image" --sql-mode=STRICT_ALL_TABLES)
docker start "$src" "$dest" >/dev/null

wait_db() {
    local id=$1 client=$2 deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
        # The temporary initialization server does not listen on TCP.
        if docker exec "$id" "$client" --connect-timeout=2 --protocol=tcp -h127.0.0.1 -uroot kvs -e 'SELECT 1' >/dev/null 2>&1; then return; fi
        [[ $(docker inspect -f '{{.State.Running}}' "$id") == true ]] || break
        sleep 1
    done
    docker logs --tail 30 "$id" >&2
    fail "$client did not become ready"
}
wait_db "$src" mysql
wait_db "$dest" mariadb
docker exec -i "$src" mysql -uroot kvs <<'SQL'
SET SESSION sql_mode='STRICT_ALL_TABLES,ALLOW_INVALID_DATES';
CREATE TABLE ktvs_options (variable varchar(64) PRIMARY KEY, value text) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
CREATE TABLE ktvs_articles (id int PRIMARY KEY, title text, body text, published date,
  FULLTEXT KEY search_text (title,body) WITH PARSER ngram) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
INSERT INTO ktvs_articles VALUES (1,'First','Calendar','2024-02-31'),(2,'Next','Issue','2024-03-01');
SQL
docker exec "$src" mysqldump --single-transaction --set-gtid-purged=OFF -uroot kvs > "$work/source.sql"
grep -Eiq 'WITH PARSER `?ngram' "$work/source.sql" || fail 'source dump lacks the ngram parser'
prepare_status=0
import_prepare_dump "$work/source.sql" ktvs_ 7.0.2 /site /site "$work/prepared.sql" mysql-replay \
    >/dev/null 2>"$work/prepare.err" || prepare_status=$?
cat "$work/prepare.err" >&2
(( prepare_status == 0 )) || exit "$prepare_status"
warning='WARNING: MySQL ngram FULLTEXT indexes will use the default MariaDB parser. Search results may differ.'
[[ $(grep -Fxc "$warning" "$work/prepare.err") == 1 ]] || fail 'expected one ngram parser change warning'
if grep -Eiq 'WITH PARSER `?ngram' "$work/prepared.sql"; then fail 'prepared dump retained the ngram parser'; fi

db=(docker exec -i "$dest" mariadb -uroot -BN kvs)
if "${db[@]}" -e "CREATE TEMPORARY TABLE dates (d date); INSERT INTO dates VALUES ('2024-02-31')" 2>"$work/error"; then
    fail 'strict destination accepted the invalid date'
fi
grep -Fq 'Incorrect date value' "$work/error" || fail 'unexpected strict date error'
"${db[@]}" < "$work/prepared.sql"
"${db[@]}" > "$work/actual" <<'SQL'
SELECT id,title,body,published FROM ktvs_articles ORDER BY id;
SELECT index_type,column_name FROM information_schema.statistics
 WHERE table_schema=DATABASE() AND table_name='ktvs_articles' AND index_name='search_text' ORDER BY seq_in_index;
SELECT value FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';
SQL
printf '%s\n' $'1\tFirst\tCalendar\t2024-02-31' $'2\tNext\tIssue\t2024-03-01' \
    $'FULLTEXT\ttitle' $'FULLTEXT\tbody' mysql-replay | diff -u - "$work/actual"
echo "PASS: ${source_image%@*} rows, dates, fulltext columns and import marker replayed on MariaDB 11.4"
