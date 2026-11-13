#!/bin/bash
# Z1: import_prepare_dump must keep a charset-only CREATE TABLE on the
# collation its source meant. The mariadb image maps utf8mb4 and utf8mb3 to
# the uca1400 collations, so a dump that names DEFAULT CHARSET without COLLATE
# - what MySQL 5.x and older MariaDB write - would otherwise land on
# uca1400_ai_ci. That silently changes equality, sorting and uniqueness for
# most KVS tables, and two spellings that collate equal under uca1400 but not
# general_ci in a UNIQUE column abort the whole replay. The prepared dump
# resets the session to the legacy per-charset default on MariaDB 11.3+. This
# replays a MySQL 5.7-style dump into every locked series and checks the
# source collation survives, both spellings import, and the import completes.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The series setup.sh offers. The finding reproduced on all three; the uca1400
# mapping and the variable this fix resets both exist from 11.3 on.
series_list=(11.4 11.8 12.3)

# A MySQL 5.7 dump of a KVS database: the options table the import marks; a tag
# table whose UNIQUE charset-only column holds an ASCII word and its fullwidth
# form (0xEFBD94EFBD85EFBD93EFBD94 is the fullwidth "test", equal under
# uca1400_ai_ci, distinct under utf8mb4_general_ci); and a utf8mb3 charset-only
# table. None carry COLLATE, as such a dump does not.
source_sql=$(mktemp "${TMPDIR:-/tmp}/kvs-z1-source.XXXXXX.sql")
trap 'rm -f "$source_sql"' EXIT
cat > "$source_sql" <<'SQL'
/*!40101 SET NAMES utf8mb4 */;
CREATE TABLE `ktvs_options` (`variable` varchar(64) NOT NULL, `value` text, PRIMARY KEY (`variable`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE `ktvs_tags` (`tag` varchar(191) NOT NULL, UNIQUE KEY `uk_tag` (`tag`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE `ktvs_legacy` (`name` varchar(100) NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8;
INSERT INTO `ktvs_tags` VALUES ('test');
INSERT INTO `ktvs_tags` VALUES (0xEFBD94EFBD85EFBD93EFBD94);
SQL

check_series() {
    local series=$1 image container init_dir token='z1-collation'
    image=$("$root/docker/bin/resolve-bases.sh" --get mariadb "$series")
    docker image inspect "$image" >/dev/null 2>&1 ||
        fail "the $series image $image is not present; run-integration.sh pulls it first"

    init_dir=$(mktemp -d "${TMPDIR:-/tmp}/kvs-z1-init.XXXXXX")
    # The entrypoint reads this directory as the mysql user inside the
    # container, so the bind mount and its files must be world-readable.
    chmod 755 "$init_dir"
    container="kvs-z1-${series//./-}-$$"
    # Prepare the dump exactly as the setup does, into the init directory the
    # official entrypoint replays on first start.
    if command -v zstd >/dev/null; then
        import_prepare_dump "$source_sql" ktvs_ 7.0.2 /var/www/kvs /var/www/kvs \
            "$init_dir/10-kvs-import.sql.zst" "$token" >/dev/null ||
            { rm -rf "$init_dir"; fail "$series: import_prepare_dump failed"; }
    else
        import_prepare_dump "$source_sql" ktvs_ 7.0.2 /var/www/kvs /var/www/kvs \
            "$init_dir/10-kvs-import.sql" "$token" >/dev/null ||
            { rm -rf "$init_dir"; fail "$series: import_prepare_dump failed"; }
        gzip "$init_dir/10-kvs-import.sql"
    fi
    chmod 644 "$init_dir"/*

    local password
    password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    docker rm -f "$container" >/dev/null 2>&1 || true
    # network_mode none and the locked image already pulled: the replay never
    # reaches the network. The image's own config ships the uca1400 mapping, so
    # this reproduces the production charset environment.
    docker run -d --name "$container" --network none --memory 1g \
        -e MARIADB_ROOT_PASSWORD="$password" \
        -e MARIADB_DATABASE=kvs \
        -v "$init_dir:/docker-entrypoint-initdb.d:ro" \
        "$image" >/dev/null ||
        { rm -rf "$init_dir"; fail "$series: the container did not start"; }

    local query='SELECT value FROM kvs.ktvs_options WHERE variable='"'KVS_INSTALL_IMPORT'"';'
    local marker=''
    for _ in $(seq 1 120); do
        if ! [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = true ]; then
            # The init replay aborts the container when a statement fails, which
            # is exactly what the uca1400 UNIQUE collision does without the fix.
            echo "--- $series container log (tail) ---" >&2
            docker logs --tail 40 "$container" >&2 2>&1 || true
            docker rm -f "$container" >/dev/null 2>&1 || true
            rm -rf "$init_dir"
            fail "$series: the import replay aborted the container (the charset-only UNIQUE key collided)"
        fi
        marker=$(docker exec "$container" mariadb -uroot -p"$password" -N -s \
            -e "$query" 2>/dev/null || true)
        [ "$marker" = "$token" ] && break
        marker=''
        sleep 1
    done
    [ "$marker" = "$token" ] ||
        { docker logs --tail 40 "$container" >&2 2>&1 || true
          docker rm -f "$container" >/dev/null 2>&1 || true
          rm -rf "$init_dir"
          fail "$series: the import never completed (no KVS_INSTALL_IMPORT marker)"; }

    local observed expected
    observed=$(docker exec "$container" mariadb -uroot -p"$password" -N -s -e "
        SELECT GROUP_CONCAT(table_name, '=', table_collation ORDER BY table_name SEPARATOR ' ')
          FROM information_schema.tables
         WHERE table_schema='kvs' AND table_name IN ('ktvs_tags','ktvs_legacy');
        SELECT COUNT(*) FROM kvs.ktvs_tags;" 2>/dev/null | tr '\n' '|')
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$init_dir"

    expected='ktvs_legacy=utf8mb3_general_ci ktvs_tags=utf8mb4_general_ci|2|'
    [ "$observed" = "$expected" ] ||
        fail "$series: collation or row count changed: got [$observed], expected [$expected]"
    echo "PASS: MariaDB $series keeps the source collation (utf8mb4/utf8mb3 general_ci) and imports both spellings of the UNIQUE tag"
}

for series in "${series_list[@]}"; do
    check_series "$series"
done
echo "PASS: import_prepare_dump preserves charset-only collations across every locked MariaDB series"
