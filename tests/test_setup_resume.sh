#!/bin/bash
# Exercise recovery orchestration without a client server or host changes.
# shellcheck disable=SC2034,SC2317
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
docker_cli=$(command -v docker || true)
fixture=$(mktemp -d /tmp/kvs-resume-setup.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/lib"
python3 - "$root/docker/setup.sh" "$fixture/setup-functions.sh" <<'PY'
import re
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
names = ('validate_domain', 'check_mariadb_stop_grace_period', 'parse_publish_endpoint',
         'resolve_public_port_configuration', 'setup_resume_import',
         'setup_resume_assert_database', 'setup_start_runtime_services', 'setup_start_cron', 'import_count_rows',
         'setup_resume_docker_query', 'setup_resume_database_snapshot', 'import_finish')
with open(sys.argv[2], 'w') as target:
    for name in names:
        match = re.search(r'^' + name + r'\(\) [\{(]\n.*?^[\})]\n', source, re.M | re.S)
        assert match, name
        target.write(match.group() + '\n')
assert source.index('if [ "$RESUME_IMPORT" != true ]; then') < source.index('export VOLUME_CHOICE=1')
assert source.index('else\n    setup_resume_import\n') > source.index('import_verify_database\n')
assert source.rindex('\nimport_finish\n') > source.index('run_step "Reloading Nginx"')
assert 'DELETE FROM' not in re.search(r'^import_verify_database\(\) \{\n.*?^\}', source, re.M | re.S).group()
PY
# shellcheck source=/dev/null
source "$fixture/setup-functions.sh"
# shellcheck source=/dev/null
source "$root/docker/lib/database.sh"
RESUME_IMPORT=true
cat > "$fixture/lib/import-resume.sh" <<'SH'
import_resume_discover() {
    printf 'discover\n' >> "$CALLS"
    IMPORT_STAGED_DUMP=mariadb/init/10-kvs-import.sql
    IMPORT_DB_DUMP=$IMPORT_STAGED_DUMP
}
import_resume_marker() {
    printf 'marker\n' >> "$CALLS"
    [ "${FAIL_MARKER:-no}" != yes ] || return 1
    printf '20260926T211043Z-1234abcd\n'
}
import_resume_token() {
    printf 'token\n' >> "$CALLS"
    printf '20260926T211043Z-1234abcd\n'
}
import_resume_verify() {
    printf 'verify\n' >> "$CALLS"
}
SH
cat > "$fixture/.env" <<'ENV'
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
cp "$fixture/.env" "$fixture/.env.example"
touch "$fixture/docker-compose.yml"
CALLS="$fixture/calls"
METADATA_CALLS="$fixture/metadata-calls"
export CALLS METADATA_CALLS
RED='' GREEN='' NC=''
log_command() { "$@"; }
import_validate_site() {
    [ "$1" = /var/www/resume.example.com ] || return 1
    printf '7.0.2\t/old/site\tktvs_\tno\n'
}
import_field() { printf '%s\n' "$1" | cut -f "$2"; }
database_wait_ready() {
    printf 'wait:%s\n' "$1" >> "$CALLS"
    [ "${FAIL_WAIT:-no}" != yes ]
}
timeout() {
    [ "$1" = -k ] && [ "$2" = 1 ] && [ "$3" = 30 ] || return 97
    shift 3
    printf '%s\n' "$*" >> "$METADATA_CALLS"
    [ "${FAIL_METADATA:-no}" != yes ] || return 124
    "$@"
}
docker() {
    case "$*" in
        'compose ps -a -q mariadb') printf '%s\n' "${CONTAINER_ID:-0123456789abcdef}" ;;
        'compose config --services') printf 'mariadb\nphp-fpm\nnginx\ncron\nmemcached\ncustom-worker\nkvs-init\nphpmyadmin-init\n' ;;
        'inspect --format {{index .Config.Labels '*)
            printf 'kvs-resume\trunning 0 false\tvolume:kvs-resume_mariadb-data:/fixture/volume\t%s\n' \
                "${STARTED_AT:-2026-09-26T21:10:43Z}" ;;
        'compose stop cron'|'compose up '*) printf 'runtime:%s\n' "$*" >> "$CALLS" ;;
        *) printf 'Unexpected Docker mutation: %s\n' "$*" >&2; return 1 ;;
    esac
}
cd "$fixture"
: > "$CALLS"
: > "$METADATA_CALLS"
DOMAIN=wrong.example.com MARIADB_VERSION=99 COMPOSE_FILE=/wrong.yml VOLUME_CHOICE=1 \
    setup_resume_import > "$fixture/startup.log" 2>&1
[ "$DOMAIN" = resume.example.com ]
[ "$MARIADB_VERSION" = 12.3 ]
[ -z "${COMPOSE_FILE:-}" ]
[ "$IMPORT_SOURCE" = resume ]
[ "$IMPORT_SITE_DIR" = /var/www/resume.example.com ]
[ "$IMPORT_RAW_DUMP" = '' ]
[ "${SETUP_RUN_FLAGS[*]}" = '--pull missing' ]
# Parse the actual recovery flags with Compose when it is installed. Help
# exits before contacting the daemon or creating any container.
if [ -n "$docker_cli" ] && "$docker_cli" compose version >/dev/null 2>&1; then
    "$docker_cli" compose --profile setup run --rm --no-deps "${SETUP_RUN_FLAGS[@]}" --help >/dev/null
fi
expected=$'discover\nwait:0\nmarker\ntoken\nverify'
[ "$(cat "$CALLS")" = "$expected" ]
[ "$(grep -c '^docker compose ps ' "$METADATA_CALLS")" = 3 ]
[ "$(grep -c '^docker inspect ' "$METADATA_CALLS")" = 3 ]
grep -Fxq 'Inspecting the saved import configuration and existing MariaDB container...' "$fixture/startup.log"
setup_start_runtime_services
grep -Fxq 'runtime:compose up -d --no-deps --no-recreate --no-build --pull missing php-fpm nginx memcached custom-worker' "$CALLS"
if STARTED_AT=changed setup_resume_assert_database 2>/dev/null; then
    echo 'FAIL: a manual MariaDB restart must invalidate recovery'; exit 1
fi
if CONTAINER_ID=abcdef0123456789 setup_resume_assert_database 2>/dev/null; then
    echo 'FAIL: a replacement MariaDB container must invalidate recovery'; exit 1
fi
: > "$CALLS"
if FAIL_METADATA=yes setup_resume_import > "$fixture/metadata-failure.log" 2>&1; then
    echo 'FAIL: a Docker metadata timeout must stop recovery'; exit 1
fi
grep -q '^Inspecting the saved import configuration' "$fixture/metadata-failure.log"
grep -q '^Locating the existing MariaDB container' "$fixture/metadata-failure.log"
grep -q 'Docker metadata check failed or exceeded its time limit' "$fixture/metadata-failure.log"
[ ! -s "$CALLS" ]
: > "$CALLS"
if FAIL_WAIT=yes setup_resume_import >/dev/null; then
    echo 'FAIL: a readiness failure must stop recovery'; exit 1
fi
if grep -q token "$CALLS"; then
    echo 'FAIL: an unfinished import must not trigger a dump scan'; exit 1
fi
: > "$CALLS"
if FAIL_MARKER=yes setup_resume_import >/dev/null; then
    echo 'FAIL: an absent database marker must stop recovery'; exit 1
fi
if grep -q token "$CALLS"; then
    echo 'FAIL: a missing marker must not trigger a dump scan'; exit 1
fi
: > "$CALLS"
MARIADB_WAIT_SECONDS=42 setup_resume_import >/dev/null
grep -Fxq wait:42 "$CALLS"
unset MARIADB_WAIT_SECONDS
# Compose would reject a saved stop grace period without its unit in every
# command: recovery stops on it before any Docker call.
: > "$CALLS"
: > "$METADATA_CALLS"
cp .env saved.env
printf 'MARIADB_STOP_GRACE_PERIOD=600\n' >> .env
if setup_resume_import > "$fixture/grace-failure.log" 2>&1; then
    echo 'FAIL: a saved stop grace period without its unit must stop recovery'; exit 1
fi
grep -Fq "MARIADB_STOP_GRACE_PERIOD must be a duration with its unit, such as 600s or 15m, got '600'" "$fixture/grace-failure.log"
[ ! -s "$METADATA_CALLS" ] && [ ! -s "$CALLS" ]
mv saved.env .env
unset MARIADB_STOP_GRACE_PERIOD

# A row-count failure must not remove the marker, staged dump, or write a
# completion receipt, even though the old pipeline's tr would have succeeded.
mkdir -p mariadb/init logs
touch mariadb/init/10-kvs-import.sql
LOG_DIR="$fixture/logs"
run_root_mariadb() {
    if [[ "$*" == *'SELECT table_name'* ]]; then
        printf 'ktvs_options\n'
    elif [[ "$*" == *'COUNT(*)'* ]]; then
        return 9
    else
        printf 'unexpected-write\n' >> "$CALLS"
    fi
}
set_env_value() { printf 'unexpected-save\n' >> "$CALLS"; }
: > "$CALLS"
if (import_finish) >/dev/null 2>&1; then
    echo 'FAIL: a failed row count must stop completion'; exit 1
fi
[ -f mariadb/init/10-kvs-import.sql ]
[ ! -s "$CALLS" ]

if bash "$root/docker/setup.sh" --resume-import --dev > "$fixture/conflict.log" 2>&1; then
    echo 'FAIL: recovery must reject destructive development mode'; exit 1
fi
grep -q 'cannot be combined' "$fixture/conflict.log"
echo 'PASS: import recovery preserves saved configuration, container identity, staging and completion proof.'
