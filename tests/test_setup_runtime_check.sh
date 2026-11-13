#!/bin/bash
# shellcheck disable=SC2034,SC2329  # Variables and stubs are used by the extracted code of setup.sh.
# H5: setup.sh printed "KVS Docker Setup Complete!" once docker compose up -d
# returned, which it does as soon as the containers are started: a PHP-FPM
# that exits at once and restarts in a loop, or an Nginx failing its probe,
# still ended with "Complete" and the site URL. setup_verify_runtime_services
# now waits for every service the setup started to run without restarting,
# seen twice at least, and to be healthy where it has a healthcheck,
# Manticore excepted while it builds its indexes; the one-off containers of
# docker compose run do not count. Here Docker is a stand-in that reports
# the states of a scenario, one line per poll, and sleep moves the clock
# instead of waiting. tests/integration_setup_runtime_check.sh runs the same
# function against real containers.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETUP="$ROOT_DIR/docker/setup.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-setup-runtime.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

extract_function() {
    awk -v signature="$1() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$SETUP"
}

{
    grep -m1 '^SETUP_RUNTIME_WAIT_SECONDS=' "$SETUP" || true
    extract_function setup_verify_runtime_services
    extract_function setup_manticore_builds
} > "$TEST_DIR/functions.sh"
grep -q '^setup_verify_runtime_services() {' "$TEST_DIR/functions.sh" ||
    fail "setup.sh has no setup_verify_runtime_services"
grep -Fxq 'SETUP_RUNTIME_WAIT_SECONDS=300' "$TEST_DIR/functions.sh" ||
    fail "setup.sh must wait up to 300 s for the runtime services"
# shellcheck source=/dev/null
source "$TEST_DIR/functions.sh"

# The stand-in: $TEST_DIR/state/<service> holds one line per poll,
# "<status> <health> <restarts> <exit code>", the last one repeated; a file
# "none" gives no container, "fail" a failed inspect. A one-off container
# of the service, listed first, answers the one line of
# $TEST_DIR/oneoff/<service>. Docker answers the format of setup.sh only,
# with the oneoff label of Compose last, as it does. docker exec runs the
# command it is given, with the paths under $TEST_DIR/fs/<container>, the
# files of that container.
RUNTIME_FORMAT='{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}} {{.State.ExitCode}} {{index .Config.Labels "com.docker.compose.oneoff"}}'
database_docker_query() {
    local service polls line id path
    local -a paths=()

    case "$*" in
        'compose ps -a -q '*)
            [ "$#" -eq 5 ] || return 99
            service=$5
            [ ! -f "$TEST_DIR/oneoff/$service" ] || printf 'run-%s\n' "$service"
            [ "$(cat "$TEST_DIR/state/$service" 2>/dev/null)" != none ] || return 0
            printf 'id-%s\n' "$service"
            ;;
        'inspect --format '*)
            [ "$#" -eq 4 ] && [ "$3" = "$RUNTIME_FORMAT" ] || return 99
            case "$4" in
                run-*)
                    printf '%s True\n' "$(cat "$TEST_DIR/oneoff/${4#run-}")"
                    return 0
                    ;;
                id-*) service=${4#id-} ;;
                *) return 99 ;;
            esac
            [ "$(cat "$TEST_DIR/state/$service")" != fail ] || return 1
            polls=$(cat "$TEST_DIR/polls/$service" 2>/dev/null || echo 0)
            polls=$((polls + 1))
            echo "$polls" > "$TEST_DIR/polls/$service"
            line=$(sed -n "${polls}p" "$TEST_DIR/state/$service")
            [ -n "$line" ] || line=$(tail -n 1 "$TEST_DIR/state/$service")
            printf '%s False\n' "$line"
            ;;
        'exec '*)
            [ "$#" -ge 6 ] && [ "$3" = sh ] && [ "$4" = -c ] && [ "$6" = sh ] || return 99
            id=$2
            echo "$id" >> "$TEST_DIR/execs"
            for path in "${@:7}"; do
                [[ "$path" == /* ]] || return 99
                paths+=("$TEST_DIR/fs/$id$path")
            done
            sh -c "$5" sh "${paths[@]}"
            ;;
        *) return 99 ;;
    esac
}
sleep() {
    SECONDS=$((SECONDS + $1))
    echo "slept $1" >> "$TEST_DIR/sleeps"
    # A wait without an end stops here instead of hanging the suite.
    if [ "$(wc -l < "$TEST_DIR/sleeps")" -gt 1000 ]; then
        echo "the wait never ends" >&2
        exit 1
    fi
}

# scenario <service>=<states separated by ;>...: the services the setup
# started, cron last when it was started too.
scenario() {
    local pair service file

    rm -rf "$TEST_DIR/state" "$TEST_DIR/polls" "$TEST_DIR/sleeps" "$TEST_DIR/oneoff" "$TEST_DIR/fs" "$TEST_DIR/execs"
    mkdir -p "$TEST_DIR/state" "$TEST_DIR/polls" "$TEST_DIR/oneoff"
    SETUP_RUNTIME_SERVICES=()
    SETUP_CRON_PENDING=false
    for pair in "$@"; do
        service=${pair%%=*}
        case "$service" in
            # <service>+run=<state>: a one-off container of the service.
            *+run)
                printf '%s\n' "${pair#*=}" > "$TEST_DIR/oneoff/${service%+run}"
                continue
                ;;
            # <service>+files=<names>: files in /var/run/manticore of the
            # service container.
            *+files)
                mkdir -p "$TEST_DIR/fs/id-${service%+files}/var/run/manticore"
                for file in ${pair#*=}; do
                    : > "$TEST_DIR/fs/id-${service%+files}/var/run/manticore/$file"
                done
                continue
                ;;
        esac
        tr ';' '\n' <<< "${pair#*=}" > "$TEST_DIR/state/$service"
        if [ "$service" = cron ]; then
            SETUP_CRON_PENDING=true
        else
            SETUP_RUNTIME_SERVICES+=("$service")
        fi
    done
}

# up <description> <scenario...>: the check succeeds.
up() {
    local description="$1"
    shift
    scenario "$@"
    ( setup_verify_runtime_services ) > "$TEST_DIR/out" 2>&1 ||
        fail "$description: the services were taken for down: $(cat "$TEST_DIR/out")"
}

# down <description> <expected error> <scenario...>: the check fails, saying why.
down() {
    local description="$1" expected="$2"
    shift 2
    scenario "$@"
    if ( setup_verify_runtime_services ) > "$TEST_DIR/out" 2>&1; then
        fail "$description: the setup would call itself complete: $(cat "$TEST_DIR/out")"
    fi
    grep -Fxq "ERROR: $expected" "$TEST_DIR/out" ||
        fail "$description: the error must be '$expected': $(cat "$TEST_DIR/out")"
}

healthy='running healthy 0 0'
plain='running none 0 0'
up "every service up" nginx="$healthy" php-fpm="$healthy" dragonfly="$plain" cron="$healthy"
[ "$(cat "$TEST_DIR/sleeps")" = 'slept 2' ] ||
    fail "services already up must be looked at twice, 2 s apart: $(cat "$TEST_DIR/sleeps")"
for service in nginx php-fpm dragonfly cron; do
    [ "$(cat "$TEST_DIR/polls/$service")" = 2 ] || fail "$service was not looked at twice: $(cat "$TEST_DIR/polls/$service")"
done
up "a recreated Nginx turns healthy" nginx='running starting 0 0;running starting 0 0;running healthy 0 0' php-fpm="$healthy"
[ "$(wc -l < "$TEST_DIR/sleeps")" -eq 2 ] || fail "a starting service must be polled until it is healthy: $(cat "$TEST_DIR/sleeps")"
up "Manticore builds its indexes" nginx="$healthy" php-fpm="$healthy" manticore='running starting 0 0'
# A large import counts its rows for minutes after Manticore started: past
# its start period, its probe fails while the start builds every index on
# the request of setup_request_manticore_rebuild.
up "Manticore builds its indexes past its start period" nginx="$healthy" php-fpm="$healthy" \
    manticore='running starting 0 0;running unhealthy 0 0' manticore+files=kvs-requested-build
grep -Fxq id-manticore "$TEST_DIR/execs" || fail "the build must be asked of the Manticore container: $(cat "$TEST_DIR/execs")"
# The containers of docker compose run beside a service are not the service.
up "an exited one-off container beside PHP-FPM" nginx="$healthy" php-fpm="$healthy" php-fpm+run='exited none 0 137'
up "a running one-off container beside cron" nginx="$healthy" cron="$healthy" cron+run='running none 0 0'
up "cron not started is not checked" nginx="$healthy" php-fpm="$healthy"
up "a restart before the first look" nginx="$healthy" php-fpm='running healthy 3 0'

down "PHP-FPM restarting" 'the php-fpm container restarts (exit code 78, 1 restarts).' \
    nginx="$healthy" php-fpm='restarting starting 1 78'
down "PHP-FPM restarting between two looks" 'the php-fpm container restarts (exit code 78, 1 restarts).' \
    nginx='running starting 0 0' php-fpm='running starting 0 0;running starting 1 78'
down "PHP-FPM exited" 'the php-fpm container has stopped (exited, exit code 78).' \
    nginx="$healthy" php-fpm='exited none 0 78'
down "Nginx failing its probe" 'the nginx container is unhealthy: its healthcheck fails.' \
    nginx='running starting 0 0;running unhealthy 0 0' php-fpm="$healthy"
down "Manticore failing its probe" 'the manticore container is unhealthy: its healthcheck fails.' \
    nginx="$healthy" php-fpm="$healthy" manticore='running unhealthy 0 0'
down "Manticore after a failed build" 'the manticore container is unhealthy: its healthcheck fails.' \
    nginx="$healthy" manticore='running unhealthy 0 0' manticore+files=kvs-build-failed
down "Manticore building with a failed build recorded" 'the manticore container is unhealthy: its healthcheck fails.' \
    nginx="$healthy" manticore='running unhealthy 0 0' manticore+files='kvs-requested-build kvs-build-failed'
down "Manticore building with a failed rebuild recorded" 'the manticore container is unhealthy: its healthcheck fails.' \
    nginx="$healthy" manticore='running unhealthy 0 0' manticore+files='kvs-requested-build kvs-rebuild-failed'
down "Nginx failing its probe beside the files of a build" 'the nginx container is unhealthy: its healthcheck fails.' \
    nginx='running unhealthy 0 0' nginx+files=kvs-requested-build
down "Manticore restarting while it builds" 'the manticore container restarts (exit code 1, 1 restarts).' \
    nginx="$healthy" manticore='running unhealthy 0 0;running unhealthy 1 1' manticore+files=kvs-requested-build
down "Manticore exited" 'the manticore container has stopped (exited, exit code 1).' \
    nginx="$healthy" manticore='exited none 0 1'
# One look can catch a container between two restarts: running, starting
# for Manticore, or with no healthcheck to wait for.
down "Dragonfly running between two restarts" 'the dragonfly container restarts (exit code 1, 3 restarts).' \
    nginx="$healthy" dragonfly='running none 2 1;running none 3 1'
down "Manticore starting between two restarts" 'the manticore container restarts (exit code 1, 2 restarts).' \
    nginx="$healthy" manticore='running starting 1 1;running starting 2 1'
down "only a one-off container of the service" 'the php-fpm service has no container.' \
    nginx="$healthy" php-fpm=none php-fpm+run='running healthy 0 0'
down "cron exited" 'the cron container has stopped (exited, exit code 1).' \
    nginx="$healthy" php-fpm="$healthy" cron='exited none 0 1'
down "a service without a container" 'the dragonfly service has no container.' \
    nginx="$healthy" dragonfly=none
down "a state Docker cannot give" 'the state of the php-fpm container could not be read.' \
    nginx="$healthy" php-fpm=fail
down "a probe that never answers" 'still starting after 300 s: nginx.' \
    nginx='running starting 0 0' php-fpm="$healthy" manticore='running starting 0 0'
# 300 s in 2 s steps; the real seconds the test itself takes count too.
steps=$(wc -l < "$TEST_DIR/sleeps")
[ "$steps" -ge 140 ] && [ "$steps" -le 150 ] || fail "the wait must last 300 s in 2 s steps: $steps steps"
down "a container never started" 'still starting after 300 s: acme.' \
    nginx="$healthy" acme='created none 0 0'
echo 'PASS: the runtime services must be up, and healthy where they have a healthcheck'

# The end of setup.sh as written: the check runs once cron is started, and
# a service that is not up ends the run with exit 1 before "Complete".
start=$(grep -n '^progress_bar "Finalizing setup"$' "$SETUP" | cut -d: -f1)
end=$(grep -n '^    progress_success "KVS Docker Setup Complete!"$' "$SETUP" | cut -d: -f1)
[ -n "$start" ] && [ -n "$end" ] && [ "$start" -lt "$end" ] || fail "setup.sh has no final block"
sed -n "${start},$((end + 1))p" "$SETUP" > "$TEST_DIR/final.sh"
final() (
    RED='' GREEN='' YELLOW='' CYAN='' NC='' DEBUG_LOG=/dev/null SETUP_ACME_FAILED=false SSL_PROVIDER=letsencrypt
    progress_bar() { :; }
    progress_success() { echo "$1"; }
    import_finish() { echo import_finish; }
    setup_start_cron() { echo setup_start_cron; }
    # shellcheck source=/dev/null
    source "$TEST_DIR/final.sh"
    echo "the run went on"
)
scenario nginx="$healthy" php-fpm='restarting starting 1 78' cron="$healthy"
if final > "$TEST_DIR/out" 2>&1; then
    fail "setup.sh went on with PHP-FPM restarting: $(cat "$TEST_DIR/out")"
fi
if grep -Fq 'Complete' "$TEST_DIR/out" || grep -Fq 'the run went on' "$TEST_DIR/out"; then
    fail "setup.sh called itself complete with PHP-FPM restarting: $(cat "$TEST_DIR/out")"
fi
grep -Fxq 'ERROR: the setup did not complete: a service it started is not up.' "$TEST_DIR/out" ||
    fail "setup.sh must say it did not complete: $(cat "$TEST_DIR/out")"
grep -Fxq '    Check: docker compose ps -a' "$TEST_DIR/out" || fail "setup.sh must say where to look: $(cat "$TEST_DIR/out")"
[ "$(grep -n -e '^setup_start_cron$' -e '^ERROR: the php-fpm' "$TEST_DIR/out" | cut -d: -f2 | tr '\n' ' ')" = 'setup_start_cron ERROR ' ] ||
    fail "the check must come once cron is started: $(cat "$TEST_DIR/out")"
scenario nginx="$healthy" php-fpm="$healthy" cron="$healthy"
final > "$TEST_DIR/out" 2>&1 || fail "setup.sh stopped with every service up: $(cat "$TEST_DIR/out")"
grep -Fxq 'KVS Docker Setup Complete!' "$TEST_DIR/out" || fail "setup.sh must complete with every service up: $(cat "$TEST_DIR/out")"
echo 'PASS: setup.sh is complete only once the services it started are up'

# The services the check waits for are the ones the setup started.
extract_function setup_start_runtime_services > "$TEST_DIR/start.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/start.sh"
setup_resume_docker_query() { printf 'mariadb\nphpmyadmin-init\nkvs-init\nnginx\nphp-fpm\ncron\nmanticore\n'; }
log_command() { :; }
RESUME_IMPORT=false IMPORT_MODE=false SETUP_RUNTIME_SERVICES=()
setup_start_runtime_services
[ "${SETUP_RUNTIME_SERVICES[*]}" = 'nginx php-fpm manticore' ] && [ "$SETUP_CRON_PENDING" = true ] ||
    fail "the check must wait for the services the setup started: ${SETUP_RUNTIME_SERVICES[*]} (cron: $SETUP_CRON_PENDING)"
echo 'PASS: the check covers the services the setup started'
