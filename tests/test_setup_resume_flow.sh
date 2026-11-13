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
    'compose version') echo 'Docker Compose version v2.32.2' ;;
    'compose ps -a -q mariadb')
        if [ "${HANG_METADATA:-no}" = yes ]; then exec /usr/bin/sleep 30; fi
        # A host still loaded by the import answers one check late, as the
        # lab did when recovery started the runtime services.
        if [ "${SLOW_METADATA:-no}" = yes ] && grep -Fxq kvs-init "$CALLS" 2>/dev/null && [ ! -e "$CALLS.slow" ]; then
            : > "$CALLS.slow"
            /usr/bin/sleep 4
        fi
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
        printf 'kvs-init-rewrites-sha256:%s\n' "${KVS_NGINX_REWRITES_SHA256:-}" >> "$CALLS"
        [ "${FAIL_KVS_INIT:-no}" != yes ] || { echo 'Simulated KVS initialization failure' >&2; exit 8; }
        ;;
    'compose up -d --no-deps --no-recreate --no-build --pull missing php-fpm'|\
        'compose up -d --no-deps --no-recreate --no-build --pull missing nginx'|\
        'compose up -d --no-deps --no-recreate --no-build --pull missing php-fpm nginx memcached')
        printf 'runtime:%s\n' "$*" >> "$CALLS" ;;
    'compose stop cron') echo stop-cron >> "$CALLS" ;;
    'compose up -d --no-deps --no-recreate --no-build --pull missing cron')
        [ ! -e "$MARKER_FILE" ] || exit 98
        [ ! -e mariadb/init/10-kvs-import.sql ] || exit 98
        grep -q '^KVS_IMPORT_COMPLETED=' .env || exit 98
        echo start-cron >> "$CALLS" ;;
    'compose exec -T nginx nginx -s reload')
        # What a real Nginx does with a new key next to the old certificate.
        if [ "${FAIL_ALL_RELOAD:-no}" = yes ]; then
            echo reload-nginx-failed >> "$CALLS"
            exit 1
        fi
        if [ "${FAIL_FIRST_RELOAD:-no}" = yes ] && [ ! -e "$CALLS.reload-failed" ]; then
            : > "$CALLS.reload-failed"
            echo reload-nginx-failed >> "$CALLS"
            exit 1
        fi
        # The first reload works, every later one fails.
        if [ "${FAIL_SECOND_RELOAD:-no}" = yes ]; then
            if [ -e "$CALLS.reload-ok" ]; then
                echo reload-nginx-failed >> "$CALLS"
                exit 1
            fi
            : > "$CALLS.reload-ok"
        fi
        echo reload-nginx >> "$CALLS" ;;
    # A public certificate: by default the CA refuses it (DNS still on the
    # old server). $CERTS/live stands for the acme-certs volume Nginx reads;
    # the pair setup saves and puts back runs its real script on it.
    'compose up -d --no-deps --no-recreate --no-build --pull missing acme')
        echo start-acme >> "$CALLS"
        [ "${FAIL_ACME_START:-no}" != yes ] || exit 1 ;;
    'compose exec -T acme sh -c '*' sh save /etc/nginx/ssl/resume.example.com /tmp/kvs-setup-previous-certificate'|\
        'compose exec -T acme sh -c '*' sh restore /etc/nginx/ssl/resume.example.com /tmp/kvs-setup-previous-certificate'|\
        'compose exec -T acme sh -c '*' sh discard /etc/nginx/ssl/resume.example.com /tmp/kvs-setup-previous-certificate')
        echo "cert-$9" >> "$CALLS"
        if [ "$9" = restore ] && [ "${FAIL_CERT_RESTORE:-no}" = yes ]; then exit 1; fi
        sh -c "$7" sh "$9" "$CERTS/live" "$CERTS/saved" ;;
    'compose exec -T acme sh -c '*)
        [ "${FAIL_ACME_API:-no}" != yes ] || exit 1
        if [ -e "$CALLS.issued" ]; then echo https://acme-v02.api.letsencrypt.org/directory; else echo __KVS_ABSENT__; fi ;;
    'compose exec -T -e KVS_CERT_PROVIDER='*)
        [ "${ACCEPT_INSTALLED:-no}" = yes ] && grep -Fxq 'issued cert' "$CERTS/live/cert.pem" ;;
    'compose exec -T acme acme.sh --issue '*)
        echo acme-issue >> "$CALLS"
        if [ "${ACME_ISSUE:-refused}" = ok ]; then : > "$CALLS.issued"; exit 0; fi
        echo 'Verify error: DNS problem: NXDOMAIN looking up A for resume.example.com'
        exit 1
        ;;
    # acme.sh writes the key, then the full chain.
    'compose exec -T acme acme.sh --install-cert '*)
        echo install-cert >> "$CALLS"
        echo 'issued key' > "$CERTS/live/key.pem"
        if [ "${ACME_INSTALL:-ok}" = partial ]; then echo 'Simulated failure after the key was written' >&2; exit 1; fi
        echo 'issued cert' > "$CERTS/live/cert.pem" ;;
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
                if [ "${SLOW_ROW_COUNT:-no}" = yes ]; then /usr/bin/sleep 6; fi
                [ "${FAIL_ROW_COUNT:-no}" != yes ] || exit 9
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
    --version) echo 'gum version v2.0.2 (test)' ;;
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
for tool in curl wget ssh scp rsync sudo apt apt-get pacman systemctl openssl; do
    ln -s blocked "$fixture/bin/$tool"
done

make_case() {
    local directory=$1
    mkdir -p "$directory/lib" "$directory/mariadb/init" "$directory/site/resume.example.com/admin/include" \
        "$directory/certs/live"
    echo 'previous cert' > "$directory/certs/live/cert.pem"
    echo 'previous key' > "$directory/certs/live/key.pem"
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
    cp "$root/docker/lib/database.sh" "$directory/lib/database.sh"
    cat >> "$directory/lib/database.sh" <<'SH'
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
        export CALLS="$directory/calls" MARKER_FILE="$directory/database-marker" CERTS="$directory/certs"
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
grep -Fxq 'runtime:compose up -d --no-deps --no-recreate --no-build --pull missing php-fpm nginx memcached' "$fixture/success/calls"
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
            'kvs-init', 'stop-cron', 'reload-nginx', 'count-rows', 'delete-marker', 'start-cron']
positions = [calls.index(item) for item in expected]
assert positions == sorted(positions), calls
PY
echo 'PASS: full --resume-import runs both initializers, preserves MariaDB, starts runtime services and records completion before cleanup.'
grep -Fxq 'kvs-init-rewrites-sha256:' "$fixture/success/calls" ||
    { echo 'FAIL: a resume whose pass vouched for no rewrites passed a sha256 to the init' >&2; exit 1; }

# The interrupted pass wrote the operator's rewrites into _INSTALL and kept
# the record of them in import/; the site's copy changed since. The resumed
# init must get the rules of that pass and their sha256 (C2), not fall back
# to the archive's stock rules or stop for want of any.
make_case "$fixture/rewrites"
mkdir -p "$fixture/rewrites/import" "$fixture/rewrites/site/resume.example.com/_INSTALL"
chmod 700 "$fixture/rewrites/import"
echo 'rewrite ^/custom-seo/(.*)$ /view_video.php?dir=$1 last;' > "$fixture/rewrites/import/resume.example.com.nginx_config.vouched"
echo 'rewrite ^/planted$ /planted.php last;' > "$fixture/rewrites/site/resume.example.com/_INSTALL/nginx_config.txt"
if ! run_case "$fixture/rewrites" no; then
    cat "$fixture/rewrites/output.log" >&2
    exit 1
fi
rules_sha=$(sha256sum < "$fixture/rewrites/import/resume.example.com.nginx_config.vouched" | cut -d' ' -f1)
if ! grep -Fxq "kvs-init-rewrites-sha256:$rules_sha" "$fixture/rewrites/calls" ||
    ! cmp -s "$fixture/rewrites/import/resume.example.com.nginx_config.vouched" \
        "$fixture/rewrites/site/resume.example.com/_INSTALL/nginx_config.txt"; then
    grep '^kvs-init-rewrites-sha256:' "$fixture/rewrites/calls" >&2 || true
    echo 'FAIL: the resumed init did not get the rewrites the interrupted pass wrote for it' >&2
    exit 1
fi
grep -q '^KVS_IMPORT_COMPLETED=' "$fixture/rewrites/.env"
echo 'PASS: --resume-import gives the init the rewrites of the interrupted pass and their sha256.'

make_case "$fixture/slow-count"
if ! SLOW_ROW_COUNT=yes run_case "$fixture/slow-count" no; then
    cat "$fixture/slow-count/output.log" >&2
    exit 1
fi
grep -q 'Counting imported rows in every table' "$fixture/slow-count/output.log"
grep -Eq 'MariaDB: [5-9][0-9]*s elapsed; import row counts are still running' "$fixture/slow-count/output.log"
[ "$(grep -vc '^#' "$fixture/slow-count/logs/import-rows.txt")" = 2 ]
grep -Fxq $'ktvs_videos\t17' "$fixture/slow-count/logs/import-rows.txt"
grep -Fxq start-cron "$fixture/slow-count/calls"
echo 'PASS: slow row counts show periodic status without contaminating the saved row-count report.'

make_case "$fixture/slow-metadata"
if ! SLOW_METADATA=yes run_case "$fixture/slow-metadata" no; then
    cat "$fixture/slow-metadata/output.log" >&2
    echo 'FAIL: a Docker check that answered after four seconds stopped recovery' >&2
    exit 1
fi
[ -e "$fixture/slow-metadata/calls.slow" ]
grep -q '^KVS_IMPORT_COMPLETED=' "$fixture/slow-metadata/.env"
grep -Fxq start-cron "$fixture/slow-metadata/calls"
echo 'PASS: a Docker check that answers late on a loaded host does not stop recovery.'

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

make_case "$fixture/count-failure"
if FAIL_ROW_COUNT=yes run_case "$fixture/count-failure" no; then
    echo 'FAIL: row-count failure was ignored' >&2
    exit 1
fi
grep -Fxq stop-cron "$fixture/count-failure/calls"
grep -Fxq count-rows "$fixture/count-failure/calls"
grep -q 'could not count the imported rows' "$fixture/count-failure/output.log"
[ -s "$fixture/count-failure/mariadb/init/10-kvs-import.sql" ]
[ "$(cat "$fixture/count-failure/database-marker")" = 20260926T211043Z-1234abcd ]
if grep -q '^KVS_IMPORT_COMPLETED=' "$fixture/count-failure/.env" ||
    grep -Eq '^(delete-marker|start-cron|unexpected:)' "$fixture/count-failure/calls"; then
    echo 'FAIL: failed row counts started cron or discarded recovery state' >&2
    exit 1
fi
echo 'PASS: failed row counts preserve recovery state and keep cron stopped.'

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
env = dict(os.environ, CALLS=str(directory / 'calls'), HANG_METADATA='yes', DOCKER_QUERY_TIMEOUT_SECONDS='2',
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

# The CA refuses the public certificate (DNS still on the old server, the
# normal state in the middle of a migration). The run must still start the
# runtime services, finish the import and start cron, then end with an
# error that names the command to issue the certificate later, instead of
# stopping at the ACME step with the cache, Manticore, cron and the import
# left undone.
make_case "$fixture/acme-failure"
sed -i 's/^SSL_PROVIDER=selfsigned$/SSL_PROVIDER=letsencrypt/' "$fixture/acme-failure/.env"
echo 'EMAIL=ops@resume.example.com' >> "$fixture/acme-failure/.env"
if run_case "$fixture/acme-failure" no; then
    echo 'FAIL: a refused certificate ended the setup with status 0' >&2
    exit 1
fi
for step in acme-issue 'runtime:compose up -d --no-deps --no-recreate --no-build --pull missing php-fpm nginx memcached' \
    reload-nginx delete-marker start-cron; do
    if ! grep -Fxq "$step" "$fixture/acme-failure/calls"; then
        tail -n 20 "$fixture/acme-failure/output.log" >&2
        echo "FAIL: a refused certificate stopped the setup before: $step" >&2
        exit 1
    fi
done
if grep -q '^unexpected:' "$fixture/acme-failure/calls"; then
    cat "$fixture/acme-failure/calls" >&2
    exit 1
fi
if ! grep -q '^KVS_IMPORT_COMPLETED=' "$fixture/acme-failure/.env" ||
    [ -e "$fixture/acme-failure/mariadb/init/10-kvs-import.sql" ]; then
    echo 'FAIL: a refused certificate left the import unfinished' >&2
    exit 1
fi
# gum is stubbed, so the success banner prints nothing here: the run must
# print its own line saying the certificate is missing instead.
for line in 'NXDOMAIN looking up A for resume.example.com' \
    'KVS Docker Setup finished without the letsencrypt certificate' \
    'ERROR: no letsencrypt certificate was installed for resume.example.com' \
    'Once resume.example.com points to this server, or the certificate authority answers again, issue it with:' \
    "cd $fixture/acme-failure && ./reconfigure.sh"; do
    if ! grep -Fq "$line" "$fixture/acme-failure/output.log"; then
        tail -n 20 "$fixture/acme-failure/output.log" >&2
        echo "FAIL: a refused certificate did not report: $line" >&2
        exit 1
    fi
done
python3 - "$fixture/acme-failure/calls" <<'PY'
from pathlib import Path
import sys
calls = Path(sys.argv[1]).read_text().splitlines()
expected = ['kvs-init', 'start-acme', 'acme-issue', 'stop-cron', 'reload-nginx', 'count-rows',
            'delete-marker', 'start-cron']
positions = [calls.index(item) for item in expected]
assert positions == sorted(positions), calls
PY
echo 'PASS: a refused certificate still finishes the runtime start, the import and cron, then fails with the retry command.'

# The CA issues the certificate, then setup rejects what acme.sh installed:
# wrong provider, a half-written pair, Nginx refusing it. The pair Nginx had
# must be back on disk, so the reload that follows serves it again and the
# messages saying Nginx kept it stay true. acme_case runs one such case with
# the stub settings it is given.
acme_case() {
    local name=$1
    shift
    make_case "$fixture/$name"
    sed -i 's/^SSL_PROVIDER=selfsigned$/SSL_PROVIDER=letsencrypt/' "$fixture/$name/.env"
    echo 'EMAIL=ops@resume.example.com' >> "$fixture/$name/.env"
    (
        export ACME_ISSUE=ok
        local setting
        for setting in "$@"; do
            export "${setting?}"
        done
        run_case "$fixture/$name" no
    )
}
acme_rejected_case() {
    local name=$1 directory="$fixture/$1"
    shift
    if acme_case "$name" "$@"; then
        echo "FAIL: $name: a rejected certificate ended the setup with status 0" >&2
        exit 1
    fi
    if grep -q '^unexpected:' "$directory/calls"; then
        cat "$directory/calls" >&2
        echo "FAIL: $name: unexpected command" >&2
        exit 1
    fi
    for step in install-cert cert-save cert-restore delete-marker start-cron; do
        if ! grep -Fxq "$step" "$directory/calls"; then
            tail -n 20 "$directory/output.log" >&2
            echo "FAIL: $name: no $step" >&2
            exit 1
        fi
    done
    if [ "$(cat "$directory/certs/live/cert.pem")" != 'previous cert' ] ||
        [ "$(cat "$directory/certs/live/key.pem")" != 'previous key' ]; then
        tail -n 20 "$directory/output.log" >&2
        echo "FAIL: $name: the pair Nginx had was not put back" >&2
        exit 1
    fi
    if [ -e "$directory/certs/saved" ] || compgen -G "$directory/certs/live/.*.previous" >/dev/null; then
        echo "FAIL: $name: the saved pair was left behind" >&2
        exit 1
    fi
    python3 - "$directory/calls" <<'PY'
from pathlib import Path
import sys
calls = Path(sys.argv[1]).read_text().splitlines()
expected = ['acme-issue', 'cert-save', 'install-cert', 'cert-restore', 'reload-nginx', 'delete-marker', 'start-cron']
positions = [calls.index(item) for item in expected]
assert positions == sorted(positions), calls
PY
    for line in 'Nginx keeps the certificate it had' \
        'The certificate Nginx had is back in /etc/nginx/ssl/resume.example.com' \
        'ERROR: no letsencrypt certificate was installed for resume.example.com; the site answers with the certificate Nginx already had' \
        'The certificate authority issued it, but setup could not put it in place (see the error above)'; do
        if ! grep -Fq "$line" "$directory/output.log"; then
            tail -n 20 "$directory/output.log" >&2
            echo "FAIL: $name: did not report: $line" >&2
            exit 1
        fi
    done
    if grep -Fq 'Once resume.example.com points to this server' "$directory/output.log"; then
        echo "FAIL: $name: the retry advice blames DNS or the CA for a certificate they issued" >&2
        exit 1
    fi
}

acme_rejected_case acme-wrong-provider
grep -Fq 'Installed SSL certificate was not issued by the requested provider' "$fixture/acme-wrong-provider/output.log"
echo 'PASS: an installed certificate from the wrong provider is undone and Nginx reloads the pair it had.'

acme_rejected_case acme-partial ACME_INSTALL=partial
grep -Fq 'SSL certificate installation failed' "$fixture/acme-partial/output.log"
echo 'PASS: a half-written install is undone: the new key does not stay next to the old certificate.'

acme_rejected_case acme-reload ACCEPT_INSTALLED=yes FAIL_FIRST_RELOAD=yes
grep -Fxq reload-nginx-failed "$fixture/acme-reload/calls"
echo 'PASS: a certificate Nginx refused to reload is undone before the final reload.'

# The retry command names the directory quoted for the shell. The run goes
# through a link whose name holds a space and a quote, the directory setup
# sees as its own.
make_case "$fixture/acme-quoted"
ln -s acme-quoted "$fixture/acme quoted's"
sed -i 's/^SSL_PROVIDER=selfsigned$/SSL_PROVIDER=letsencrypt/' "$fixture/acme-quoted/.env"
echo 'EMAIL=ops@resume.example.com' >> "$fixture/acme-quoted/.env"
if run_case "$fixture/acme quoted's" no; then
    echo 'FAIL: a refused certificate ended the setup with status 0 (quoted directory)' >&2
    exit 1
fi
expected=$(printf '  cd %q && ./reconfigure.sh' "$fixture/acme quoted's")
if ! grep -Fxq -- "$expected" "$fixture/acme quoted's/output.log"; then
    tail -n 5 "$fixture/acme quoted's/output.log" >&2
    echo "FAIL: the retry command is not quoted for the shell: expected $expected" >&2
    exit 1
fi
echo 'PASS: the retry command quotes the setup directory.'

# A half-written install whose restore fails as well: the new key stays next
# to the old certificate, so every Nginx reload fails. setup must not claim
# Nginx kept its certificate, and the final reload failing must not stop the
# run before the import, cron and the final error it announced.
status=0
acme_case acme-restore-failure ACME_INSTALL=partial FAIL_CERT_RESTORE=yes FAIL_ALL_RELOAD=yes || status=$?
if [ "$status" -ne 1 ]; then
    echo "FAIL: a failed restore ended the setup with status $status instead of 1" >&2
    exit 1
fi
for step in reload-nginx-failed delete-marker start-cron; do
    if ! grep -Fxq "$step" "$fixture/acme-restore-failure/calls"; then
        tail -n 20 "$fixture/acme-restore-failure/output.log" >&2
        echo "FAIL: a failed restore and a refused reload stopped the setup before: $step" >&2
        exit 1
    fi
done
grep -q '^KVS_IMPORT_COMPLETED=' "$fixture/acme-restore-failure/.env" ||
    { echo 'FAIL: a failed restore and a refused reload left the import unfinished' >&2; exit 1; }
for line in 'Could not put back the certificate Nginx had in /etc/nginx/ssl/resume.example.com' \
    'was rejected and the certificate Nginx had could not be put back' \
    'WARNING: Nginx could not be reloaded; the setup goes on and ends with an error.' \
    'may be the rejected one' \
    './reconfigure.sh recreates Nginx, which replaces a missing or mismatched pair with a self-signed one' \
    'Nginx could not be reloaded at the end of the setup either' \
    "cd $fixture/acme-restore-failure && ./reconfigure.sh"; do
    if ! grep -Fq "$line" "$fixture/acme-restore-failure/output.log"; then
        tail -n 20 "$fixture/acme-restore-failure/output.log" >&2
        echo "FAIL: a failed restore did not report: $line" >&2
        exit 1
    fi
done
if grep -Fq 'Nginx keeps the certificate it had' "$fixture/acme-restore-failure/output.log" ||
    grep -Fq 'the site answers with the certificate Nginx already had' "$fixture/acme-restore-failure/output.log"; then
    echo 'FAIL: a failed restore still says Nginx kept its certificate' >&2
    exit 1
fi
echo 'PASS: a failed restore is reported as such, and a refused final reload still lets the run finish.'

# Whenever the pair on disk is the one Nginx had, or the certificate it
# accepted, a refused final reload is a real Nginx error and still stops the
# run as before, right after the reload: the import stays unfinished, cron
# stays stopped and the run exits 1. reload_fatal_check checks one such run,
# given its status and the pair it must leave on disk.
reload_fatal_check() {
    local name=$1 status=$2 key=$3 cert=$4 directory="$fixture/$1" step line
    if [ "$status" -ne 1 ]; then
        tail -n 20 "$directory/output.log" >&2
        echo "FAIL: $name: a refused final reload ended the setup with status $status instead of 1" >&2
        exit 1
    fi
    if grep -q '^unexpected:' "$directory/calls" ||
        [ "$(tail -n 1 "$directory/calls")" != reload-nginx-failed ]; then
        cat "$directory/calls" >&2
        echo "FAIL: $name: the run did not stop right after the refused final reload" >&2
        exit 1
    fi
    for step in delete-marker start-cron; do
        if grep -Fxq "$step" "$directory/calls"; then
            echo "FAIL: $name: the run went on to $step after a refused final reload" >&2
            exit 1
        fi
    done
    if grep -q '^KVS_IMPORT_COMPLETED=' "$directory/.env" ||
        [ ! -s "$directory/mariadb/init/10-kvs-import.sql" ] ||
        [ "$(cat "$directory/database-marker")" != 20260926T211043Z-1234abcd ]; then
        echo "FAIL: $name: a refused final reload did not keep the import to resume" >&2
        exit 1
    fi
    for line in 'WARNING: Nginx could not be reloaded' 'KVS Docker Setup finished without' \
        'Nginx could not be reloaded at the end of the setup either'; do
        if grep -Fq "$line" "$directory/output.log"; then
            tail -n 20 "$directory/output.log" >&2
            echo "FAIL: $name: a refused final reload was reported as one the setup goes past: $line" >&2
            exit 1
        fi
    done
    if [ "$(cat "$directory/certs/live/key.pem")" != "$key" ] ||
        [ "$(cat "$directory/certs/live/cert.pem")" != "$cert" ] ||
        [ -e "$directory/certs/saved" ]; then
        echo "FAIL: $name: a refused final reload left the wrong pair, or the saved copy, on disk" >&2
        exit 1
    fi
}

# Without a certificate step.
make_case "$fixture/reload-failure"
status=0
FAIL_ALL_RELOAD=yes run_case "$fixture/reload-failure" no || status=$?
reload_fatal_check reload-failure "$status" 'previous key' 'previous cert'
echo 'PASS: a refused final reload still stops a run whose certificate step did not run.'

# A certificate step that failed without touching the pair (the CA refused
# it, or ACME did not start), or whose rejected pair was put back.
for case in 'reload-refused-issue ACME_ISSUE=refused' 'reload-no-acme FAIL_ACME_START=yes' \
    'reload-restored ACME_INSTALL=partial' 'reload-restored-refused ACCEPT_INSTALLED=yes'; do
    read -r -a words <<< "$case"
    status=0
    acme_case "${words[@]}" FAIL_ALL_RELOAD=yes || status=$?
    reload_fatal_check "${words[0]}" "$status" 'previous key' 'previous cert'
done
if ! grep -Fxq cert-restore "$fixture/reload-restored/calls" ||
    ! grep -Fxq cert-restore "$fixture/reload-restored-refused/calls" ||
    grep -Fxq cert-save "$fixture/reload-refused-issue/calls" ||
    grep -Fxq acme-issue "$fixture/reload-no-acme/calls"; then
    echo 'FAIL: a fatal reload case did not run the certificate step it stands for' >&2
    exit 1
fi
echo 'PASS: a refused final reload still stops the run when the certificate step left Nginx its own pair.'

# An accepted certificate (its own reload worked), then the final reload
# alone fails: still fatal, and the issued pair stays in place.
status=0
acme_case reload-accepted ACCEPT_INSTALLED=yes FAIL_SECOND_RELOAD=yes || status=$?
reload_fatal_check reload-accepted "$status" 'issued key' 'issued cert'
if ! grep -Fxq reload-nginx "$fixture/reload-accepted/calls" ||
    ! grep -Fxq cert-discard "$fixture/reload-accepted/calls" ||
    grep -Fxq cert-restore "$fixture/reload-accepted/calls" ||
    grep -Fq 'ERROR: no letsencrypt certificate' "$fixture/reload-accepted/output.log"; then
    cat "$fixture/reload-accepted/calls" >&2
    echo 'FAIL: an accepted certificate was undone or reported as missing when the final reload failed' >&2
    exit 1
fi
echo 'PASS: a refused final reload after an accepted certificate still stops the run and keeps the issued pair.'

# ACME itself did not start, or its saved provider could not be read: the
# advice points at the error above, not at DNS or the certificate authority.
for setting in FAIL_ACME_START=yes FAIL_ACME_API=yes; do
    name=acme-${setting%%=*}
    name=${name,,}
    make_case "$fixture/$name"
    sed -i 's/^SSL_PROVIDER=selfsigned$/SSL_PROVIDER=letsencrypt/' "$fixture/$name/.env"
    echo 'EMAIL=ops@resume.example.com' >> "$fixture/$name/.env"
    if (export "${setting?}"; run_case "$fixture/$name" no); then
        echo "FAIL: $setting: the setup ended with status 0" >&2
        exit 1
    fi
    if grep -Fxq acme-issue "$fixture/$name/calls" ||
        ! grep -Fxq start-cron "$fixture/$name/calls" ||
        ! grep -Fq 'The ACME container could not be started or read (see the error above)' "$fixture/$name/output.log" ||
        grep -Fq 'Once resume.example.com points to this server' "$fixture/$name/output.log"; then
        tail -n 20 "$fixture/$name/output.log" >&2
        echo "FAIL: $setting: wrong advice, or the run did not finish" >&2
        exit 1
    fi
done
echo 'PASS: an ACME container that does not start or cannot be read gets its own advice.'

# Accepted certificate: it stays, the saved copy goes, the setup succeeds.
if ! acme_case acme-accepted ACCEPT_INSTALLED=yes; then
    tail -n 20 "$fixture/acme-accepted/output.log" >&2
    echo 'FAIL: an accepted certificate failed the setup' >&2
    exit 1
fi
if [ "$(cat "$fixture/acme-accepted/certs/live/cert.pem")" != 'issued cert' ] ||
    [ "$(cat "$fixture/acme-accepted/certs/live/key.pem")" != 'issued key' ] ||
    [ -e "$fixture/acme-accepted/certs/saved" ] ||
    ! grep -Fxq cert-discard "$fixture/acme-accepted/calls" ||
    grep -Fxq cert-restore "$fixture/acme-accepted/calls" ||
    grep -q '^unexpected:' "$fixture/acme-accepted/calls" ||
    grep -Fq 'ERROR:' "$fixture/acme-accepted/output.log"; then
    tail -n 20 "$fixture/acme-accepted/output.log" >&2
    cat "$fixture/acme-accepted/calls" >&2
    echo 'FAIL: an accepted certificate was undone, or its saved copy kept' >&2
    exit 1
fi
echo 'PASS: an accepted certificate stays installed and the saved pair is removed.'
