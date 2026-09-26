#!/bin/bash
# Run the complete setup recovery branch with isolated files and strict stubs.
# shellcheck disable=SC2016
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/kvs-resume-flow.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"

cat > "$fixture/bin/docker" <<'SH'
#!/bin/bash
set -euo pipefail
case "$*" in
    'compose ps -a -q mariadb')
        if [ "${HANG_METADATA:-no}" = yes ]; then exec /usr/bin/sleep 30; fi
        echo 0123456789abcdef ;;
    'inspect --format {{index .Config.Labels '*)
        printf 'kvs-resume\trunning 0 false\tvolume:kvs-resume_mariadb-data:/fixture/volume\t2026-09-26T21:10:43Z\n' ;;
    'compose config --services') printf 'mariadb\nphp-fpm\nnginx\ncron\nmemcached\nphpmyadmin-init\nkvs-init\n' ;;
    'compose --profile setup config --images kvs-init') echo kvs-resume-kvs-init ;;
    'image inspect --format {{.Id}} kvs-resume-kvs-init')
        echo check-init-image >> "$CALLS"
        [ "${FAIL_INIT_IMAGE:-no}" != yes ] || exit 1
        ;;
    'compose --profile setup run --rm --no-deps --pull missing phpmyadmin-init')
        echo phpmyadmin-init >> "$CALLS" ;;
    'compose --profile setup run --rm --no-deps --pull missing kvs-init')
        echo kvs-init >> "$CALLS"
        [ "${FAIL_KVS_INIT:-no}" != yes ] || { echo 'Simulated KVS initialization failure' >&2; exit 8; }
        ;;
    'compose up -d --no-deps --no-recreate --no-build --pull missing php-fpm'|\
        'compose up -d --no-deps --no-recreate --no-build --pull missing nginx'|\
        'compose up -d --no-deps --no-recreate --no-build --pull missing php-fpm nginx cron memcached')
        printf 'runtime:%s\n' "$*" >> "$CALLS" ;;
    'compose exec nginx nginx -s reload') echo reload-nginx >> "$CALLS" ;;
    'compose exec -T mariadb sh -c '*)
        query=${!#}
        case "$query" in
            *"login='admin'"*) echo 0 ;;
            'SELECT 1') echo 1 ;;
            *'FROM information_schema.schemata '*|*'FROM mysql.user '*) echo 1 ;;
            "SHOW TABLES LIKE '%options%';") echo ktvs_options ;;
            'UPDATE ktvs_options SET '*"WHERE variable='MAIN_SERVER_MIN_FREE_SPACE_MB';"|\
                'UPDATE ktvs_options SET '*"WHERE variable='SERVER_GROUP_MIN_FREE_SPACE_MB';") echo disk-setting >> "$CALLS" ;;
            'SELECT table_name FROM information_schema.tables '*) printf 'ktvs_options\nktvs_videos\n' ;;
            "SELECT 'ktvs_options', COUNT(*) FROM "*)
                echo count-rows >> "$CALLS"
                printf 'ktvs_options\t2\nktvs_videos\t17\n' ;;
            "DELETE FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';")
                grep -q '^KVS_IMPORT_COMPLETED=' .env || exit 9
                echo delete-marker >> "$CALLS"
                rm "$MARKER_FILE" ;;
            *) echo unexpected:sql >> "$CALLS"; printf 'Unexpected SQL: %s\n' "$query" >&2; exit 97 ;;
        esac
        ;;
    *) echo unexpected:docker >> "$CALLS"; printf 'Unexpected Docker command: %s\n' "$*" >&2; exit 97 ;;
esac
SH
cat > "$fixture/bin/gum" <<'SH'
#!/bin/bash
case "$1" in
    style) exit 0 ;;
    spin)
        while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
        [ "$#" -gt 0 ] || exit 97
        shift
        exec "$@"
        ;;
    *) echo unexpected:gum >> "$CALLS"; echo 'Unexpected gum command' >&2; exit 97 ;;
esac
SH
cat > "$fixture/bin/blocked" <<'SH'
#!/bin/bash
printf 'Forbidden command in setup recovery test: %s\n' "$0" >&2
printf 'unexpected:%s\n' "$0" >> "$CALLS"
exit 97
SH
chmod +x "$fixture/bin/"*
for tool in curl wget ssh scp rsync sudo apt apt-get pacman systemctl openssl sleep; do
    ln -s blocked "$fixture/bin/$tool"
done

make_case() {
    local directory=$1
    mkdir -p "$directory/lib" "$directory/mariadb/init" "$directory/site/resume.example.com/admin/include"
    python3 - "$root/docker/setup.sh" "$directory/setup.sh" "$directory" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert text.count('if [ "$EUID" -ne 0 ]; then') == 1
text = text.replace('if [ "$EUID" -ne 0 ]; then', 'if false; then')
text = text.replace('/opt/kvs/logs', sys.argv[3] + '/logs')
text = text.replace('/var/www/', sys.argv[3] + '/site/')
Path(sys.argv[2]).write_text(text)
PY
    cp "$root/docker/lib/import.sh" "$directory/lib/import.sh"
    cat > "$directory/lib/database.sh" <<'SH'
database_wait_ready() {
    [ "$1" = 0 ] || return 97
    echo wait >> "$CALLS"
}
SH
    cat > "$directory/lib/import-resume.sh" <<'SH'
import_resume_discover() {
    [ "$1" = mariadb/init ] && [ "$2" = resume.example.com ] && [ "$3" = ktvs_ ] || return 97
    echo discover >> "$CALLS"
    IMPORT_STAGED_DUMP=mariadb/init/10-kvs-import.sql
    IMPORT_DB_DUMP=$IMPORT_STAGED_DUMP
    IMPORT_DUMP_TABLES=2
}
import_resume_marker() { echo marker >> "$CALLS"; cat "$MARKER_FILE"; }
import_resume_token() {
    [ -s "$1" ] || return 97
    echo token >> "$CALLS"
    echo 20260926T211043Z-1234abcd
}
import_resume_verify() {
    [ "$3" = "$(cat "$MARKER_FILE")" ] || return 1
    echo verify >> "$CALLS"
}
SH
    cat > "$directory/.env" <<'ENV'
DOMAIN=resume.example.com
SITE_PREFIX=kvs-resume
COMPOSE_PROJECT_NAME=kvs-resume
TABLES_PREFIX=ktvs_
MARIADB_VERSION=12.3
MODE=single
SSL_PROVIDER=selfsigned
USE_WWW=false
COMPOSE_PROFILES=memcached
ENV
    cp "$directory/.env" "$directory/.env.example"
    touch "$directory/docker-compose.yml"
    echo 'original staged artifact' > "$directory/mariadb/init/10-kvs-import.sql"
    echo 20260926T211043Z-1234abcd > "$directory/database-marker"
    cat > "$directory/site/resume.example.com/admin/include/setup.php" <<'PHP'
<?php
$config['project_path']='/old/site';
$config['project_url']='https://resume.example.com';
$config['tables_prefix']='ktvs_';
PHP
    echo '<?php' > "$directory/site/resume.example.com/admin/include/setup_db.php"
    cat > "$directory/site/resume.example.com/admin/include/version.php" <<'PHP'
<?php
/* Developed by Kernel Team. */
$config['project_version']='7.0.2';
PHP
}

run_case() {
    local directory=$1 failure=$2 image_failure=${3:-no}
    (
        cd "$directory"
        export CALLS="$directory/calls" MARKER_FILE="$directory/database-marker"
        export FAIL_KVS_INIT="$failure" FAIL_INIT_IMAGE="$image_failure" PATH="$fixture/bin:/usr/bin:/bin"
        unset MARIADB_WAIT_SECONDS
        bash ./setup.sh --resume-import
    ) > "$directory/output.log" 2>&1
}

make_case "$fixture/success"
if ! run_case "$fixture/success" no; then
    cat "$fixture/success/output.log" >&2
    exit 1
fi
grep -Fxq phpmyadmin-init "$fixture/success/calls"
grep -Fxq kvs-init "$fixture/success/calls"
grep -Fxq 'runtime:compose up -d --no-deps --no-recreate --no-build --pull missing php-fpm nginx cron memcached' "$fixture/success/calls"
grep -Fxq reload-nginx "$fixture/success/calls"
grep -Fxq delete-marker "$fixture/success/calls"
if grep -q '^unexpected:' "$fixture/success/calls"; then
    cat "$fixture/success/calls" >&2
    exit 1
fi
grep -q '^KVS_IMPORT_COMPLETED=' "$fixture/success/.env"
grep -Fxq $'ktvs_videos\t17' "$fixture/success/logs/import-rows.txt"
[ ! -e "$fixture/success/mariadb/init/10-kvs-import.sql" ]
[ ! -e "$fixture/success/database-marker" ]
python3 - "$fixture/success/calls" <<'PY'
from pathlib import Path
import sys
calls = Path(sys.argv[1]).read_text().splitlines()
expected = ['discover', 'wait', 'marker', 'token', 'verify', 'check-init-image', 'phpmyadmin-init',
            'kvs-init', 'reload-nginx', 'count-rows', 'delete-marker']
positions = [calls.index(item) for item in expected]
assert positions == sorted(positions), calls
PY
echo 'PASS: full --resume-import runs both initializers, preserves MariaDB, starts runtime services and records completion before cleanup.'

make_case "$fixture/failure"
if run_case "$fixture/failure" yes; then
    echo 'FAIL: KVS initialization failure was ignored' >&2
    exit 1
fi
grep -Fxq phpmyadmin-init "$fixture/failure/calls"
grep -Fxq kvs-init "$fixture/failure/calls"
grep -q 'Simulated KVS initialization failure' "$fixture/failure/output.log"
[ -s "$fixture/failure/mariadb/init/10-kvs-import.sql" ]
[ "$(cat "$fixture/failure/database-marker")" = 20260926T211043Z-1234abcd ]
if grep -q '^KVS_IMPORT_COMPLETED=' "$fixture/failure/.env" ||
    grep -Eq '^(runtime:|delete-marker|count-rows|unexpected:)' "$fixture/failure/calls"; then
    echo 'FAIL: failed initialization continued finalization or ran an unexpected command' >&2
    exit 1
fi
echo 'PASS: full --resume-import preserves the staged dump and database marker when KVS initialization fails.'

make_case "$fixture/missing-init-image"
if run_case "$fixture/missing-init-image" no yes; then
    echo 'FAIL: recovery ignored the missing KVS initializer image' >&2
    exit 1
fi
grep -Fxq check-init-image "$fixture/missing-init-image/calls"
[ -s "$fixture/missing-init-image/mariadb/init/10-kvs-import.sql" ]
[ "$(cat "$fixture/missing-init-image/database-marker")" = 20260926T211043Z-1234abcd ]
if grep -q '^KVS_IMPORT_COMPLETED=' "$fixture/missing-init-image/.env" ||
    grep -Eq '^(phpmyadmin-init|kvs-init|runtime:|delete-marker|count-rows|unexpected:)' "$fixture/missing-init-image/calls"; then
    echo 'FAIL: recovery changed the import or initialized services without its existing KVS image' >&2
    exit 1
fi
echo 'PASS: a missing KVS initializer image stops recovery before initialization and preserves the import.'

make_case "$fixture/metadata-timeout"
python3 - "$fixture/metadata-timeout" "$fixture/bin" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import time

directory = Path(sys.argv[1])
env = dict(os.environ, CALLS=str(directory / 'calls'), HANG_METADATA='yes',
           MARKER_FILE=str(directory / 'database-marker'), PATH=sys.argv[2] + ':/usr/bin:/bin')
env.pop('MARIADB_WAIT_SECONDS', None)
output = directory / 'output.log'
started = time.monotonic()
with output.open('w') as stream:
    process = subprocess.Popen(['bash', './setup.sh', '--resume-import'], cwd=directory,
                               env=env, stdout=stream, stderr=subprocess.STDOUT)
    try:
        while 'Locating the existing MariaDB container...' not in output.read_text():
            assert process.poll() is None, output.read_text()
            assert time.monotonic() - started < 2, 'No immediate startup status'
            time.sleep(0.02)
        assert 'Inspecting the saved import configuration' in output.read_text()
        assert process.wait(timeout=5) != 0, 'A hung metadata check was ignored'
        assert time.monotonic() - started < 5, 'The Docker metadata check was not bounded'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
assert 'Docker metadata check failed or exceeded its time limit' in output.read_text()
assert not (directory / 'calls').exists(), 'Recovery proceeded after an unavailable Docker response'
assert (directory / 'mariadb/init/10-kvs-import.sql').exists()
assert (directory / 'database-marker').exists()
assert 'KVS_IMPORT_COMPLETED=' not in (directory / '.env').read_text()
PY
echo 'PASS: a hung Docker metadata check displays immediate status, times out and preserves the import.'
