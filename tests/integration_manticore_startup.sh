#!/bin/bash
# Optional proof, against the image built from docker/manticore, that
# Manticore answers right after a restart and rebuilds its indexes behind
# searchd:
#   (a) the first start, on an empty volume, builds every index before
#       searchd answers, and the container turns healthy;
#   (b) recreated on the same volume, as an upgrade does, the container
#       answers within seconds with the indexes it kept while the rebuild
#       runs, turns healthy, and serves the new rows once searchd rotated
#       them in; a plain restart does the same;
#   (c) the hourly cron line skips while the rebuild holds the lock, and
#       rotates once the lock is free;
#   (d) no zombie process is left once the rebuild ends;
#   (e) once a rebuild is requested through docker/lib/manticore.sh, as
#       setup and reconfigure.sh do when the database changed under the
#       kept indexes, the start builds every index before searchd answers,
#       and the wait reconfigure.sh runs before it switches KVS lasts until
#       then: the first answer has the rows added and not the rows removed;
#   (f) a rebuild behind searchd that fails on a broken source, which the
#       indexer reports with an ERROR line and exit status 0, turns the
#       container unhealthy with the reason in its health log and in what
#       reconfigure.sh --manticore status reads, until an hourly rotation
#       rebuilds every table;
#   (g) a requested rebuild that fails on that source drops the indexes the
#       volume kept and starts searchd with the tables it built, without the
#       one it could not build, keeps the request and records why: the
#       container is not restarted, which would build every table again and
#       again, its probe fails with the reason, the wait reconfigure.sh runs
#       before it switches KVS ends at once, and once the source is repaired
#       a start builds every table;
#   (h) a first build that fails on one table does the same; an hourly
#       rotation then neither brings that table in nor clears the record,
#       and a start does;
#   (i) every client call to searchd's MySQL port, in the health check, the
#       entrypoint and docker/lib/manticore.sh, works against a server that
#       offers TLS it cannot complete, as searchd does at some starts, while
#       the image's client fails there by default;
#   (j) reconfigure.sh --manticore enable, run again while the build its
#       first run asked for goes on after that run ran out of time, waits
#       for that build: the same container builds on, nothing starts the
#       build over, and KVS is switched once it ends.
# The manticore service is the one of docker/docker-compose.yml, its health
# check (probed every 2 s instead of 30 s) and init included, without its
# published ports. MariaDB is the 11.8 image of docker/images.lock, with the
# tables and columns the three sources of manticore.conf.template read. A
# table lock held in MariaDB keeps a build waiting while the test looks at
# it. The test's own client never asks searchd for TLS either. Building the
# image needs the network (base image and packages); the containers run on
# an internal network, and the containers, network, volume and image are
# removed at the end. Run by hand: tests/run.sh does not run it.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# searchd must answer this soon after a recreated or restarted container
# started. The rebuild is held on a locked table meanwhile, so a start that
# waited for it would not answer at all: the bound only flags a slow start,
# with room for a loaded machine.
RESTART_ANSWER_LIMIT_MS=30000

if [ -n "${DOCKER_CONTEXT:-}" ]; then
    endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
else
    endpoint=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}
fi
case "$endpoint" in
    unix://*) ;;
    *) echo 'ERROR: this integration test requires a local Docker socket' >&2; exit 1 ;;
esac
mariadb_image=$(awk -F '\t' '$1 == "mariadb" && $2 == "11.8" { print $3 }' "$ROOT_DIR/docker/images.lock")
[ -n "$mariadb_image" ] || { echo 'ERROR: docker/images.lock has no MariaDB 11.8 line' >&2; exit 1; }

umask 077
project="kvsctltest-manticore-$$-$RANDOM"
TEST_DIR=$(mktemp -d /tmp/kvsctltest-manticore.XXXXXX)
export COMPOSE_PROJECT_NAME="$project"
export COMPOSE_FILE="$TEST_DIR/compose.yml"
unset COMPOSE_PROFILES
manticore="$project-manticore"
database="$project-mariadb"
root_password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
site_password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')

cleanup() {
    local status=$?
    if [ "$status" -ne 0 ] && [ -f "$COMPOSE_FILE" ]; then
        docker compose logs --no-color --tail 60 >&2 2>/dev/null || true
    fi
    if [ -f "$COMPOSE_FILE" ]; then
        docker compose down -v --rmi local --timeout 10 >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
now_ms() {
    local now=${EPOCHREALTIME/[.,]/}
    echo $((now / 1000))
}
seconds_since() {
    local elapsed=$(($(now_ms) - $1))
    printf '%d.%01d' $((elapsed / 1000)) $((elapsed % 1000 / 100))
}

# The real service, rendered by Compose: only its published ports and its
# profile go, and the database is the pinned MariaDB with its real health
# check, probed faster.
printf '%s\n' 'DOMAIN=example.com' "MARIADB_PASSWORD=$site_password" \
    "MARIADB_ROOT_PASSWORD=$root_password" "SITE_PREFIX=$project" \
    'TABLES_PREFIX=ktvs_' > "$TEST_DIR/render.env"
(
    unset DOMAIN MARIADB_PASSWORD MARIADB_ROOT_PASSWORD SITE_PREFIX TABLES_PREFIX
    docker compose --env-file "$TEST_DIR/render.env" -f "$ROOT_DIR/docker/docker-compose.yml" \
        --profile manticore config --format json
) | python3 -c '
import json
import sys

stack = json.load(sys.stdin)
service = stack["services"]["manticore"]
assert service.get("init") is True, "the manticore service must run under Docker init"
assert service.get("healthcheck", {}).get("test"), "the manticore service has no health check"
service.pop("ports", None)
service.pop("profiles", None)
service["healthcheck"]["interval"] = "2s"
real_database = stack["services"]["mariadb"]
database = {
    "image": sys.argv[1],
    "container_name": sys.argv[2] + "-mariadb",
    "environment": real_database["environment"],
    "volumes": ["./init:/docker-entrypoint-initdb.d:ro"],
    "healthcheck": dict(real_database["healthcheck"], interval="2s", retries=60),
    "networks": ["kvs-network"],
}
fixture = {
    "services": {"manticore": service, "mariadb": database},
    "networks": {"kvs-network": {"internal": True}},
    "volumes": {"manticore-data": {}},
}
with open(sys.argv[3], "w") as output:
    json.dump(fixture, output, indent=2)
    output.write("\n")
' "$mariadb_image" "$project" "$COMPOSE_FILE"
rm -f "$TEST_DIR/render.env"

# The tables and columns the videos, albums and searches sources read.
mkdir -m 755 "$TEST_DIR/init"
cat > "$TEST_DIR/init/10-search-schema.sql" <<'SQL'
CREATE TABLE ktvs_videos (
    video_id INT UNSIGNED NOT NULL PRIMARY KEY, title VARCHAR(255) NOT NULL,
    description TEXT NOT NULL, duration INT UNSIGNED NOT NULL DEFAULT 0,
    comments_count INT UNSIGNED NOT NULL DEFAULT 0, favourites_count INT UNSIGNED NOT NULL DEFAULT 0,
    video_viewed INT UNSIGNED NOT NULL DEFAULT 0, rating INT UNSIGNED NOT NULL DEFAULT 0,
    rating_amount INT UNSIGNED NOT NULL DEFAULT 1, resolution_type TINYINT UNSIGNED NOT NULL DEFAULT 0,
    format_video_group_id INT UNSIGNED NOT NULL DEFAULT 0, post_date DATETIME NOT NULL,
    relative_post_date INT NOT NULL DEFAULT 0, content_source_id INT UNSIGNED NOT NULL DEFAULT 0,
    dvd_id INT UNSIGNED NOT NULL DEFAULT 0, status_id TINYINT UNSIGNED NOT NULL DEFAULT 1
);
CREATE TABLE ktvs_albums (
    album_id INT UNSIGNED NOT NULL PRIMARY KEY, title VARCHAR(255) NOT NULL,
    description TEXT NOT NULL, photos_amount INT UNSIGNED NOT NULL DEFAULT 0,
    comments_count INT UNSIGNED NOT NULL DEFAULT 0, favourites_count INT UNSIGNED NOT NULL DEFAULT 0,
    album_viewed INT UNSIGNED NOT NULL DEFAULT 0, rating INT UNSIGNED NOT NULL DEFAULT 0,
    rating_amount INT UNSIGNED NOT NULL DEFAULT 1, post_date DATETIME NOT NULL,
    relative_post_date INT NOT NULL DEFAULT 0, content_source_id INT UNSIGNED NOT NULL DEFAULT 0,
    status_id TINYINT UNSIGNED NOT NULL DEFAULT 1
);
CREATE TABLE ktvs_stats_search (
    search_id INT UNSIGNED NOT NULL PRIMARY KEY, query VARCHAR(255) NOT NULL,
    query_length INT UNSIGNED NOT NULL DEFAULT 0, query_results_videos INT UNSIGNED NOT NULL DEFAULT 0,
    query_results_albums INT UNSIGNED NOT NULL DEFAULT 0, query_results_total INT UNSIGNED NOT NULL DEFAULT 0,
    amount INT UNSIGNED NOT NULL DEFAULT 0, added_date DATETIME NOT NULL,
    status_id TINYINT UNSIGNED NOT NULL DEFAULT 1
);
CREATE TABLE ktvs_tags (tag_id INT UNSIGNED NOT NULL PRIMARY KEY, tag VARCHAR(255) NOT NULL);
CREATE TABLE ktvs_tags_videos (tag_id INT UNSIGNED NOT NULL, video_id INT UNSIGNED NOT NULL, PRIMARY KEY (tag_id, video_id));
CREATE TABLE ktvs_tags_albums (tag_id INT UNSIGNED NOT NULL, album_id INT UNSIGNED NOT NULL, PRIMARY KEY (tag_id, album_id));
CREATE TABLE ktvs_categories (category_id INT UNSIGNED NOT NULL PRIMARY KEY, title VARCHAR(255) NOT NULL, synonyms TEXT NOT NULL);
CREATE TABLE ktvs_categories_videos (category_id INT UNSIGNED NOT NULL, video_id INT UNSIGNED NOT NULL, PRIMARY KEY (category_id, video_id));
CREATE TABLE ktvs_categories_albums (category_id INT UNSIGNED NOT NULL, album_id INT UNSIGNED NOT NULL, PRIMARY KEY (category_id, album_id));
CREATE TABLE ktvs_models (model_id INT UNSIGNED NOT NULL PRIMARY KEY, title VARCHAR(255) NOT NULL);
CREATE TABLE ktvs_models_videos (model_id INT UNSIGNED NOT NULL, video_id INT UNSIGNED NOT NULL, PRIMARY KEY (model_id, video_id));
CREATE TABLE ktvs_models_albums (model_id INT UNSIGNED NOT NULL, album_id INT UNSIGNED NOT NULL, PRIMARY KEY (model_id, album_id));
CREATE TABLE ktvs_content_sources (content_source_id INT UNSIGNED NOT NULL PRIMARY KEY, title VARCHAR(255) NOT NULL);
CREATE TABLE ktvs_dvds (dvd_id INT UNSIGNED NOT NULL PRIMARY KEY, title VARCHAR(255) NOT NULL);

INSERT INTO ktvs_tags VALUES (1, 'sunset'), (2, 'harbour');
INSERT INTO ktvs_categories VALUES (1, 'Travel', 'trips'), (2, 'Nature', 'outdoors');
INSERT INTO ktvs_models VALUES (1, 'Ada');
INSERT INTO ktvs_content_sources VALUES (1, 'Studio');
INSERT INTO ktvs_dvds VALUES (1, 'Collection');
INSERT INTO ktvs_videos (video_id, title, description, post_date, content_source_id, dvd_id) VALUES
    (1, 'Lighthouse at dawn', 'A walk along the coast', '2026-01-01 10:00:00', 1, 1),
    (2, 'Mountain lake', 'Calm water and pine trees', '2026-01-02 10:00:00', 0, 0),
    (3, 'City lights', 'Night traffic downtown', '2026-01-03 10:00:00', 1, 0);
INSERT INTO ktvs_tags_videos VALUES (1, 1), (2, 1), (2, 3);
INSERT INTO ktvs_categories_videos VALUES (1, 1), (2, 2);
INSERT INTO ktvs_models_videos VALUES (1, 3);
INSERT INTO ktvs_albums (album_id, title, description, photos_amount, post_date, content_source_id) VALUES
    (1, 'Harbour photos', 'Boats in the morning', 12, '2026-01-01 10:00:00', 1),
    (2, 'Forest trail', 'Autumn colours', 8, '2026-01-02 10:00:00', 0);
INSERT INTO ktvs_tags_albums VALUES (2, 1);
INSERT INTO ktvs_categories_albums VALUES (2, 2);
INSERT INTO ktvs_models_albums VALUES (1, 1);
INSERT INTO ktvs_stats_search (search_id, query, query_length, query_results_total, amount, added_date) VALUES
    (1, 'lighthouse', 10, 1, 4, '2026-01-01 10:00:00'),
    (2, 'mountain lake', 13, 1, 2, '2026-01-02 10:00:00');
SQL
chmod 644 "$TEST_DIR/init/10-search-schema.sql"

# The request and the checks reconfigure.sh runs, against this project.
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/manticore.sh"
export DOMAIN=example.com

db() {
    docker exec -i -e MYSQL_PWD="$root_password" "$database" \
        mariadb -uroot --batch --skip-column-names example.com "$@"
}
search() {
    docker exec "$manticore" mariadb --skip-ssl --connect-timeout=2 -h 127.0.0.1 -P 9306 \
        --batch --skip-column-names -e "$1" 2>/dev/null
}
searchd_answers() { search 'SHOW STATUS' >/dev/null; }
health() { docker inspect --format '{{.State.Health.Status}}' "$manticore"; }
health_log_has() {
    local output
    output=$(docker inspect --format '{{range .State.Health.Log}}{{.Output}}{{end}}' "$manticore")
    grep -Fq "$1" <<< "$output"
}
# The whole output is read first: grep -q in a pipe can stop the writer with
# SIGPIPE, which pipefail turns into a failure.
container_log_has() {
    local output
    output=$(docker logs "$manticore" 2>&1)
    grep -Fq "$1" <<< "$output"
}
started_ms() {
    local started
    started=$(docker inspect --format '{{.State.StartedAt}}' "$manticore")
    echo $(($(date -d "$started" +%s%N) / 1000000))
}
# Retries a command every 0.2 s for up to $1 seconds.
wait_until() {
    local limit=$(($1 * 5)) attempt
    shift
    for ((attempt = 0; attempt < limit; attempt++)); do
        if "$@"; then return 0; fi
        sleep 0.2
    done
    return 1
}
is_healthy() { [ "$(health)" = healthy ]; }
is_unhealthy() { [ "$(health)" = unhealthy ]; }
restart_count() { docker inspect --format '{{.RestartCount}}' "$manticore"; }
failure_recorded() { docker exec "$manticore" test -s /var/run/manticore/kvs-rebuild-failed; }
build_failure_recorded() { docker exec "$manticore" test -s /var/run/manticore/kvs-build-failed; }
request_kept() { docker exec "$manticore" test -e /var/lib/manticore/kvs-rebuild-before-start; }
searches_served() { [ "$(search "SELECT COUNT(*) FROM example_com_searches")" = 2 ]; }
searches_missing() { ! search "SELECT COUNT(*) FROM example_com_searches" > /dev/null; }
indexer_runs() { docker exec "$manticore" pgrep -x indexer >/dev/null; }
indexer_stopped() { ! docker exec "$manticore" pgrep -x indexer >/dev/null; }
# A session of its own holds a write lock on the videos table, on which
# indexer then waits; killing the session releases it.
hold_videos() {
    docker exec -d -e MYSQL_PWD="$root_password" "$database" mariadb -uroot example.com \
        -e 'LOCK TABLES ktvs_videos WRITE; SELECT SLEEP(600); UNLOCK TABLES'
    wait_until 30 videos_held || fail "the test could not lock the videos table"
}
videos_held() {
    [ -n "$(db -e "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO = 'SELECT SLEEP(600)'")" ]
}
release_videos() {
    local session
    session=$(db -e "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO = 'SELECT SLEEP(600)'")
    db -e "KILL $session"
}
serves_initial_rows() {
    [ "$(search "SELECT COUNT(*) FROM example_com_videos")" = 3 ] &&
        [ "$(search "SELECT COUNT(*) FROM example_com_albums")" = 2 ] &&
        [ "$(search "SELECT COUNT(*) FROM example_com_searches")" = 2 ]
}
quokka_found() { [ "$(search "SELECT id FROM example_com_videos WHERE MATCH('quokka')")" = 4 ]; }
wombat_found() { [ "$(search "SELECT id FROM example_com_videos WHERE MATCH('wombat')")" = 5 ]; }
rebuild_rotated() {
    docker exec "$manticore" grep -Fq 'successfully sent SIGHUP to searchd' \
        /var/log/manticore/indexer-init.log 2>/dev/null
}
# The rebuild is the parent of the flock that holds the indexer lock: it
# must belong to PID 1, Docker's init, not to searchd.
rebuild_parent() {
    docker exec "$manticore" ps -eo pid=,ppid=,args= | awk '
        { parent[$1] = $2 }
        $3 == "flock" && $4 == "/var/run/manticore/indexer.lock" { holder = $2 }
        END { if (holder != "") print parent[holder] }
    '
}
rebuild_gone() { [ -z "$(rebuild_parent)" ] && indexer_stopped; }
# grep -c reads the whole output, so the pipe cannot fail on SIGPIPE.
rebuilds_reported() {
    [ "$(docker logs "$manticore" 2>&1 |
        grep -c 'Indexes rebuilt in the background and handed to searchd')" = "$1" ]
}
zombies() { docker exec "$manticore" ps -eo stat=,pid=,ppid=,args= | awk '$1 ~ /^Z/'; }

docker compose build manticore > "$TEST_DIR/build.log" 2>&1 ||
    { cat "$TEST_DIR/build.log" >&2; fail "the Manticore image did not build"; }
docker compose up -d --wait --wait-timeout 180 mariadb > /dev/null 2>&1 ||
    fail "MariaDB did not become healthy"

# (a) First start on an empty volume: the build comes before searchd.
hold_videos
docker compose up -d manticore > /dev/null 2>&1
start_a=$(started_ms)
wait_until 60 container_log_has 'Building initial indexes' ||
    fail "the first start did not build the indexes"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if searchd_answers; then fail "searchd answered before the first build ended"; fi
    sleep 0.5
done
indexer_runs || fail "no indexer runs while the first start waits"
[ "$(health)" = starting ] || fail "the container is $(health) during its first build"
release_a=$(now_ms)
release_videos
wait_until 120 searchd_answers || fail "searchd did not answer after the first build"
answer_a=$(seconds_since "$release_a")
serves_initial_rows || fail "searchd answered before every index was built"
container_log_has 'Initial indexes built successfully' ||
    fail "the first build was not reported"
wait_until 120 is_healthy || fail "the container is $(health) after the first start"
healthy_a=$(seconds_since "$start_a")
# The base image ships MySQL's client only; the entrypoint, the health check
# and the rebuild run the mariadb command the image adds.
docker exec "$manticore" sh -c 'command -v mariadb' > /dev/null ||
    fail "the image has no mariadb command"

# (b) Recreated on the kept volume: searchd answers with the kept indexes
# while the rebuild waits on the held table.
db -e "INSERT INTO ktvs_videos (video_id, title, description, post_date)
    VALUES (4, 'Quokka parade', 'Added after the first build', '2026-01-04 10:00:00')"
hold_videos
docker compose up -d --no-deps --force-recreate manticore > /dev/null 2>&1
start_b=$(started_ms)
wait_until 60 searchd_answers || fail "searchd did not answer after a recreate"
answer_b_ms=$(($(now_ms) - start_b))
[ "$answer_b_ms" -le "$RESTART_ANSWER_LIMIT_MS" ] ||
    fail "searchd answered ${answer_b_ms} ms after a recreate, over ${RESTART_ANSWER_LIMIT_MS} ms"
serves_initial_rows || fail "the kept indexes are not served after a recreate"
if quokka_found; then fail "the row added after the first build is served before the rebuild"; fi
container_log_has 'Indexes found from a previous start' ||
    fail "the recreated container did not take the kept indexes"
if container_log_has 'Building initial indexes'; then
    fail "the recreated container built the indexes before searchd"
fi
# The rebuild probes searchd every 2 s before it starts the indexer.
wait_until 30 indexer_runs || fail "no rebuild runs behind searchd"
[ "$(rebuild_parent)" = 1 ] ||
    fail "the rebuild is not a child of Docker's init: parent $(rebuild_parent)"
wait_until 120 is_healthy || fail "the recreated container is $(health)"
healthy_b=$(seconds_since "$start_b")
indexer_runs || fail "the rebuild ended before the test released the table"

# (c) The hourly line, run as cron runs it, skips while the rebuild holds the
# lock: it starts no indexer and clears no file.
cron_command=$(docker exec "$manticore" sed -n 's/^0 \* \* \* \* manticore //p' /etc/cron.d/manticore-indexer)
[ -n "$cron_command" ] || fail "the image has no hourly rotation for the manticore user"
run_cron() {
    docker exec -u manticore -e PATH=/usr/local/bin:/usr/bin:/bin "$manticore" /bin/sh -c "$cron_command"
}
docker exec -u root "$manticore" touch /var/lib/manticore/kvsctltest_root.new.spa
docker exec -u manticore "$manticore" touch /var/lib/manticore/kvsctltest_own.new.spa
run_cron || fail "the hourly rotation does not exit cleanly while the rebuild runs"
last_cron_line=$(docker exec "$manticore" tail -n 1 /var/log/manticore/indexer-cron.log)
grep -q 'an index rebuild holds the lock, this hourly rotation is skipped$' <<< "$last_cron_line" ||
    fail "the skipped hourly rotation was not logged: ${last_cron_line}"
[ "$(docker exec "$manticore" pgrep -c -x indexer)" = 1 ] ||
    fail "the hourly rotation started a second indexer"
docker exec "$manticore" test -e /var/lib/manticore/kvsctltest_root.new.spa ||
    fail "the skipped hourly rotation cleared a file"

# The rebuild then completes and searchd rotates the new rows in.
rebuild_b=$(now_ms)
release_videos
wait_until 120 rebuild_rotated || fail "the background rebuild did not rotate"
wait_until 60 quokka_found || fail "the rotated indexes do not serve the new row"
rotated_b=$(seconds_since "$rebuild_b")
wait_until 30 rebuilds_reported 1 ||
    fail "the background rebuild did not report its end"

# (d) Nothing of the rebuild is left, zombies included.
wait_until 30 rebuild_gone || fail "the rebuild did not end"
[ -z "$(zombies)" ] || fail "zombie processes after the rebuild: $(zombies)"
is_healthy || fail "the container is $(health) after the rebuild"

# Once the lock is free the hourly line rotates, clearing only the rotation
# files of another user.
run_cron || fail "the hourly rotation failed"
docker exec "$manticore" grep -Fq 'successfully sent SIGHUP to searchd' \
    /var/log/manticore/indexer-cron.log || fail "the hourly rotation did not rotate"
if docker exec "$manticore" test -e /var/lib/manticore/kvsctltest_root.new.spa; then
    fail "the hourly rotation kept the rotation file another user left"
fi
docker exec "$manticore" test -e /var/lib/manticore/kvsctltest_own.new.spa ||
    fail "the hourly rotation cleared a file of its own user"
docker exec "$manticore" rm -f /var/lib/manticore/kvsctltest_own.new.spa

# A plain restart keeps the container, its lock file and its logs: it serves
# at once and rebuilds the same way.
docker compose restart manticore > /dev/null 2>&1
start_r=$(started_ms)
wait_until 60 searchd_answers || fail "searchd did not answer after a restart"
answer_r_ms=$(($(now_ms) - start_r))
[ "$answer_r_ms" -le "$RESTART_ANSWER_LIMIT_MS" ] ||
    fail "searchd answered ${answer_r_ms} ms after a restart, over ${RESTART_ANSWER_LIMIT_MS} ms"
quokka_found || fail "the indexes kept by a restart are not served"
wait_until 120 rebuilds_reported 2 || fail "the rebuild after a restart did not report its end"
wait_until 30 rebuild_gone || fail "the rebuild after a restart did not end"
[ -z "$(zombies)" ] || fail "zombie processes after a restart: $(zombies)"
wait_until 120 is_healthy || fail "the container is $(health) after a restart"

# (e) The database changes under the kept indexes, as an import or a
# replaced database leaves it, and the rebuild is requested.
db -e "INSERT INTO ktvs_videos (video_id, title, description, post_date)
    VALUES (5, 'Wombat burrow', 'Added under the kept indexes', '2026-01-05 10:00:00')"
db -e "DELETE FROM ktvs_videos WHERE video_id = 2"
hold_videos
manticore_request_rebuild > "$TEST_DIR/request.log" 2>&1 ||
    { cat "$TEST_DIR/request.log" >&2; fail "the rebuild could not be requested"; }
[ -z "$(docker compose ps -a -q manticore)" ] ||
    fail "the request left the container that read the volume before it"
docker compose up -d manticore > /dev/null 2>&1
wait_until 60 container_log_has 'A rebuild from the current database was requested' ||
    fail "the start did not take the requested rebuild"
MANTICORE_WAIT_SECONDS=300 manticore_wait_ready > "$TEST_DIR/wait.log" 2>&1 &
wait_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if searchd_answers; then fail "searchd answered before the requested rebuild ended"; fi
    sleep 0.5
done
indexer_runs || fail "no indexer runs while the requested rebuild waits"
[ "$(health)" = starting ] || fail "the container is $(health) during the requested rebuild"
kill -0 "$wait_pid" 2>/dev/null || fail "the wait before KVS is switched ended during the requested rebuild"
if container_log_has 'Indexes found from a previous start'; then
    fail "the kept indexes were served although a rebuild was requested"
fi
release_e=$(now_ms)
release_videos
wait "$wait_pid" || { cat "$TEST_DIR/wait.log" >&2; fail "the wait before KVS is switched failed after the requested rebuild"; }
answer_e=$(seconds_since "$release_e")
wombat_found || fail "the first answers after the requested rebuild miss the row added under the kept indexes"
[ "$(search "SELECT COUNT(*) FROM example_com_videos WHERE id = 2")" = 0 ] ||
    fail "the first answers after the requested rebuild have the row removed under the kept indexes"
docker exec "$manticore" test ! -e /var/lib/manticore/kvs-rebuild-before-start ||
    fail "the request outlived the build it asked for"
container_log_has 'Indexes rebuilt from the current database' ||
    fail "the requested rebuild did not report its end"
wait_until 120 is_healthy || fail "the container is $(health) after the requested rebuild"

# (f) A source the database no longer matches: the indexer prints an ERROR
# line for that table and exits 0, as it built the others. The held table
# lets the container turn healthy first, as on a site whose rebuild takes
# longer than a probe: Docker counts no failed probe of the start period
# before a first one passed.
db -e "ALTER TABLE ktvs_stats_search CHANGE amount amount_moved INT UNSIGNED NOT NULL DEFAULT 0"
hold_videos
docker compose up -d --no-deps --force-recreate manticore > /dev/null 2>&1
wait_until 60 searchd_answers || fail "searchd did not answer after a recreate on a broken source"
container_log_has 'Indexes found from a previous start' ||
    fail "a recreate no longer serves the kept indexes at once"
wait_until 120 is_healthy || fail "the container is $(health) while its rebuild runs"
release_videos
wait_until 120 failure_recorded || fail "the failed rebuild behind searchd was not recorded"
wait_until 60 is_unhealthy || fail "the container is $(health) although its rebuild failed"
health_log_has 'Background index rebuild failed' ||
    fail "the health log does not say why the container is unhealthy"
failure=$(manticore_rebuild_failure) || fail "the status check does not see the failed rebuild"
grep -Fq 'Background index rebuild failed' <<< "$failure" ||
    fail "the status check does not say why the rebuild failed: ${failure}"
docker exec "$manticore" grep -Fq "ERROR: table 'example_com_searches'" /var/log/manticore/indexer-init.log ||
    fail "the log of the failed rebuild does not name the table"
wombat_found || fail "searchd stopped answering from the indexes it has"
# Repaired, the next hourly rotation rebuilds every table and clears it.
db -e "ALTER TABLE ktvs_stats_search CHANGE amount_moved amount INT UNSIGNED NOT NULL DEFAULT 0"
run_cron || fail "the hourly rotation failed"
if failure_recorded; then fail "an hourly rotation that rebuilt every table kept the recorded failure"; fi
wait_until 60 is_healthy || fail "the container stayed $(health) after an hourly rotation rebuilt every table"

# (g) The same broken source under a requested rebuild: the start drops the
# indexes the volume kept and builds every table before searchd answers.
# searchd then serves the tables that build made, without the one it could
# not build, and the container stays up: Docker starting it again would
# build every other table again at once, until the source is repaired.
db -e "ALTER TABLE ktvs_stats_search CHANGE amount amount_moved INT UNSIGNED NOT NULL DEFAULT 0"
manticore_request_rebuild > "$TEST_DIR/request.log" 2>&1 ||
    { cat "$TEST_DIR/request.log" >&2; fail "the rebuild could not be requested"; }
docker compose up -d manticore > /dev/null 2>&1
wait_until 120 searchd_answers || fail "searchd did not answer after a requested rebuild that failed on one table"
container_log_has 'ERROR: The requested index rebuild failed on some tables' ||
    fail "a requested rebuild that failed on one table was not reported"
[ "$(search "SELECT COUNT(*) FROM example_com_videos")" = 4 ] ||
    fail "the videos the requested rebuild built are not served"
wombat_found || fail "the videos the requested rebuild built miss the current rows"
[ "$(search "SELECT COUNT(*) FROM example_com_albums")" = 2 ] ||
    fail "the albums the requested rebuild built are not served"
searches_missing ||
    fail "the table the requested rebuild could not build is served from the indexes the volume kept"
build_failure_recorded || fail "the requested rebuild that failed on one table was not recorded"
request_kept || fail "a requested rebuild that failed on one table dropped the request"
wait_until 60 health_log_has 'The requested index rebuild failed on some tables' ||
    fail "the probe does not say why the requested rebuild failed"
[ "$(health)" != healthy ] || fail "the container is healthy although a table is not served"
wait_start=$SECONDS
if MANTICORE_WAIT_SECONDS=300 manticore_wait_ready > "$TEST_DIR/wait.log" 2>&1; then
    fail "the wait before KVS is switched accepted a requested rebuild that failed on one table"
fi
[ $((SECONDS - wait_start)) -lt 30 ] ||
    fail "the wait before KVS is switched lasted $((SECONDS - wait_start)) s for a build that had already failed"
grep -Fq 'The requested index rebuild failed on some tables' "$TEST_DIR/wait.log" ||
    { cat "$TEST_DIR/wait.log" >&2; fail "the wait before KVS is switched does not say why it stopped"; }
failure=$(manticore_rebuild_failure) || fail "the status check does not see the failed requested rebuild"
grep -Fq 'The requested index rebuild failed on some tables' <<< "$failure" ||
    fail "the status check does not say why the requested rebuild failed: ${failure}"
# A start that ended its build ran it once.
sleep 5
[ "$(restart_count)" = 0 ] || fail "the container was restarted after a requested rebuild that failed on one table"
[ "$(docker logs "$manticore" 2>&1 | grep -c 'A rebuild from the current database was requested')" = 1 ] ||
    fail "the requested rebuild ran more than once"
# Repaired, the next start drops and builds every table again, and serves
# them all.
db -e "ALTER TABLE ktvs_stats_search CHANGE amount_moved amount INT UNSIGNED NOT NULL DEFAULT 0"
docker compose restart manticore > /dev/null 2>&1
wait_until 120 searches_served || fail "the table the failed rebuild could not build is not served once a start built it"
if request_kept; then fail "the request outlived the build that made every table"; fi
if build_failure_recorded; then fail "a start that built every table kept the recorded failure"; fi
wombat_found || fail "the start that built every table lost the current rows"
wait_until 120 is_healthy || fail "the container is $(health) once a start built every table"

# (h) A first build, for a table left without files, that fails on that
# table: searchd starts with the others and the reason is recorded. An
# hourly rotation, once the source is repaired, does not bring that table
# in, as searchd does not take a table it started without from a rotation,
# and leaves the record; a start builds it.
db -e "ALTER TABLE ktvs_stats_search CHANGE amount amount_moved INT UNSIGNED NOT NULL DEFAULT 0"
docker exec "$manticore" sh -c 'rm -f /var/lib/manticore/example_com_searches.*'
docker compose restart manticore > /dev/null 2>&1
wait_until 120 build_failure_recorded || fail "a first build that failed on one table was not recorded"
wait_until 120 searchd_answers || fail "searchd did not answer after a first build that failed on one table"
container_log_has 'ERROR: Initial indexing failed on some tables' ||
    fail "a first build that failed on one table was not reported"
searches_missing || fail "a table the first build could not build is served"
wombat_found || fail "the tables the first build made are not served"
wait_until 60 health_log_has 'Initial indexing failed on some tables' ||
    fail "the probe does not say why the first build failed"
db -e "ALTER TABLE ktvs_stats_search CHANGE amount_moved amount INT UNSIGNED NOT NULL DEFAULT 0"
run_cron || fail "the hourly rotation failed"
docker exec "$manticore" grep -Fq 'successfully sent SIGHUP to searchd' /var/log/manticore/indexer-hourly.log ||
    fail "the hourly rotation did not rotate"
if docker exec "$manticore" grep -Eq '^(ERROR|FATAL):' /var/log/manticore/indexer-hourly.log; then
    fail "the hourly rotation failed on a table once the source was repaired"
fi
sleep 3
searches_missing ||
    fail "searchd took from a rotation a table it started without: the failure of a build before searchd could then be cleared by the hourly rotation"
build_failure_recorded || fail "the hourly rotation cleared the failure of a build before searchd"
[ "$(restart_count)" = 0 ] || fail "the container was restarted after a first build that failed on one table"
docker compose restart manticore > /dev/null 2>&1
wait_until 120 searches_served || fail "the table the first build could not build is not served once a start built it"
if build_failure_recorded; then fail "a start that built every table kept the recorded failure"; fi
wait_until 120 is_healthy || fail "the container is $(health) once a start built every table"

# (i) A server on searchd's port that offers TLS it cannot complete, run
# with the image's client in a container of its own: every client call to
# that port in the health check, the entrypoint and docker/lib/manticore.sh
# must get its answer, where the image's client fails by default.
mkdir -m 755 "$TEST_DIR/tls"
cat > "$TEST_DIR/tls/tls-offered.pl" <<'PERL'
# Offers TLS in its greeting and answers a TLS handshake with the fatal
# alert of a server that has no certificate; a client that stays in plain
# text gets an OK for every command.
use strict;
use warnings;
use IO::Socket::INET;

my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 9306, Listen => 16, ReuseAddr => 1,
) or die "cannot listen on 127.0.0.1:9306: $!\n";

sub read_exact {
    my ($socket, $length) = @_;
    my $data = '';
    while (length($data) < $length) {
        my $read = sysread($socket, my $chunk, $length - length($data));
        return undef unless $read;
        $data .= $chunk;
    }
    return $data;
}

sub read_packet {
    my ($socket) = @_;
    my $header = read_exact($socket, 4);
    return () unless defined $header;
    my $length = unpack('V', substr($header, 0, 3) . "\0");
    my $body = $length ? read_exact($socket, $length) : '';
    return () unless defined $body;
    return (unpack('C', substr($header, 3, 1)), $body);
}

sub send_packet {
    my ($socket, $sequence, $body) = @_;
    syswrite($socket, substr(pack('V', length($body)), 0, 3) . pack('C', $sequence) . $body);
}

# OK: no rows affected, no insert id, autocommit, no warnings.
my $ok = pack('CCCvv', 0, 0, 0, 2, 0);
# LONG_PASSWORD, LONG_FLAG, CONNECT_WITH_DB, PROTOCOL_41, SSL, TRANSACTIONS,
# SECURE_CONNECTION and PLUGIN_AUTH.
my $capabilities = 0x0001 | 0x0004 | 0x0008 | 0x0200 | 0x0800 | 0x2000 | 0x8000 | 0x80000;

while (my $client = $server->accept) {
    send_packet($client, 0, pack('C', 10) . "8.0.0-tls-offered\0" . pack('V', 1) . 'abcdefgh' . "\0"
        . pack('v', $capabilities & 0xffff) . pack('C', 33) . pack('v', 2)
        . pack('v', $capabilities >> 16) . pack('C', 21) . ("\0" x 10)
        . 'ijklmnopqrst' . "\0" . "mysql_native_password\0");
    my ($sequence, $reply) = read_packet($client);
    if (!defined $reply) { close $client; next; }
    if (length($reply) == 32 && (unpack('V', $reply) & 0x0800)) {
        sysread($client, my $hello, 16384);
        syswrite($client, pack('C7', 0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x28));
        close $client;
        next;
    }
    send_packet($client, $sequence + 1, $ok);
    while (my ($command_sequence, $command) = read_packet($client)) {
        last if $command eq "\x01";
        send_packet($client, $command_sequence + 1, $ok);
    }
    close $client;
}
PERL
cat > "$TEST_DIR/tls/run.sh" <<'RUN'
perl /tls/tls-offered.pl &
for _ in $(seq 1 50); do
    if (exec 3<> /dev/tcp/127.0.0.1/9306) 2> /dev/null; then break; fi
    sleep 0.1
done
if output=$(timeout 20 mariadb --connect-timeout=5 -h 127.0.0.1 -P 9306 -e 'SHOW STATUS' 2>&1); then
    echo 'default client: answered'
else
    echo "default client: ${output}"
fi
while IFS= read -r command; do
    if output=$(timeout 20 sh -c "$command" 2>&1 > /dev/null); then
        echo "answered: ${command}"
    else
        echo "failed: ${command}: ${output}"
    fi
done < /tls/commands
RUN
{
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["services"]["manticore"]["healthcheck"]["test"][1])' \
        "$COMPOSE_FILE"
    grep -ohE "(mariadb|mysql) [^']*-P 9306[^']*'[^']*'" \
        "$ROOT_DIR/docker/manticore/docker-entrypoint.sh" "$ROOT_DIR/docker/lib/manticore.sh"
} > "$TEST_DIR/tls/commands"
chmod 644 "$TEST_DIR/tls/"*
[ "$(wc -l < "$TEST_DIR/tls/commands")" -ge 3 ] ||
    fail "the health check, the entrypoint and docker/lib/manticore.sh should call searchd's MySQL port: $(cat "$TEST_DIR/tls/commands")"
image=$(docker inspect --format '{{.Config.Image}}' "$manticore")
docker run --rm --network none -v "$TEST_DIR/tls:/tls:ro" --entrypoint bash "$image" /tls/run.sh \
    > "$TEST_DIR/tls.log" 2>&1 || { cat "$TEST_DIR/tls.log" >&2; fail "the TLS check did not run"; }
grep -Fxq 'default client: ERROR 2026 (HY000): TLS/SSL error: sslv3 alert handshake failure' "$TEST_DIR/tls.log" ||
    { cat "$TEST_DIR/tls.log" >&2; fail "the server that offers TLS does not fail the image's client as searchd did"; }
if grep -q '^failed: ' "$TEST_DIR/tls.log"; then
    cat "$TEST_DIR/tls.log" >&2
    fail "a client call to searchd's MySQL port fails when searchd offers TLS it cannot complete"
fi
[ "$(grep -c '^answered: ' "$TEST_DIR/tls.log")" = "$(wc -l < "$TEST_DIR/tls/commands")" ] ||
    { cat "$TEST_DIR/tls.log" >&2; fail "not every client call to searchd's MySQL port was checked"; }

# (j) Search enabled on a site whose build outlasts the wait of enable: the
# first run asks for the build and runs out of time, the build goes on, and
# a second run waits for it instead of removing the container, which would
# start it over. Only the KVS parts of enable, the plugin switch and the
# writes to .env, are left out.
manticore_configure_plugin() { printf 'plugin switched: %s\n' "$1"; }
add_compose_profile() { :; }
set_env_value() { :; }
container_id() { docker inspect --format '{{.Id}} {{.State.StartedAt}}' "$manticore"; }
requested_builds() { docker logs "$manticore" 2>&1 | grep -c 'A rebuild from the current database was requested'; }
db -e "INSERT INTO ktvs_videos (video_id, title, description, post_date)
    VALUES (6, 'Numbat trail', 'Added before search was enabled again', '2026-01-06 10:00:00')"
hold_videos
if (MANTICORE_WAIT_SECONDS=20 manticore_manage enable) > "$TEST_DIR/enable-1.log" 2>&1; then
    fail "enable accepted a build that had not ended"
fi
grep -Fq 'Manticore indexes are not ready after' "$TEST_DIR/enable-1.log" ||
    { cat "$TEST_DIR/enable-1.log" >&2; fail "the first enable did not run out of time on the build"; }
if grep -Fq 'plugin switched' "$TEST_DIR/enable-1.log"; then
    fail "the first enable switched KVS before the build ended"
fi
[ "$(requested_builds)" = 1 ] || fail "the first enable did not start one requested build"
building_j=$(container_id)
# The log is there before the job opens it: the first grep below can run
# before the background shell does.
: > "$TEST_DIR/enable-2.log"
(MANTICORE_WAIT_SECONDS=300 manticore_manage enable) > "$TEST_DIR/enable-2.log" 2>&1 &
enable_pid=$!
wait_until 60 grep -Fq 'Waiting for videos, albums and searches indexes' "$TEST_DIR/enable-2.log" ||
    { cat "$TEST_DIR/enable-2.log" >&2; fail "the second enable did not wait"; }
sleep 5
kill -0 "$enable_pid" 2>/dev/null ||
    { cat "$TEST_DIR/enable-2.log" >&2; fail "the second enable ended while the build went on"; }
[ "$(container_id)" = "$building_j" ] ||
    fail "the second enable replaced the container that was building: $building_j, now $(container_id)"
[ "$(requested_builds)" = 1 ] || fail "the second enable started the build over"
indexer_runs || fail "the build stopped while the second enable waited"
if searchd_answers; then fail "searchd answered before the build ended"; fi
grep -Fq 'still building every index from the database on an earlier request' "$TEST_DIR/enable-2.log" ||
    fail "the second enable did not say it waits for the build in progress"
release_j=$(now_ms)
release_videos
wait "$enable_pid" || { cat "$TEST_DIR/enable-2.log" >&2; fail "the second enable failed once the build ended"; }
answer_j=$(seconds_since "$release_j")
grep -Fxq 'plugin switched: true' "$TEST_DIR/enable-2.log" || fail "the second enable did not switch KVS"
grep -Fq 'Manticore enabled. Indexes built from the current database' "$TEST_DIR/enable-2.log" ||
    fail "the second enable did not report the indexes it verified"
[ "$(container_id)" = "$building_j" ] || fail "the container changed once the build ended"
[ "$(search "SELECT id FROM example_com_videos WHERE MATCH('numbat')")" = 6 ] ||
    fail "KVS was switched to indexes that miss a row of the current database"
docker exec "$manticore" test ! -e /var/lib/manticore/kvs-rebuild-before-start ||
    fail "the request outlived the build it asked for"
grep -Fq 'The build of every index from the database goes on: run ./reconfigure.sh --manticore enable again to wait for it.' \
    "$TEST_DIR/enable-1.log" || fail "the first enable did not say that the build goes on and how to wait for it"
wait_until 120 is_healthy || fail "the container is $(health) once the build enable waited for ended"

printf 'first start: searchd answered %ss after the build was released, healthy %ss after the container started\n' \
    "$answer_a" "$healthy_a"
printf 'recreate: searchd answered %d ms after the container started, healthy after %ss, rotation %ss after the release\n' \
    "$answer_b_ms" "$healthy_b" "$rotated_b"
printf 'restart: searchd answered %d ms after the container started\n' "$answer_r_ms"
printf 'requested rebuild: searchd answered %ss after the build was released, with the current rows\n' "$answer_e"
printf 'enable run again during the build: switched %ss after the build was released, same container\n' "$answer_j"
echo "PASS: Manticore serves its kept indexes at once and rebuilds them in the background, builds them before it answers when a rebuild is requested, serves the tables a failed build made and reports it without a restart, its clients never ask for TLS, and enable run again waits for the build in progress ($mariadb_image)"
