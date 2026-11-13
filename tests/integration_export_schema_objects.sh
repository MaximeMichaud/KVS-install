#!/bin/bash
# The stored routines and events of a site travel with the dump: the real
# kvs-export.sh dumps a source database, import_prepare_dump prepares it as
# the setup does, and the MariaDB entrypoint replays it on the series the
# stack runs. A function a view uses, a procedure a trigger calls and an
# event must exist and work there, and the query with which the setup says
# that imported events do not run must count them. An account that may not
# read a routine's body is refused before anything is dumped. What the old
# server cannot list (the events an account without the EVENT privilege
# cannot see, or that a DISABLED event scheduler refuses to list, the
# routines of a stale mysql.proc) stays behind with a warning, and the
# export goes on. The servers run from the images docker/images.lock pins,
# with no network.
# shellcheck disable=SC2016  # PHP and SQL fixtures hold literal dollar signs.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"

# The oldest series the lock pins stands in for the old server; a local run
# can point DATABASE_TEST_SOURCE_IMAGE at an older one.
source_image=${DATABASE_TEST_SOURCE_IMAGE:-$("$root/docker/bin/resolve-bases.sh" --get mariadb 11.4)}
target_image=${DATABASE_TEST_IMAGE:-$("$root/docker/bin/resolve-bases.sh" --get mariadb 12.3)}
for image in "$source_image" "$target_image"; do
    docker image inspect "$image" >/dev/null 2>&1 ||
        { echo "FAIL: $image is not present; run-integration.sh pulls it first" >&2; exit 1; }
done

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/kvs-export-routines.XXXXXX")
chmod 755 "$test_dir"
prefix="kvs-export-routines-$$"
root_password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
site_password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
containers=()

cleanup() {
    local status=$? container
    for container in ${containers[@]+"${containers[@]}"}; do
        if [ "$status" -ne 0 ]; then
            echo "--- $container (log tail) ---" >&2
            docker logs --tail 30 "$container" >&2 2>&1 || true
        fi
        docker rm -f "$container" >/dev/null 2>&1 || true
    done
    rm -rf "$test_dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# start_database <name> <image> <database> [init directory] [server option...]
start_database() {
    local name=$1 image=$2 database=$3 init_dir=${4:-}
    local -a mounts=()

    shift 3
    [ "$#" -eq 0 ] || shift
    [ -z "$init_dir" ] || mounts=(-v "$init_dir:/docker-entrypoint-initdb.d:ro")
    docker rm -f "$name" >/dev/null 2>&1 || true
    containers+=("$name")
    docker run -d --name "$name" --network none --memory 1g \
        -e MARIADB_ROOT_PASSWORD="$root_password" -e MARIADB_DATABASE="$database" \
        -e MARIADB_USER=kvs -e MARIADB_PASSWORD="$site_password" \
        ${mounts[@]+"${mounts[@]}"} "$image" "$@" >/dev/null
}

# sql <container> <user> [client arguments...]: the client over TCP, so the
# temporary server of the entrypoint (socket only) is never mistaken for
# the real one.
sql() {
    local container=$1 user=$2 password
    shift 2
    password=$root_password
    [ "$user" = root ] || password=$site_password
    docker exec -i -e MYSQL_PWD="$password" "$container" \
        mariadb --skip-ssl --protocol=tcp -h 127.0.0.1 -u "$user" -N -B "$@"
}

wait_ready() {
    local container=$1
    for _ in $(seq 1 120); do
        if ! [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = true ]; then
            fail "$container stopped"
        fi
        sql "$container" root -e 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 1
    done
    fail "$container never answered"
}

# export_dump <container> <login> <password> <output>: the real exporter, on
# the source server, against a KVS site whose setup_db.php names the login.
export_dump() {
    local container=$1 login=$2 password=$3 output=$4 site="$test_dir/site-$2"

    mkdir -p "$site/admin/include" "$site/contents/videos"
    cat > "$site/admin/include/setup.php" <<'PHP'
<?php
$config['project_path']='/srv/old-site';
$config['project_url']='https://old.example.com';
$config['tables_prefix']='ktvs_';
PHP
    printf '<?php\n$config['"'"'project_version'"'"']='"'"'7.0.2'"'"';\n' > "$site/admin/include/version.php"
    cat > "$site/admin/include/setup_db.php" <<PHP
<?php
define('DB_HOST','localhost');
define('DB_LOGIN','$login');
define('DB_PASS','$password');
define('DB_DEVICE','oldsite');
PHP
    docker cp "$site" "$container:/tmp/site-$login"
    docker cp "$root/kvs-export.sh" "$container:/tmp/kvs-export.sh"
    timeout 120 docker exec "$container" bash /tmp/kvs-export.sh --no-size --gzip --database-format sql \
        dump "/tmp/site-$login" > "$output" 2> "$output.err"
}

# replay <dump> <name>: prepare the dump as the setup does and let the
# entrypoint of the target series replay it.
replay() {
    local dump=$1 name=$2 token=routines-$$ init_dir="$test_dir/init-$2" marker=''

    mkdir -p "$init_dir"
    chmod 755 "$init_dir"
    import_prepare_dump "$dump" ktvs_ 7.0.2 /var/www/kvs /var/www/kvs "$init_dir/10-kvs-import.sql" "$token" >/dev/null ||
        fail "import_prepare_dump refused the dump"
    gzip "$init_dir/10-kvs-import.sql"
    chmod 644 "$init_dir"/*
    start_database "$name" "$target_image" kvs "$init_dir"
    for _ in $(seq 1 120); do
        [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ] ||
            fail "the replay stopped the target server (a statement of the dump failed)"
        marker=$(sql "$name" root kvs -e "SELECT value FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT'" 2>/dev/null) || marker=''
        [ "$marker" = "$token" ] && return 0
        sleep 1
    done
    fail "the replay never completed (no KVS_INSTALL_IMPORT marker)"
}

source_container="$prefix-source"
start_database "$source_container" "$source_image" oldsite
wait_ready "$source_container"
source_version=$(sql "$source_container" root -e 'SELECT VERSION()')

# What a customised site holds: the site's own account defined each object.
sql "$source_container" kvs oldsite <<'SQL'
CREATE TABLE ktvs_options (variable VARCHAR(64) NOT NULL PRIMARY KEY, value TEXT) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO ktvs_options VALUES ('INITIAL_VERSION', '7.0.2');
CREATE TABLE ktvs_videos (video_id INT NOT NULL PRIMARY KEY, title VARCHAR(64)) ENGINE=InnoDB;
CREATE TABLE ktvs_log (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, message VARCHAR(64)) ENGINE=InnoDB;
DELIMITER ;;
CREATE FUNCTION kvs_double(x INT) RETURNS INT DETERMINISTIC RETURN x * 2;;
CREATE PROCEDURE kvs_note(IN message VARCHAR(64)) BEGIN INSERT INTO ktvs_log (message) VALUES (message); END;;
CREATE TRIGGER ktvs_videos_note AFTER INSERT ON ktvs_videos FOR EACH ROW CALL kvs_note(CONCAT('video ', NEW.video_id));;
DELIMITER ;
CREATE VIEW ktvs_videos_doubled AS SELECT video_id, kvs_double(video_id) AS twice FROM ktvs_videos;
CREATE EVENT kvs_log_cleanup ON SCHEDULE EVERY 1 DAY DISABLE DO DELETE FROM ktvs_log WHERE id < 0;
INSERT INTO ktvs_videos VALUES (1, 'first');
-- A database whose default changed after its routines were created: the
-- dump wraps each of them in ALTER DATABASE `oldsite` lines.
ALTER DATABASE oldsite CHARACTER SET latin1 COLLATE latin1_swedish_ci;
SQL

export_dump "$source_container" kvs "$site_password" "$test_dir/routines.sql.gz" ||
    { cat "$test_dir/routines.sql.gz.err" >&2; fail "the export of a database with routines and events failed"; }
gzip -dc "$test_dir/routines.sql.gz" | grep -q '^ALTER DATABASE `oldsite`' ||
    fail "the dump must name the old database around its routines, as the dump tool writes it"
replay "$test_dir/routines.sql.gz" "$prefix-target"
target=$prefix-target
[ "$(sql "$target" root kvs -e 'SELECT kvs_double(21)')" = 42 ] || fail "the stored function is missing on the new server"
[ "$(sql "$target" root kvs -e 'SELECT twice FROM ktvs_videos_doubled WHERE video_id = 1')" = 2 ] ||
    fail "the view using the stored function does not answer"
sql "$target" kvs kvs -e "INSERT INTO ktvs_videos VALUES (2, 'second')" ||
    fail "an INSERT into the table whose trigger calls the procedure failed"
[ "$(sql "$target" root kvs -e 'SELECT GROUP_CONCAT(message ORDER BY id) FROM ktvs_log')" = 'video 1,video 2' ] ||
    fail "the trigger did not reach the stored procedure"
[ "$(sql "$target" root kvs -e "SELECT CONCAT(event_name, ' ', status) FROM information_schema.events WHERE event_schema = 'kvs'")" = 'kvs_log_cleanup DISABLED' ] ||
    fail "the event is missing on the new server"
echo "PASS: routines, the view and trigger using them, and an event move from MariaDB $source_version to the new server"
# The query with which the setup counts the imported events that will not
# run: none for a DISABLED event, one once it is enabled, none once the
# event scheduler of the server is on.
events_query=$(sed -n 's/^ *"\(SELECT COUNT(\*) FROM information_schema\.events WHERE [^"]*\)".*/\1/p' "$root/docker/setup.sh")
[ -n "$events_query" ] || fail "the event query of docker/setup.sh was not found"
[ "$(sql "$target" root kvs -e "$events_query")" = 0 ] || fail "a DISABLED event needs no notice"
sql "$target" root kvs -e 'ALTER EVENT kvs_log_cleanup ENABLE'
[ "$(sql "$target" root kvs -e "$events_query")" = 1 ] || fail "an enabled event does not run while the scheduler is off"
sql "$target" root -e 'SET GLOBAL event_scheduler = ON'
[ "$(sql "$target" root kvs -e "$events_query")" = 0 ] || fail "with the scheduler on, the events run"
echo "PASS: the setup counts the imported events that do not run"

# What the old server cannot list stays behind with a warning, and the
# export goes on as it did before the dump carried routines and events.
# An account without the EVENT privilege sees no event: SHOW EVENTS, which
# the dump tool runs for --events, refuses it.
sql "$source_container" root -e "CREATE USER 'noevent'@'%' IDENTIFIED BY '$site_password';
GRANT ALL PRIVILEGES ON oldsite.* TO 'noevent'@'%';
REVOKE EVENT ON oldsite.* FROM 'noevent'@'%';
GRANT SELECT ON mysql.proc TO 'noevent'@'%';"
export_dump "$source_container" noevent "$site_password" "$test_dir/noevent.sql.gz" ||
    { cat "$test_dir/noevent.sql.gz.err" >&2; fail "an account without the EVENT privilege must still export"; }
if ! grep -Fq 'WARNING: the events of oldsite could not be listed (ERROR 1044 (42000)' "$test_dir/noevent.sql.gz.err" ||
    ! grep -Fq 'give noevent the EVENT privilege on oldsite' "$test_dir/noevent.sql.gz.err"; then
    cat "$test_dir/noevent.sql.gz.err" >&2
    fail "the export must say that the events it cannot see stay behind"
fi
grep -q 'FUNCTION `kvs_double`' <(gzip -dc "$test_dir/noevent.sql.gz") || fail "the routines must still travel without the events"
if grep -q 'EVENT `kvs_log_cleanup`' <(gzip -dc "$test_dir/noevent.sql.gz"); then
    fail "an account without the EVENT privilege cannot dump the event"
fi
echo "PASS: an account without the EVENT privilege exports the rest and says that the events stay behind"

# A server started with event_scheduler=DISABLED answers error 1577 to any
# event listing. Its routines still travel, and the view using one works.
disabled_container="$prefix-disabled"
start_database "$disabled_container" "$source_image" oldsite "" --event-scheduler=DISABLED
wait_ready "$disabled_container"
sql "$disabled_container" kvs oldsite <<'SQL'
CREATE TABLE ktvs_options (variable VARCHAR(64) NOT NULL PRIMARY KEY, value TEXT) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
INSERT INTO ktvs_options VALUES ('INITIAL_VERSION', '7.0.2');
CREATE TABLE ktvs_videos (video_id INT NOT NULL PRIMARY KEY, title VARCHAR(64)) ENGINE=InnoDB;
INSERT INTO ktvs_videos VALUES (1, 'first');
CREATE FUNCTION kvs_double(x INT) RETURNS INT DETERMINISTIC RETURN x * 2;
CREATE VIEW ktvs_videos_doubled AS SELECT video_id, kvs_double(video_id) AS twice FROM ktvs_videos;
SQL
export_dump "$disabled_container" kvs "$site_password" "$test_dir/disabled.sql.gz" ||
    { cat "$test_dir/disabled.sql.gz.err" >&2; fail "a server whose event scheduler is DISABLED must still export"; }
if ! grep -Fq 'WARNING: the events of oldsite could not be listed (ERROR 1577 (HY000)' "$test_dir/disabled.sql.gz.err" ||
    ! grep -Fq 'event_scheduler=OFF or ON instead of DISABLED' "$test_dir/disabled.sql.gz.err"; then
    cat "$test_dir/disabled.sql.gz.err" >&2
    fail "the export must say why no event travels"
fi
replay "$test_dir/disabled.sql.gz" "$prefix-disabled-target"
[ "$(sql "$prefix-disabled-target" root kvs -e 'SELECT twice FROM ktvs_videos_doubled WHERE video_id = 1')" = 2 ] ||
    fail "the routine of a server whose event scheduler is DISABLED must travel"
echo "PASS: a server whose event scheduler is DISABLED exports its routines and says why no event travels"

# A mysql.proc older than the server (an upgrade without mysql_upgrade,
# which also leaves mysql.event behind and the scheduler off) fails every
# routine listing with error 1805: the tables still travel. A view using a
# routine cannot be dumped from such a server at all, so it goes first.
sql "$disabled_container" kvs oldsite -e 'DROP VIEW ktvs_videos_doubled'
sql "$disabled_container" root -e 'ALTER TABLE mysql.proc DROP COLUMN aggregate'
export_dump "$disabled_container" kvs "$site_password" "$test_dir/stale-proc.sql.gz" ||
    { cat "$test_dir/stale-proc.sql.gz.err" >&2; fail "a stale mysql.proc must not stop the export"; }
if ! grep -Fq 'WARNING: the stored routines of oldsite could not be listed (ERROR 1805 (HY000)' "$test_dir/stale-proc.sql.gz.err" ||
    ! grep -Fq 'run mysql_upgrade (mariadb-upgrade on MariaDB 10.4 and later) on this server, whose mysql.proc is older than the server' "$test_dir/stale-proc.sql.gz.err" ||
    ! grep -Fq 'WARNING: the events of oldsite could not be listed (ERROR 1577 (HY000)' "$test_dir/stale-proc.sql.gz.err"; then
    cat "$test_dir/stale-proc.sql.gz.err" >&2
    fail "the export must say that the routines and events stay behind and how to carry them"
fi
grep -q '^CREATE TABLE `ktvs_videos`' <(gzip -dc "$test_dir/stale-proc.sql.gz") || fail "the tables must still travel"
if grep -q 'FUNCTION `kvs_double`' <(gzip -dc "$test_dir/stale-proc.sql.gz"); then
    fail "the routines cannot be dumped from a stale mysql.proc"
fi
docker rm -f "$disabled_container" "$prefix-disabled-target" >/dev/null
echo "PASS: a stale mysql.proc leaves the routines behind with a warning, the export goes on"

# An account that may use the routines but not read their bodies: the dump
# tool would stop on the first one, so the export refuses before it starts.
sql "$source_container" root -e "CREATE USER 'reader'@'%' IDENTIFIED BY '$site_password';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER, LOCK TABLES, CREATE VIEW, SHOW VIEW, TRIGGER, EXECUTE, EVENT ON oldsite.* TO 'reader'@'%';"
status=0
export_dump "$source_container" reader "$site_password" "$test_dir/refused.sql.gz" || status=$?
[ "$status" = 3 ] || { cat "$test_dir/refused.sql.gz.err" >&2; fail "an unreadable routine must stop the export with status 3, got $status"; }
grep -Fq '2 of the 2 stored routines of oldsite' "$test_dir/refused.sql.gz.err" ||
    { cat "$test_dir/refused.sql.gz.err" >&2; fail "the refusal must name the routines it cannot read"; }
[ ! -s "$test_dir/refused.sql.gz" ] || fail "the refused export must not write a dump"
echo "PASS: an account that may not read the routine bodies is refused before the dump"
