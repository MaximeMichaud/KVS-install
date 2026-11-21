#!/bin/bash
# Persistent resource selection through the real env writer and Compose parser.
# No daemon, network, database, or system configuration is changed by this test.
# shellcheck disable=SC2034,SC1090,SC2016
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/kvs-db-resources.XXXXXX)
trap 'rm -rf "$work"' EXIT
real_docker=$(type -P docker)
# shellcheck source=/dev/null
source "$root/docker/lib/database.sh"
source <(sed -n '/^remove_env_value() {/,/^}/p; /^set_env_value() {/,/^}/p' "$root/docker/setup.sh")
cd "$work"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
database_available_memory_mb() { echo "${AVAILABLE_MB:-24576}"; }
database_capacity_memory_mb() { echo "${CAPACITY_MB:-32768}"; }
docker() {
    [ "$1" = compose ] || return 97
    shift
    "$real_docker" compose --env-file "$work/.env" \
        -f "$root/docker/docker-compose.yml" "${compose_extra[@]}" "$@"
}
reset_case() {
    unset MARIADB_BUFFER_POOL_SIZE MARIADB_BUFFER_POOL_SIZE_REQUEST
    unset MARIADB_REDO_LOG_SIZE MARIADB_REDO_LOG_SIZE_REQUEST
    unset AVAILABLE_MB CAPACITY_MB
    compose_extra=()
    cat > .env <<'ENV'
DOMAIN=resources.example.com
SITE_PREFIX=kvs-resources
MARIADB_ROOT_PASSWORD=fixture-root-only
MARIADB_PASSWORD=fixture-user-only
ENV
    chmod 600 .env
}
read_saved() {
    bash -eu -c 'source "$1"; printf "%s %s\n" "$MARIADB_BUFFER_POOL_SIZE" "$MARIADB_REDO_LOG_SIZE"' sh "$work/.env"
}
assert_unchanged_failure() {
    cp .env before.env
    if database_configure_resources > failure.log 2>&1; then fail "$1 accepted"; fi
    cmp .env before.env || fail "$1 changed persisted settings"
}

for pair in '256 128M' '512 256M' '1024 512M' '8192 4096M' '24576 12288M' '65536 32768M'; do
    read -r budget expected <<< "$pair"
    [ "$(database_buffer_pool_for_host "$budget")" = "$expected" ] || fail "pool budget $budget"
done
for budget in 0 1 128 255 invalid; do
    if database_buffer_pool_for_host "$budget" >/dev/null 2>&1; then fail "insufficient budget $budget accepted"; fi
done
for pair in '128 128M' '256 128M' '1024 512M' '4096 2048M' '12288 2048M'; do
    read -r pool expected <<< "$pair"
    [ "$(database_redo_for_pool "$pool")" = "$expected" ] || fail "redo for $pool pool"
done

reset_case
database_configure_resources > sizing.log
[ "$(read_saved)" = '12288M 2048M' ] || fail '24 GiB automatic sizes not persisted'
[ "$(stat -c '%a' .env)" = 600 ] || fail 'env file permissions changed'
docker compose config --format json > rendered.json
jq -e '.services.mariadb.command == ["--innodb-buffer-pool-size=12288M", "--innodb-log-file-size=2048M", "--max-allowed-packet=1G"]' rendered.json >/dev/null || fail 'persisted settings missing from rendered startup'
# Read from the saved file in a new process without the exported values.
env -u MARIADB_BUFFER_POOL_SIZE -u MARIADB_REDO_LOG_SIZE "$real_docker" compose \
    --env-file "$work/.env" -f "$root/docker/docker-compose.yml" config --format json > fresh.json
jq -e '.services.mariadb.command == ["--innodb-buffer-pool-size=12288M", "--innodb-log-file-size=2048M", "--max-allowed-packet=1G"]' fresh.json >/dev/null || fail 'new process lost saved startup settings'
AVAILABLE_MB=1024
database_configure_resources >/dev/null
[ "$(read_saved)" = '12288M 2048M' ] || fail 'rerun resized a saved pool based on remaining free RAM'
echo 'PASS: automatic sizing persisted, reloaded and rendered for startup'

reset_case
MARIADB_BUFFER_POOL_SIZE=4G
database_configure_resources >/dev/null
[ "$(read_saved)" = '4G 2048M' ] || fail 'legacy pool was guessed to be automatic'
MARIADB_BUFFER_POOL_SIZE_REQUEST=auto
AVAILABLE_MB=18432
database_configure_resources >/dev/null
[ "$(read_saved)" = '9216M 2048M' ] || fail 'explicit auto did not recalculate pool'
MARIADB_BUFFER_POOL_SIZE_REQUEST=2G
MARIADB_REDO_LOG_SIZE_REQUEST=512M
database_configure_resources >/dev/null
[ "$(read_saved)" = '2G 512M' ] || fail 'explicit sizes lost precedence'
MARIADB_BUFFER_POOL_SIZE_REQUEST=64M
database_configure_resources >/dev/null
[ "$(read_saved)" = '64M 512M' ] || fail 'explicit small pool was replaced by automatic minimum'
echo 'PASS: saved sizes, explicit overrides and explicit recalculation'

reset_case
cat > limits.yml <<'YAML'
services:
  mariadb:
    mem_limit: 1g
YAML
compose_extra=(-f "$work/limits.yml")
database_configure_resources >/dev/null
[ "$(read_saved)" = '512M 256M' ] || fail 'Compose cap not reflected in both defaults'
unset MARIADB_BUFFER_POOL_SIZE MARIADB_REDO_LOG_SIZE
AVAILABLE_MB=512
CAPACITY_MB=512
database_configure_resources >/dev/null
[ "$(read_saved)" = '256M 128M' ] || fail 'smaller cgroup budget ignored'
MARIADB_BUFFER_POOL_SIZE_REQUEST=512M
assert_unchanged_failure 'explicit pool without container headroom'
echo 'PASS: Compose and cgroup budgets, including explicit-size rejection'

reset_case
AVAILABLE_MB=0
assert_unchanged_failure 'zero available RAM'
unset AVAILABLE_MB
MARIADB_BUFFER_POOL_SIZE_REQUEST=12G
for value in 0G 513G 2M 08G 999999999999999999999G '2G;echo unexpected'; do
    MARIADB_REDO_LOG_SIZE_REQUEST=$value
    assert_unchanged_failure "invalid redo $value"
done
MARIADB_REDO_LOG_SIZE_REQUEST=2G
MARIADB_BUFFER_POOL_SIZE_REQUEST=999999999999999999999G
assert_unchanged_failure 'oversized numeric pool'
echo 'PASS: invalid sizing cannot partially rewrite env settings'

reset_case
# MariaDB aborts at startup with a buffer pool under 6 MiB ("innodb_page_size=
# 16384 requires innodb_buffer_pool_size >= 6 MiB"), and every rerun would
# reuse the saved size: 5M is refused before .env changes, 6M is saved.
MARIADB_BUFFER_POOL_SIZE_REQUEST=5M
assert_unchanged_failure '5M pool (below the 6 MiB MariaDB minimum)'
grep -Fq 'at least 6M' failure.log ||
    fail "the refusal of a 5M pool does not name the minimum: $(cat failure.log)"
MARIADB_BUFFER_POOL_SIZE_REQUEST=6M
database_configure_resources > minimum.log 2>&1 ||
    fail "the smallest pool MariaDB starts with was refused: $(cat minimum.log)"
[ "$(read_saved)" = '6M 128M' ] || fail "a 6M pool was saved as $(read_saved)"
echo 'PASS: the smallest buffer pool accepted is the smallest MariaDB starts with'

reset_case
cat > command.yml <<'YAML'
services:
  mariadb:
    command: ["mariadbd"]
YAML
compose_extra=(-f "$work/command.yml")
assert_unchanged_failure 'command override removing resource flags'
for alias in loose-innodb-buffer-pool-size maximum-innodb-buffer-pool-size loose-innodb-log-file-size; do
    cat > command.yml <<'YAML'
services:
  mariadb:
    command:
      - --innodb-buffer-pool-size=${MARIADB_BUFFER_POOL_SIZE}
      - --innodb-log-file-size=${MARIADB_REDO_LOG_SIZE}
YAML
    printf '      - --%s=24G\n' "$alias" >> command.yml
    assert_unchanged_failure "late $alias override"
done
echo 'PASS: effective command override detected before persistence'

# Compose before 2.22.0 writes the items of a list at the level of its key
# ("    - item") and 2.22.0 and newer indent them under it, as 2.21.0 and
# 2.22.0 render the MariaDB service. The check reads both layouts, and the
# command ends at the next key of the service: an item of a later list is
# not one of its arguments.
render_mariadb() {
    local item="$1"
    printf 'name: kvs-resources\nservices:\n  mariadb:\n    command:\n'
    printf '%s- --innodb-buffer-pool-size=%s\n' "$item" "${MARIADB_BUFFER_POOL_SIZE:-128M}"
    printf '%s- --innodb-log-file-size=%s\n' "$item" "${MARIADB_REDO_LOG_SIZE:-128M}"
    printf '%s- --max-allowed-packet=1G\n' "$item"
    printf '%s' "${command_extra:-}"
    printf '    container_name: kvs-resources-mariadb\n    entrypoint:\n'
    printf '%s- --innodb-buffer-pool-size=24G\n' "$item"
    printf '    image: mariadb:12.3\n'
}
for item in '    ' '      '; do
    layout='the layout of Compose 2.22.0 and newer'
    [ "$item" != '    ' ] || layout='the layout of Compose before 2.22.0'
    (
        # shellcheck disable=SC2329  # Called by the functions under test.
        docker() { [ "$*" = 'compose config' ] || return 97; render_mariadb "$item"; }
        reset_case
        command_extra=''
        database_configure_resources > layout.log 2>&1 ||
            fail "$layout: the MariaDB command was not recognized: $(cat layout.log)"
        [ "$(read_saved)" = '12288M 2048M' ] || fail "$layout: sizes not persisted: $(read_saved)"
        reset_case
        command_extra="${item}- --loose-innodb-buffer-pool-size=24G"$'\n'
        assert_unchanged_failure "$layout: a late loose buffer pool argument"
    )
done
echo 'PASS: the MariaDB command check reads the list layout of every Compose release'

reset_case
MARIADB_BUFFER_POOL_SIZE=512M
MARIADB_REDO_LOG_SIZE=128M
database_root_query() { printf '536870912\t%s\n' "${ACTUAL_REDO:-134217728}"; }
database_verify_running_resources >/dev/null
ACTUAL_REDO=100663296
if database_verify_running_resources >/dev/null 2>&1; then fail 'running default redo accepted'; fi
echo 'PASS: SQL readback rejects a server ignoring saved settings'

reset_case
printf 'MARIADB_BUFFER_POOL_SIZE=1G\nMARIADB_REDO_LOG_SIZE=512M\n' >> .env
"$real_docker" compose --env-file "$work/.env" \
    -f "$root/docker/multi-site/docker-compose.site.yml.template" config --format json > secondary.json
jq -e '.services.mariadb.command == ["--innodb-buffer-pool-size=1G", "--innodb-log-file-size=512M", "--max-allowed-packet=1G"]' secondary.json >/dev/null || fail 'secondary template ignores persistent sizes'
echo 'PASS: secondary template honors its own explicit resource budget'

# Docker kills a container 10 s after SIGTERM unless told otherwise, which
# can cut MariaDB short while it flushes its changed pages.
reset_case
grep -Fqx 'MARIADB_STOP_GRACE_PERIOD=10m' "$root/docker/.env.example" ||
    fail '.env.example does not carry the MariaDB stop grace period'
for grace in '' 15m; do
    [ -z "$grace" ] || printf 'MARIADB_STOP_GRACE_PERIOD=%s\n' "$grace" >> .env
    for compose_file in "$root/docker/docker-compose.yml" "$root/docker/multi-site/docker-compose.site.yml.template"; do
        "$real_docker" compose --env-file "$work/.env" -f "$compose_file" config --format json > grace.json
        jq -e --arg expected "${grace:-10m}0s" '.services.mariadb.stop_grace_period == $expected' grace.json >/dev/null ||
            fail "$compose_file: MariaDB stop grace period is not ${grace:-the 10m default}"
        # The entrypoint that loads the dump of an import is a bash PID 1
        # with no SIGTERM handler: without an init, a stop during that load
        # waited out the whole grace period.
        jq -e '.services.mariadb.init == true' grace.json >/dev/null ||
            fail "$compose_file: MariaDB does not run under an init that forwards SIGTERM"
    done
done
echo 'PASS: MariaDB gets a 10 minute stop grace period in both Compose files, and .env can change it'

# Exercise the setup and import call sites in script order. The requested
# socket can become occupied during shutdown, even if preflight saw it free.
sed -n '/^parse_publish_endpoint() {/,/^}/p; /^publish_endpoint_is_listening() {/,/^}/p;
    /^publish_address_key() {/,/^}/p; /^public_port_conflicts_exist() {/,/^}/p; /^port_conflicts_to_resolve() {/,/^}/p;
    /^check_configured_ports() {/,/^}/p; /^stop_for_configured_ports() {/,/^}/p;
    /^delete_database_volume() {/,/^}/p; /^replace_setup_database_volume() {/,/^}/p;
    /^import_replace_database_volume() {/,/^}/p' "$root/docker/setup.sh" > volume-functions
sed -n '/^check_configured_ports || exit 1$/p; /^stop_for_configured_ports || exit 1$/p;
    /^replace_setup_database_volume || exit 1$/p; /^import_replace_database_volume$/p' "$root/docker/setup.sh" > volume-steps
cat > volume-case <<'SH'
set -eu
source ./volume-functions
RED= GREEN= YELLOW= NC= MODE=single COMPOSE_PROJECT_NAME=kvs-test STOP_EXISTING=y
PUBLIC_HTTPS_ENDPOINT=127.0.0.1:$port PUBLIC_HTTP_ENDPOINT=127.0.0.1:$free_port
if [ "$scenario" = ipv6 ]; then PUBLIC_HTTPS_ENDPOINT="[0:0:0:0:0:0:0:1]:$port"; fi
MARIADB_HOST_PORT=$free_port CACHE_HOST_PORT=$free_port
ss() {
    if [ "$3" = "sport = :${PUBLIC_HTTPS_ENDPOINT##*:}" ]; then
        case $scenario in
            preflight) return 1 ;;
            owner-check) [ ! -e mappings-read ] || return 1 ;;
            ss-fails) [ ! -s events ] || return 1 ;;
            ss-missing)
                if [ -s events ]; then PATH=/nonexistent command ss "$@"; return $?; fi ;;
        esac
    fi
    command ss "$@"
}
SETUP_VOLUME_TO_DELETE= IMPORT_VOLUME_TO_DELETE=
if [ "$IMPORT_MODE" = true ]; then IMPORT_VOLUME_TO_DELETE=fixture; else SETUP_VOLUME_TO_DELETE=fixture; fi
remove_env_value() { [ "$1" = KVS_IMPORT_COMPLETED ]; }
docker() {
    case "$*" in
        'ps --filter label=com.docker.compose.project=kvs-test --format {{.Names}}') echo kvs-old ;;
        'ps --filter label=com.docker.compose.project=kvs-test --format table '*|'ps -q --filter label=com.docker.compose.project=kvs-test') ;;
        'port kvs-old') touch mappings-read; echo "443/tcp -> 127.0.0.1:$port" ;;
        'compose down --timeout 10')
            echo down >> events
            case $scenario in
                fail) return 1 ;;
                late|ipv6|owned)
                    python3 -c 'import socket, sys
s = socket.socket(fileno=int(sys.argv[1]))
if sys.argv[2] in ("late", "ipv6"):
    s.listen()
else:
    s.shutdown(socket.SHUT_RDWR)' "$socket_fd" "$scenario" ;;
            esac ;;
        'volume inspect fixture') [ -f volume ] ;;
        'volume rm fixture') echo rm >> events; rm volume ;;
        *) echo "Unexpected Docker call: $*" >&2; return 64 ;;
    esac
}
source ./volume-steps
SH
python3 - <<'PY'
import os
import socket
import subprocess
from pathlib import Path

for importing in ("true", "false"):
    for scenario in ("free", "late", "ipv6", "ss-fails", "ss-missing", "preflight", "owner-check", "owned", "fail"):
        with socket.socket(socket.AF_INET6 if scenario == "ipv6" else socket.AF_INET) as sock, socket.socket() as free:
            sock.bind(("::1" if scenario == "ipv6" else "127.0.0.1", 0))
            free.bind(("127.0.0.1", 0))
            if scenario in ("owned", "owner-check"):
                sock.listen()
            Path("mappings-read").unlink(missing_ok=True)
            Path("volume").touch()
            Path("events").write_text("")
            env = dict(os.environ, IMPORT_MODE=importing, scenario=scenario,
                       port=str(sock.getsockname()[1]), free_port=str(free.getsockname()[1]),
                       socket_fd=str(sock.fileno()))
            result = subprocess.run(["bash", "volume-case"], env=env, pass_fds=(sock.fileno(),),
                                    capture_output=True, text=True, timeout=10)
            events = Path("events").read_text().splitlines()
            output = result.stdout + result.stderr
            early = scenario in ("preflight", "owner-check")
            kept = early or scenario in ("late", "ipv6", "ss-fails", "ss-missing", "fail")
            evidence = (importing, scenario, result.returncode, events, output)
            assert result.returncode == int(kept), evidence
            assert events == ([] if early else ["down"] if kept else ["down", "rm"]), evidence
            assert Path("volume").exists() == kept, evidence
            if scenario == "late":
                assert f"127.0.0.1:{sock.getsockname()[1]}/tcp" in output, evidence
            if scenario == "ipv6":
                assert f"[0:0:0:0:0:0:0:1]:{sock.getsockname()[1]}/tcp" in output, evidence
            if early or scenario.startswith("ss-"):
                assert "inspect" in output and str(sock.getsockname()[1]) in output, evidence
            if scenario == "fail":
                assert "Could not stop this Compose project" in output, evidence
PY
echo 'PASS: setup and import stop once, check the requested sockets and then remove the selected volume'

# Compose rejects a stop grace period without its unit for the whole
# project, so every docker compose command would fail: setup.sh and
# reconfigure.sh refuse it first, by name.
source <(sed -n '/^check_mariadb_stop_grace_period() {/,/^}/p' "$root/docker/setup.sh")
reset_case
for grace in '' 10m 600s 1h30m 500ms; do
    MARIADB_STOP_GRACE_PERIOD=$grace check_mariadb_stop_grace_period || fail "stop grace period '$grace' refused"
    MARIADB_STOP_GRACE_PERIOD=$grace "$real_docker" compose --env-file "$work/.env" \
        -f "$root/docker/docker-compose.yml" config --quiet || fail "Compose refuses the stop grace period '$grace'"
done
if MARIADB_STOP_GRACE_PERIOD=600 "$real_docker" compose --env-file "$work/.env" \
    -f "$root/docker/docker-compose.yml" config --quiet 2>/dev/null; then
    fail 'Compose now takes a stop grace period without its unit: revisit the check'
fi
for grace in 600 10M ' 10m' 10m30 0; do
    if MARIADB_STOP_GRACE_PERIOD=$grace check_mariadb_stop_grace_period 2> grace.err; then
        fail "stop grace period '$grace' accepted"
    fi
    grep -Fq "MARIADB_STOP_GRACE_PERIOD must be a duration with its unit, such as 600s or 15m, got '$grace'" grace.err ||
        fail "a refused stop grace period must be named: $(cat grace.err)"
done
# Only the selection of the saved import endpoint may come between loading
# .env and the check: assignments of IMPORT_ variables and tests of them,
# with no command substitution.
loaded=$(awk '$0 == "source .env" { capture = 1; next } capture { print } capture && $0 == "check_mariadb_stop_grace_period || exit 1" { exit }' \
    "$root/docker/setup.sh")
before=$(sed '$d' <<< "$loaded")
if [ "$(tail -n 1 <<< "$loaded")" != 'check_mariadb_stop_grace_period || exit 1' ] ||
    grep -Evq '^ *(IMPORT_[A-Z_]+=|(el)?if \[ |else$|fi$)' <<< "$before" ||
    grep -Eq '[$][(]|`' <<< "$before"; then
    fail 'setup.sh must check the stop grace period as soon as it loads .env'
fi
mkdir -p reconfigure/bin
cp "$root/docker/reconfigure.sh" reconfigure/
touch reconfigure/docker-compose.yml
printf '#!/bin/sh\nexit 97\n' > reconfigure/bin/docker
chmod +x reconfigure/bin/docker
printf 'DOMAIN=example.com\nMARIADB_PASSWORD=fixture-user-only\nMARIADB_STOP_GRACE_PERIOD=600\n' > reconfigure/.env
status=0
(cd reconfigure && PATH="$work/reconfigure/bin:$PATH" bash reconfigure.sh) > reconfigure.log 2>&1 || status=$?
if [ "$status" -ne 1 ] ||
    ! grep -Fq "MARIADB_STOP_GRACE_PERIOD in .env must be a duration with its unit, such as 600s or 15m, got '600'" reconfigure.log; then
    fail "reconfigure.sh must refuse a stop grace period without its unit (exit $status): $(cat reconfigure.log)"
fi
echo 'PASS: a stop grace period without its unit is refused before any docker compose command'
