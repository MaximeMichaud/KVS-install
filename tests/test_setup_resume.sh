#!/bin/bash
# Exercise recovery orchestration without a client server or host changes.
# shellcheck disable=SC2034,SC2317,SC2329
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
names = ('validate_domain', 'check_mariadb_stop_grace_period', 'check_cloudflare_configuration', 'parse_publish_endpoint',
         'resolve_public_port_configuration', 'setup_resume_import',
         'setup_resume_assert_database', 'setup_start_runtime_services', 'setup_start_cron', 'import_count_rows',
         'setup_resume_docker_query', 'setup_resume_database_snapshot', 'import_finish', 'remove_env_value', 'set_env_value')
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
        'compose version')
            [ -n "${COMPOSE_VERSION-2.32.2}" ] || return 1
            printf 'Docker Compose version v%s\n' "${COMPOSE_VERSION-2.32.2}"
            ;;
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
# exits before contacting the daemon or creating any container. Without
# Compose the check is skipped and says so, except under CI, where that is a
# failure.
if [ -n "$docker_cli" ] && "$docker_cli" compose version >/dev/null 2>&1; then
    "$docker_cli" compose --profile setup run --rm --no-deps "${SETUP_RUN_FLAGS[@]}" --help >/dev/null
elif [ "${CI:-}" = true ]; then
    echo 'FAIL: Docker Compose is required to parse the recovery flags'; exit 1
else
    echo 'SKIP: the recovery flags were not parsed, Docker Compose is not installed'
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
# The initializers run with "docker compose run --pull", which Compose has
# from 2.32.2 on: an older one, or none, stops recovery before it inspects
# or waits for anything.
for old_compose in 2.32.1 2.24.4 ''; do
    : > "$CALLS"
    : > "$METADATA_CALLS"
    if COMPOSE_VERSION=$old_compose setup_resume_import > "$fixture/compose-failure.log" 2>&1; then
        echo "FAIL: recovery must refuse Docker Compose '${old_compose}'"; exit 1
    fi
    grep -Fq "ERROR: --resume-import needs Docker Compose 2.32.2 or newer, the first whose docker compose run takes --pull; found ${old_compose:-none}." "$fixture/compose-failure.log" || {
        echo "FAIL: the refusal must name the Compose found: $(cat "$fixture/compose-failure.log")"; exit 1
    }
    if [ -s "$METADATA_CALLS" ] || [ -s "$CALLS" ] || grep -q '^Inspecting' "$fixture/compose-failure.log"; then
        echo "FAIL: an old Compose must stop recovery before anything is inspected: $(cat "$CALLS" "$METADATA_CALLS")"; exit 1
    fi
done
: > "$CALLS"
COMPOSE_VERSION=5.6.0 setup_resume_import > "$fixture/compose-current.log" 2>&1 || {
    echo "FAIL: Compose 5.6.0 must resume: $(cat "$fixture/compose-current.log")"; exit 1
}
[ "$(cat "$CALLS")" = "$expected" ] || { echo "FAIL: Compose 5.6.0 must resume: $(cat "$CALLS")"; exit 1; }
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

# Completion checks the assignment actually persisted by the real writer,
# not receipt-looking lines inside other values. Read errors stop cleanup.
for receipt_case in new exported multiline combined noop_fake wrong_fake write_failure read_failure token_failure; do
    directory="$fixture/receipt-$receipt_case"
    mkdir -p "$directory/logs" "$directory/native" "$directory/staging"
    printf 'DOMAIN=example.test\nEXTRA=preserved\n' > "$directory/.env"
    # shellcheck disable=SC2016  # Evaluated once by the fixture's initial source.
    printf '%s\n' 'READ_PROBE=$(printf "evaluated\n" >> parse-count)' >> "$directory/.env"
    case "$receipt_case" in
        exported|combined|token_failure) echo 'export KVS_IMPORT_COMPLETED=2026-10-01T10:00:00Z' >> "$directory/.env" ;;
    esac
    case "$receipt_case" in
        multiline|combined|noop_fake|wrong_fake)
            printf 'KEEP="first\nKVS_IMPORT_COMPLETED=2030-01-02T03:04:05Z\nlast"\n' >> "$directory/.env" ;;
    esac
    chmod 600 "$directory/.env"
    cp "$directory/.env" "$directory/before.env"
    for artifact in token dump raw native/payload staging/kvs-export.manifest; do
        echo 'owned placeholder' > "$directory/$artifact"
    done
    status=0
    (
        cd "$directory"
        # Restore the real writer after the earlier row-count failure stub.
        # shellcheck source=/dev/null
        source "$fixture/setup-functions.sh"
        unset KVS_IMPORT_COMPLETED
        # shellcheck source=/dev/null
        source .env
        IMPORT_MODE=true LOG_DIR="$directory/logs" IMPORT_SITE_DIR=/synthetic-site IMPORT_DB_DUMP=dump
        IMPORT_TABLES_PREFIX=fixture_ IMPORT_STAGED_DUMP=dump IMPORT_RAW_DUMP=raw
        IMPORT_NATIVE_STAGE=native IMPORT_STAGING=staging
        readback_fault_active=no
        date() { printf '2030-01-02T03:04:05Z\n'; }
        import_count_rows() { printf 'fixture_options\t2\n'; }
        run_root_mariadb() {
            case "$*" in
                *'SELECT table_name'*) echo fixture_options ;;
                *'DELETE FROM fixture_options'*)
                    echo delete-token >> calls
                    [ "$receipt_case" != token_failure ] || return 71
                    rm token ;;
                *) echo unexpected >> calls; return 97 ;;
            esac
        }
        mktemp() {
            [ "$receipt_case" != write_failure ] || return 73
            command mktemp "$@"
        }
        mv() {
            command mv "$@" || return
            if [ "${!#}" = .env ]; then readback_fault_active=yes; fi
        }
        # Fault both the old and new readback command after the real final
        # rename, leaving the successful write available to a fresh oracle.
        grep() {
            if [ "$receipt_case" = read_failure ] && [ "$readback_fault_active" = yes ] && [ "${!#}" = .env ]; then return 74; fi
            command grep "$@"
        }
        tail() {
            if [ "$receipt_case" = read_failure ] && [ "$readback_fault_active" = yes ] && [ "${!#}" = .env ]; then return 74; fi
            command tail "$@"
        }
        case "$receipt_case" in
            noop_fake) set_env_value() { :; } ;;
            wrong_fake) set_env_value() { echo 'KVS_IMPORT_COMPLETED=2000-01-01T00:00:00Z' >> .env; } ;;
        esac
        import_finish
    ) > "$directory/output" 2>&1 || status=$?
    [ "$(cat "$directory/parse-count")" = evaluated ] || { echo 'FAIL: completion evaluated .env again'; exit 1; }
    case "$receipt_case" in
        new|exported|multiline|combined)
            [ "$status" -eq 0 ] || { echo "FAIL: completion rejected $receipt_case: $(cat "$directory/output")"; exit 1; }
            for artifact in token dump raw native staging/kvs-export.manifest; do
                [ ! -e "$directory/$artifact" ] || { echo "FAIL: completion retained $artifact"; exit 1; }
            done
            grep -Fxq delete-token "$directory/calls" ;;
        *)
            [ "$status" -ne 0 ] || { echo "FAIL: completion accepted $receipt_case"; exit 1; }
            for artifact in token dump raw native/payload staging/kvs-export.manifest; do
                [ -f "$directory/$artifact" ] || { echo "FAIL: $receipt_case removed $artifact"; exit 1; }
            done
            if [ "$receipt_case" != token_failure ] && [ -e "$directory/calls" ]; then
                echo 'FAIL: failed receipt validation reached token deletion'; exit 1
            fi ;;
    esac
    case "$receipt_case" in
        noop_fake|write_failure) cmp -s "$directory/.env" "$directory/before.env" ;;
    esac
    # shellcheck disable=SC2016  # A fresh child reads the persisted state.
    actual=$(cd "$directory" && env -u KVS_IMPORT_COMPLETED bash -c 'source .env; printf "%s" "${KVS_IMPORT_COMPLETED-}"')
    expected=2030-01-02T03:04:05Z
    case "$receipt_case" in
        noop_fake|write_failure) expected='' ;;
        wrong_fake) expected=2000-01-01T00:00:00Z ;;
    esac
    [ "$actual" = "$expected" ] || { echo 'FAIL: persisted receipt differs from the write result'; exit 1; }
    case "$receipt_case" in
        multiline|combined|noop_fake|wrong_fake)
            # shellcheck disable=SC2016  # The child reads the unrelated value.
            actual=$(cd "$directory" && env -u KEEP bash -c 'source .env; printf "%s" "$KEEP"')
            [ "$actual" = $'first\nKVS_IMPORT_COMPLETED=2030-01-02T03:04:05Z\nlast' ] || { echo 'FAIL: receipt validation changed a multiline value'; exit 1; } ;;
    esac
    grep -Fxq 'EXTRA=preserved' "$directory/.env"
    [ "$(stat -c %a "$directory/.env")" = 600 ]
done
echo 'PASS: completion verifies persisted receipts, preserves multiline values and stops cleanup on write or read failure.'
