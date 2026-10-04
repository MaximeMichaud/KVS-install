#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROTATE="${ROOT_DIR}/docker/nginx/rotate-site-logs.sh"
ENTRYPOINT="${ROOT_DIR}/docker/nginx/docker-entrypoint.sh"
TEST_DIR=$(mktemp -d /tmp/kvs-log-rotation.XXXXXX)
BACKGROUND_PIDS=()
FAKE_MASTER_PID=''
LOG_SETTINGS=(DOCKER_LOG_MAX_SIZE DOCKER_LOG_MAX_FILE NGINX_LOG_MAX_SIZE NGINX_LOG_KEEP NGINX_LOG_CHECK_INTERVAL)

cleanup() {
    local pid

    for pid in "${BACKGROUND_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "Docker with the Compose plugin is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# Settings exported by the caller would hide the defaults under test.
unset "${LOG_SETTINGS[@]}" COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME \
    NGINX_LOG_DIR NGINX_PID_FILE

#################################################################
# Compose: every container keeps bounded json-file logs
#################################################################

cat > "${TEST_DIR}/compose-default.env" <<'EOF'
DOMAIN=example.com
SITE_PREFIX=kvs-example
MARIADB_ROOT_PASSWORD=test-root
MARIADB_PASSWORD=test-user
EOF
cp "${TEST_DIR}/compose-default.env" "${TEST_DIR}/compose-custom.env"
cat >> "${TEST_DIR}/compose-custom.env" <<'EOF'
DOCKER_LOG_MAX_SIZE=50m
DOCKER_LOG_MAX_FILE=4
NGINX_LOG_MAX_SIZE=250M
NGINX_LOG_KEEP=9
NGINX_LOG_CHECK_INTERVAL=120
EOF

# Renders a Compose model with every profile it declares, so that the
# services behind a profile, the one-shots included, are checked too.
render_compose() {
    local output="$1"
    local profile
    local profiles=()
    shift

    while IFS= read -r profile; do
        profiles+=(--profile "$profile")
    done < <(docker compose "$@" config --profiles)
    docker compose "$@" "${profiles[@]}" config --format json > "$output"
}

assert_capped_logs() {
    local model="$1"
    local size="$2"
    local files="$3"
    local offenders

    offenders=$(jq -r --arg size "$size" --arg files "$files" '
        [.services | to_entries[] |
         select(.value.logging.driver != "json-file" or
                .value.logging.options["max-size"] != $size or
                .value.logging.options["max-file"] != $files) | .key] | join(" ")
    ' "$model")
    [ -z "$offenders" ] ||
        fail "$(basename "$model"): no json-file logs capped at ${files} x ${size} for: ${offenders}"
}

assert_one_shots_rendered() {
    jq -e '.services["kvs-init"] and .services["phpmyadmin-init"]' "$1" >/dev/null ||
        fail "$(basename "$1"): the one-shot services were not rendered"
}

# The site logs and their generations outlive a recreated Nginx container.
assert_site_logs_in_volume() {
    jq -e '[.services.nginx.volumes[] | select(.target == "/var/log/nginx")] |
        length == 1 and .[0].type == "volume"' "$1" >/dev/null ||
        fail "$(basename "$1"): the Nginx site logs are not kept in a volume"
}

assert_rotation_settings() {
    local model="$1"
    local size="$2"
    local keep="$3"
    local interval="$4"

    jq -e --arg size "$size" --arg keep "$keep" --arg interval "$interval" '
        .services.nginx.environment.NGINX_LOG_MAX_SIZE == $size and
        .services.nginx.environment.NGINX_LOG_KEEP == $keep and
        .services.nginx.environment.NGINX_LOG_CHECK_INTERVAL == $interval
    ' "$model" >/dev/null ||
        fail "$(basename "$model"): Nginx does not receive the rotation settings ${size}, ${keep}, ${interval}"
}

test_compose_log_limits() {
    local compose_dir="${ROOT_DIR}/docker"
    local env_file
    local model
    local suffix

    for suffix in default custom; do
        env_file="${TEST_DIR}/compose-${suffix}.env"
        render_compose "${TEST_DIR}/single-${suffix}.json" --env-file "$env_file" \
            -f "${compose_dir}/docker-compose.yml"
        render_compose "${TEST_DIR}/multi-${suffix}.json" --env-file "$env_file" \
            -f "${compose_dir}/docker-compose.yml" -f "${compose_dir}/docker-compose.multi.yml"
        render_compose "${TEST_DIR}/site-${suffix}.json" --env-file "$env_file" \
            -f "${compose_dir}/multi-site/docker-compose.site.yml.template"
        render_compose "${TEST_DIR}/caddy-${suffix}.json" --env-file "$env_file" \
            -p multi-site -f "${compose_dir}/multi-site/docker-compose.caddy.yml"
    done

    for model in single multi site; do
        assert_one_shots_rendered "${TEST_DIR}/${model}-default.json"
        assert_site_logs_in_volume "${TEST_DIR}/${model}-default.json"
        assert_capped_logs "${TEST_DIR}/${model}-default.json" 10m 3
        assert_capped_logs "${TEST_DIR}/${model}-custom.json" 50m 4
        assert_rotation_settings "${TEST_DIR}/${model}-default.json" 100M 20 60
        assert_rotation_settings "${TEST_DIR}/${model}-custom.json" 250M 9 120
    done
    assert_capped_logs "${TEST_DIR}/caddy-default.json" 10m 3
    assert_capped_logs "${TEST_DIR}/caddy-custom.json" 50m 4

    # The shell environment overrides .env, as for any Compose variable.
    DOCKER_LOG_MAX_SIZE=1g DOCKER_LOG_MAX_FILE=2 NGINX_LOG_MAX_SIZE=0 \
        render_compose "${TEST_DIR}/site-shell.json" --env-file "${TEST_DIR}/compose-custom.env" \
        -f "${compose_dir}/multi-site/docker-compose.site.yml.template"
    assert_capped_logs "${TEST_DIR}/site-shell.json" 1g 2
    assert_rotation_settings "${TEST_DIR}/site-shell.json" 0 9 120
}

test_settings_documented() {
    local readme
    local setting

    for setting in DOCKER_LOG_MAX_SIZE=10m DOCKER_LOG_MAX_FILE=3 NGINX_LOG_MAX_SIZE=100M \
        NGINX_LOG_KEEP=20 NGINX_LOG_CHECK_INTERVAL=60; do
        grep -Fqx "$setting" "${ROOT_DIR}/docker/.env.example" ||
            fail "docker/.env.example does not carry ${setting}, the Compose default"
    done
    readme=$(tr -d '\r' < "${ROOT_DIR}/README.md")
    for setting in "${LOG_SETTINGS[@]}"; do
        grep -Fq "\`${setting}\`" <<< "$readme" || fail "README does not document ${setting}"
    done
    grep -Fq 'docker compose up -d' <<< "$readme" ||
        fail "README does not say how existing containers take the new log limits"
}

test_rotation_wiring() {
    local start_line
    local exec_line
    local template

    grep -Fqx 'COPY rotate-site-logs.sh /usr/local/bin/rotate-site-logs' \
        "${ROOT_DIR}/docker/nginx/Dockerfile" ||
        fail "the Nginx image does not install the site log rotation"
    grep -Eq '^RUN chmod \+x .*/usr/local/bin/rotate-site-logs' "${ROOT_DIR}/docker/nginx/Dockerfile" ||
        fail "the site log rotation is not executable in the Nginx image"
    start_line=$(grep -nFx '/usr/local/bin/rotate-site-logs &' "$ENTRYPOINT" | cut -d: -f1)
    # shellcheck disable=SC2016  # The literal entrypoint line is the pattern.
    exec_line=$(grep -nFx 'exec /docker-entrypoint.sh "$@"' "$ENTRYPOINT" | cut -d: -f1)
    [ -n "$start_line" ] && [ -n "$exec_line" ] && [ "$start_line" -lt "$exec_line" ] ||
        fail "the entrypoint does not start the site log rotation in the background before Nginx"
    # The rotation picks the site logs by these names, in both layouts.
    for template in conf/nginx/templates/kvs.conf.tpl docker/multi-site/nginx/kvs-caddy.conf.template; do
        # shellcheck disable=SC2016  # Literal template placeholders.
        grep -Fq 'access_log /var/log/nginx/${DOMAIN}.access.log;' "${ROOT_DIR}/${template}" ||
            fail "${template} no longer writes the access log the rotation expects"
        # shellcheck disable=SC2016  # Literal template placeholders.
        grep -Fq 'error_log /var/log/nginx/${DOMAIN}.error.log warn;' "${ROOT_DIR}/${template}" ||
            fail "${template} no longer writes the error log the rotation expects"
    done
}

#################################################################
# Rotation of the site logs, against a stand-in Nginx master
#################################################################

# Runs one check of the rotation script on a scratch directory.
rotate_once() {
    local dir="$1"
    shift

    env "$@" NGINX_LOG_DIR="${dir}/logs" NGINX_PID_FILE="${dir}/nginx.pid" \
        sh "$ROTATE" --once
}

# Stands in for the Nginx master: a process with its title that holds the two
# site logs open and, as Nginx does on SIGUSR1, reopens them by name and
# counts the reopenings. With "write", it appends numbered lines until the
# stop file appears, then records how many it wrote. It is ready once its
# logs are open and SIGUSR1 is handled.
start_fake_master() {
    local dir="$1"
    local mode="${2:-idle}"

    rm -f "${dir}/ready"
    (
        exec -a 'nginx: master process nginx -g daemon off;' bash -c '
            dir=$1
            mode=$2
            reopened=0
            exec 3>>"${dir}/logs/example.com.access.log" 4>>"${dir}/logs/example.com.error.log"
            reopen() {
                exec 3>>"${dir}/logs/example.com.access.log" 4>>"${dir}/logs/example.com.error.log"
                reopened=$((reopened + 1))
                printf "%s\n" "$reopened" > "${dir}/reopened.tmp"
                mv -f "${dir}/reopened.tmp" "${dir}/reopened"
            }
            trap reopen USR1
            : > "${dir}/ready"
            line=0
            while [ ! -e "${dir}/stop" ]; do
                if [ "$mode" = write ]; then
                    line=$((line + 1))
                    printf "GET /request/%08d HTTP/1.1 200\n" "$line" >&3
                    printf "upstream error %08d\n" "$line" >&4
                    [ $((line % 20)) -ne 0 ] || sleep 0.005
                else
                    sleep 0.02
                fi
            done
            printf "%s\n" "$line" > "${dir}/written"
        ' fake-nginx "$dir" "$mode"
    ) &
    FAKE_MASTER_PID=$!
    BACKGROUND_PIDS+=("$FAKE_MASTER_PID")
    printf '%s\n' "$FAKE_MASTER_PID" > "${dir}/nginx.pid"
    wait_for "the stand-in Nginx master to start" test -e "${dir}/ready"
}

stop_fake_master() {
    local dir="$1"

    : > "${dir}/stop"
    wait "$FAKE_MASTER_PID" || fail "the stand-in Nginx master failed"
}

wait_for() {
    local description="$1"
    local attempt
    shift

    for attempt in $(seq 1 400); do
        if "$@"; then
            return 0
        fi
        sleep 0.025
    done
    fail "timed out after ${attempt} attempts waiting for ${description}"
}

size_at_least() {
    [ -f "$1" ] && [ "$(stat -c %s "$1")" -ge "$2" ]
}

reopened_at_least() {
    [ -f "${1}/reopened" ] && [ "$(cat "${1}/reopened")" -ge "$2" ]
}

reopen_count() {
    if [ -f "${1}/reopened" ]; then
        cat "${1}/reopened"
    else
        echo 0
    fi
}

# Runs a check and, when it rotated a log, waits until the stand-in master
# has reopened, after which nothing writes to the renamed file any more.
rotate_and_settle() {
    local dir="$1"
    local before
    shift

    before=$(reopen_count "$dir")
    rotate_once "$dir" "$@" > "${dir}/check.out" 2> "${dir}/check.err"
    cat "${dir}/check.out" >> "${dir}/rotation.out"
    cat "${dir}/check.err" >> "${dir}/rotation.err"
    if grep -Fq 'Rotated the Nginx site logs' "${dir}/check.out"; then
        wait_for "Nginx to reopen its logs" reopened_at_least "$dir" $((before + 1))
        sleep 0.1
        [ "$(reopen_count "$dir")" -eq $((before + 1)) ] ||
            fail "one check signalled Nginx more than once"
    else
        [ "$(reopen_count "$dir")" -eq "$before" ] || fail "a check without rotation signalled Nginx"
    fi
}

# Makes every rotated, still uncompressed generation look written two minutes
# ago, older than the 60 second default interval.
age_rotated_logs() {
    local rotated

    for rotated in "$1"/logs/*.1; do
        [ -f "$rotated" ] || continue
        touch -d '-2 minutes' "$rotated"
    done
}

# Prints a log's generations from the oldest to the live file.
collect_generations() {
    local base="$1"
    local generation

    for generation in $(seq 20 -1 1); do
        if [ -f "${base}.${generation}.gz" ]; then
            gzip -dc "${base}.${generation}.gz"
        fi
    done
    if [ -f "${base}.1" ]; then
        cat "${base}.1"
    fi
    if [ -f "$base" ]; then
        cat "$base"
    fi
}

write_bytes() {
    head -c "$2" /dev/zero | tr '\0' 'x' > "$1"
}

new_case() {
    local dir="${TEST_DIR}/$1"

    mkdir -p "${dir}/logs"
    printf '%s\n' "$dir"
}

# Lines keep coming while the logs rotate: the ones a worker writes between
# the rename and its reopening land in <name>.1, so the generations put back
# together hold every line once, in order. A copy in place of the rename
# would lose the lines written meanwhile, however few: <name>.1 has to be the
# file the worker holds.
test_rotation_keeps_every_line() {
    local dir
    local logs
    local round
    local live_inode
    local rotated_inode
    local written
    local generation

    dir=$(new_case lossless)
    logs="${dir}/logs"
    start_fake_master "$dir" write
    for round in 1 2 3 4 5 6; do
        wait_for "an access log of 8k" size_at_least "${logs}/example.com.access.log" 8192
        live_inode=$(stat -c %i "${logs}/example.com.access.log")
        rotate_and_settle "$dir" NGINX_LOG_MAX_SIZE=8k NGINX_LOG_KEEP=20
        [ -f "${logs}/example.com.access.log.1" ] ||
            fail "round ${round}: the access log was not renamed to .1"
        rotated_inode=$(stat -c %i "${logs}/example.com.access.log.1")
        [ "$rotated_inode" = "$live_inode" ] ||
            fail "round ${round}: the access log was copied to .1 instead of renamed"

        # Written moments ago: neither compressed nor rotated over.
        wait_for "an access log of 8k" size_at_least "${logs}/example.com.access.log" 8192
        rotate_and_settle "$dir" NGINX_LOG_MAX_SIZE=8k NGINX_LOG_KEEP=20
        [ "$(stat -c %i "${logs}/example.com.access.log.1")" = "$rotated_inode" ] ||
            fail "round ${round}: a log was rotated again before its previous generation was compressed"
        [ ! -e "${logs}/example.com.access.log.1.gz" ] ||
            fail "round ${round}: a generation written moments ago was compressed"
        age_rotated_logs "$dir"
    done
    [ ! -s "${dir}/rotation.err" ] || fail "the rotation reported: $(head -n 1 "${dir}/rotation.err")"
    stop_fake_master "$dir"
    age_rotated_logs "$dir"
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=8k NGINX_LOG_KEEP=20 >> "${dir}/rotation.out" 2>&1

    written=$(cat "${dir}/written")
    [ "$written" -gt 0 ] || fail "the stand-in Nginx master wrote nothing"
    # shellcheck disable=SC2046  # One printf argument per line number.
    printf 'GET /request/%08d HTTP/1.1 200\n' $(seq 1 "$written") > "${dir}/access.expected"
    # shellcheck disable=SC2046  # One printf argument per line number.
    printf 'upstream error %08d\n' $(seq 1 "$written") > "${dir}/error.expected"
    collect_generations "${logs}/example.com.access.log" > "${dir}/access.collected"
    collect_generations "${logs}/example.com.error.log" > "${dir}/error.collected"
    cmp -s "${dir}/access.expected" "${dir}/access.collected" ||
        fail "the rotated access logs lost, repeated or reordered lines"
    cmp -s "${dir}/error.expected" "${dir}/error.collected" ||
        fail "the rotated error logs lost, repeated or reordered lines"

    [ ! -e "${logs}/example.com.access.log.1" ] ||
        fail "an idle generation was not compressed"
    for generation in 1 2 3 4 5 6; do
        gzip -t "${logs}/example.com.access.log.${generation}.gz" 2>/dev/null ||
            fail "access log generation ${generation} is not a valid gzip file"
    done
    [ ! -e "${logs}/example.com.access.log.7.gz" ] ||
        fail "more access log generations than rotations"
    [ -e "${logs}/example.com.error.log.2.gz" ] || fail "the error log did not rotate"
}

# The image links access.log and error.log to the container output. Here they
# point at files the test watches, as do links named like a site log, like a
# generation waiting for compression, like a generation the shift passes over,
# like an old generation, and like the temporary copy and the result of a
# compression; a limit of 16 bytes, 5 generations and old link times make each
# of them due. None may be renamed, compressed or followed; the last two are
# replaced like files.
test_symbolic_links_untouched() {
    local dir
    local logs
    local link

    dir=$(new_case links)
    logs="${dir}/logs"
    for link in stdout stderr site pending shifted old copy compressed; do
        write_bytes "${dir}/${link}.target" 20000
    done
    sha256sum "${dir}"/*.target > "${dir}/targets.sha256"
    ln -s "${dir}/stdout.target" "${logs}/access.log"
    ln -s "${dir}/stderr.target" "${logs}/error.log"
    ln -s "${dir}/site.target" "${logs}/linked.example.com.access.log"
    ln -s "${dir}/pending.target" "${logs}/linked.example.com.error.log.1"
    ln -s "${dir}/shifted.target" "${logs}/example.com.access.log.2.gz"
    ln -s "${dir}/old.target" "${logs}/example.com.access.log.9.gz"
    ln -s "${dir}/copy.target" "${logs}/example.com.error.log.1.gz.tmp"
    ln -s "${dir}/compressed.target" "${logs}/example.com.error.log.1.gz"
    touch -h -d '-2 minutes' "${logs}"/*
    write_bytes "${logs}/example.com.access.log" 100
    write_bytes "${logs}/linked.example.com.error.log" 100
    printf 'last error\n' > "${logs}/example.com.error.log.1"
    touch -d '-2 minutes' "${logs}/example.com.error.log.1"
    start_fake_master "$dir"

    rotate_and_settle "$dir" NGINX_LOG_MAX_SIZE=16 NGINX_LOG_KEEP=5
    [ -e "${logs}/example.com.access.log.1" ] || fail "the site log next to the links was not rotated"
    [ "$(stat -c %s "${logs}/linked.example.com.error.log")" -eq 100 ] ||
        fail "a log whose .1 is a symbolic link was rotated over it"
    grep -Fq "linked.example.com.error.log.1 is a symbolic link" "${dir}/check.err" ||
        fail "a symbolic link blocking a rotation was not reported"
    [ ! -L "${logs}/example.com.error.log.1.gz" ] && [ ! -e "${logs}/example.com.error.log.1.gz.tmp" ] &&
        [ "$(gzip -dc "${logs}/example.com.error.log.1.gz")" = 'last error' ] ||
        fail "a compression wrote through a link at its temporary path or at its result"
    [ "$(readlink "${logs}/access.log")" = "${dir}/stdout.target" ] &&
        [ "$(readlink "${logs}/error.log")" = "${dir}/stderr.target" ] &&
        [ "$(readlink "${logs}/linked.example.com.access.log")" = "${dir}/site.target" ] &&
        [ "$(readlink "${logs}/linked.example.com.error.log.1")" = "${dir}/pending.target" ] &&
        [ "$(readlink "${logs}/example.com.access.log.2.gz")" = "${dir}/shifted.target" ] &&
        [ "$(readlink "${logs}/example.com.access.log.9.gz")" = "${dir}/old.target" ] &&
        [ ! -e "${logs}/example.com.access.log.3.gz" ] && [ ! -L "${logs}/example.com.access.log.3.gz" ] ||
        fail "a symbolic link in the log directory was renamed or removed"
    sha256sum --quiet -c "${dir}/targets.sha256" || fail "the target of a symbolic link was modified"
    if compgen -G "${logs}/access.log.*" >/dev/null || compgen -G "${logs}/error.log.*" >/dev/null ||
        compgen -G "${logs}/linked.example.com.access.log.*" >/dev/null ||
        compgen -G "${logs}/linked.example.com.error.log.1.*" >/dev/null; then
        fail "a symbolic link was rotated or compressed"
    fi
    stop_fake_master "$dir"
}

# NGINX_LOG_KEEP bounds the generations, including those a larger value
# left behind; the oldest go first.
test_generations_are_bounded() {
    local dir
    local logs
    local generation
    local round

    dir=$(new_case bounded)
    logs="${dir}/logs"
    for generation in 1 2 3 4 5 6; do
        printf 'generation %s\n' "$generation" | gzip -c > "${logs}/example.com.access.log.${generation}.gz"
    done
    start_fake_master "$dir"
    write_bytes "${logs}/example.com.access.log" 3000
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=2k NGINX_LOG_KEEP=3 > "${dir}/rotation.out"
    [ "$(gzip -dc "${logs}/example.com.access.log.2.gz")" = 'generation 1' ] &&
        [ "$(gzip -dc "${logs}/example.com.access.log.3.gz")" = 'generation 2' ] ||
        fail "the compressed generations did not move up by one"
    for generation in 4 5 6; do
        [ ! -e "${logs}/example.com.access.log.${generation}.gz" ] ||
            fail "generation ${generation} outlived NGINX_LOG_KEEP=3"
    done

    for round in 1 2 3; do
        wait_for "Nginx to reopen its logs" reopened_at_least "$dir" "$round"
        age_rotated_logs "$dir"
        {
            printf 'round %s\n' "$round"
            head -c 3000 /dev/zero | tr '\0' 'x'
        } >> "${logs}/example.com.access.log"
        rotate_once "$dir" NGINX_LOG_MAX_SIZE=2k NGINX_LOG_KEEP=3 >> "${dir}/rotation.out"
    done
    stop_fake_master "$dir"
    age_rotated_logs "$dir"
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=2k NGINX_LOG_KEEP=3 >> "${dir}/rotation.out" 2>&1
    [ "$(find "$logs" -name 'example.com.access.log.*' | wc -l)" -eq 3 ] ||
        fail "NGINX_LOG_KEEP=3 did not leave exactly three generations"
    for generation in 1 2 3; do
        gzip -dc "${logs}/example.com.access.log.${generation}.gz" |
            grep -Fqx "round $((4 - generation))" ||
            fail "the kept generations are not the three newest, newest first"
    done
}

# Logs due together rotate in one check, which signals Nginx once.
test_one_signal_per_check() {
    local dir
    local logs
    local log

    dir=$(new_case together)
    logs="${dir}/logs"
    start_fake_master "$dir"
    write_bytes "${logs}/example.com.access.log" 3000
    write_bytes "${logs}/example.com.error.log" 3000
    write_bytes "${logs}/second.example.com.error.log" 3000
    rotate_and_settle "$dir" NGINX_LOG_MAX_SIZE=2k
    grep -Fqx 'Rotated the Nginx site logs: example.com.access.log example.com.error.log second.example.com.error.log' \
        "${dir}/rotation.out" || fail "the logs due together were not rotated and reported together"
    for log in example.com.access.log example.com.error.log second.example.com.error.log; do
        [ -e "${logs}/${log}.1" ] || fail "${log} was not rotated"
    done
    stop_fake_master "$dir"
}

# Only the Nginx master gets the signal: a stale, foreign or missing PID file
# postpones the rotation instead of renaming logs nobody reopens.
test_rotation_waits_for_nginx() {
    local dir
    local logs
    local other_pid
    local output

    dir=$(new_case no-master)
    logs="${dir}/logs"
    write_bytes "${logs}/example.com.access.log" 5000

    rotate_once "$dir" NGINX_LOG_MAX_SIZE=1k > "${dir}/missing.out" 2>&1
    sleep 300 &
    other_pid=$!
    BACKGROUND_PIDS+=("$other_pid")
    printf '%s\n' "$other_pid" > "${dir}/nginx.pid"
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=1k > "${dir}/foreign.out" 2>&1
    kill -0 "$other_pid" 2>/dev/null || fail "a process that is not the Nginx master was signalled"
    kill "$other_pid"
    wait "$other_pid" 2>/dev/null || true
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=1k > "${dir}/stale.out" 2>&1
    printf 'not a pid\n' > "${dir}/nginx.pid"
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=1k > "${dir}/garbage.out" 2>&1

    [ "$(stat -c %s "${logs}/example.com.access.log")" -eq 5000 ] &&
        [ ! -e "${logs}/example.com.access.log.1" ] ||
        fail "a log was rotated without an Nginx master to reopen it"
    for output in missing foreign stale garbage; do
        grep -Fq 'no Nginx master process' "${dir}/${output}.out" ||
            fail "the ${output} PID file case was not reported"
    done
}

# Sizes take a k, m or g suffix, in powers of 1024, without the octal trap of a
# leading zero; bad values fall back to the defaults and 0 turns the rotation
# off.
test_settings() {
    local dir
    local logs
    local warning

    dir=$(new_case settings)
    logs="${dir}/logs"
    start_fake_master "$dir"

    write_bytes "${logs}/example.com.access.log" 9000
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=010k > "${dir}/settings.out"
    [ ! -e "${logs}/example.com.access.log.1" ] || fail "010k was read as an octal 8k"
    write_bytes "${logs}/example.com.access.log" 10240
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=010k >> "${dir}/settings.out"
    [ -e "${logs}/example.com.access.log.1" ] || fail "a log of exactly 10k was not rotated at 010k"
    rm -f "${logs}"/example.com.access.log*

    truncate -s 1048575 "${logs}/example.com.access.log"
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=1M >> "${dir}/settings.out"
    [ ! -e "${logs}/example.com.access.log.1" ] || fail "a log under 1M was rotated"
    truncate -s 1048576 "${logs}/example.com.access.log"
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=1M >> "${dir}/settings.out"
    [ -e "${logs}/example.com.access.log.1" ] || fail "a log of 1M was not rotated"
    rm -f "${logs}"/example.com.access.log*

    truncate -s 104857599 "${logs}/example.com.error.log"
    rotate_once "$dir" > "${dir}/default.out" 2>&1
    rotate_once "$dir" NGINX_LOG_MAX_SIZE=lots NGINX_LOG_KEEP=0 NGINX_LOG_CHECK_INTERVAL=soon \
        > "${dir}/invalid.out" 2>&1
    [ ! -e "${logs}/example.com.error.log.1" ] || fail "a log under the 100M default was rotated"
    for warning in 'NGINX_LOG_MAX_SIZE=lots is not a size' \
        'NGINX_LOG_KEEP=0 is not a number of generations' \
        'NGINX_LOG_CHECK_INTERVAL=soon is not a number of seconds'; do
        grep -Fq "$warning" "${dir}/invalid.out" || fail "an invalid setting was not reported: ${warning}"
    done
    [ ! -s "${dir}/default.out" ] || fail "the default settings were reported as invalid"
    truncate -s 104857600 "${logs}/example.com.error.log"
    rotate_once "$dir" > "${dir}/default.out" 2>&1
    [ -e "${logs}/example.com.error.log.1" ] || fail "a log of 100M was not rotated by default"
    rm -f "${logs}"/example.com.error.log*

    write_bytes "${logs}/example.com.access.log" 5000
    timeout 10 env NGINX_LOG_DIR="$logs" NGINX_PID_FILE="${dir}/nginx.pid" NGINX_LOG_MAX_SIZE=0 \
        sh "$ROTATE" > "${dir}/off.out" ||
        fail "NGINX_LOG_MAX_SIZE=0 did not stop the rotation at once"
    grep -Fq 'Nginx site log rotation is off' "${dir}/off.out" || fail "the disabled rotation was not reported"
    [ ! -e "${logs}/example.com.access.log.1" ] || fail "NGINX_LOG_MAX_SIZE=0 still rotated a log"

    if sh "$ROTATE" --now >/dev/null 2>&1; then
        fail "an unknown argument was accepted"
    fi
    stop_fake_master "$dir"
}

# A rotated generation is compressed once Nginx has created its log again and
# nothing has written to it for a whole interval (60 seconds by default),
# keeping its time; a leftover partial copy from an interrupted check is
# replaced. While its log is missing, Nginx did not reopen and may still write
# to it, however long it has been idle: it is kept and Nginx is asked again.
test_compression() {
    local dir
    local logs
    local original

    dir=$(new_case compression)
    logs="${dir}/logs"
    # shellcheck disable=SC2046  # One printf argument per line number.
    printf 'line %s\n' $(seq 1 500) > "${logs}/example.com.access.log.1"
    original=$(sha256sum < "${logs}/example.com.access.log.1")
    printf 'partial' > "${logs}/example.com.access.log.1.gz.tmp"
    start_fake_master "$dir"
    rm -f "${logs}/example.com.access.log"

    touch -d '-90 seconds' "${logs}/example.com.access.log.1"
    rotate_once "$dir" > "${dir}/unopened.out" 2> "${dir}/unopened.err"
    [ -e "${logs}/example.com.access.log.1" ] && [ ! -e "${logs}/example.com.access.log.1.gz" ] ||
        fail "a generation was compressed while Nginx had not created its log again"
    grep -Fq 'Nginx did not reopen example.com.access.log; asked it again' "${dir}/unopened.err" &&
        [ ! -s "${dir}/unopened.out" ] || fail "a log Nginx did not reopen was not reported"
    wait_for "Nginx to reopen its logs again" reopened_at_least "$dir" 1

    touch -d '-30 seconds' "${logs}/example.com.access.log.1"
    rotate_once "$dir" > "${dir}/recent.out" 2>&1
    [ -e "${logs}/example.com.access.log.1" ] && [ ! -e "${logs}/example.com.access.log.1.gz" ] ||
        fail "a generation idle for less than the interval was compressed"

    touch -d '-90 seconds' "${logs}/example.com.access.log.1"
    rotate_once "$dir" > "${dir}/idle.out" 2>&1
    [ ! -e "${logs}/example.com.access.log.1" ] && [ ! -e "${logs}/example.com.access.log.1.gz.tmp" ] ||
        fail "an idle generation or a partial copy was left behind"
    [ "$(gzip -dc "${logs}/example.com.access.log.1.gz" | sha256sum)" = "$original" ] ||
        fail "the compressed generation differs from the rotated log"
    [ $(($(date +%s) - $(stat -c %Y "${logs}/example.com.access.log.1.gz"))) -ge 85 ] ||
        fail "the compressed generation lost the time of its last line"
    [ ! -s "${dir}/recent.out" ] && [ ! -s "${dir}/idle.out" ] && [ "$(reopen_count "$dir")" -eq 1 ] ||
        fail "a check that neither rotated nor found a log missing signalled Nginx"
    stop_fake_master "$dir"
}

first_loop_done() {
    [ -e "${1}/logs/example.com.access.log.1.gz" ] && [ ! -e "${1}/logs/example.com.access.log.1" ]
}

second_loop_done() {
    [ -e "${1}/logs/example.com.access.log.2.gz" ] && grep -Fq 'Rotated the Nginx site logs' "${1}/second.out"
}

# The background loop of the entrypoint; stopping and starting it again, as
# a container restart does, carries on from the files alone.
test_loop_survives_restart() {
    local dir
    local logs
    local loop
    local loop_pid

    dir=$(new_case restart)
    logs="${dir}/logs"
    start_fake_master "$dir"

    for loop in first second; do
        env NGINX_LOG_DIR="$logs" NGINX_PID_FILE="${dir}/nginx.pid" NGINX_LOG_MAX_SIZE=4k \
            NGINX_LOG_CHECK_INTERVAL=1 sh "$ROTATE" > "${dir}/${loop}.out" 2>&1 &
        loop_pid=$!
        BACKGROUND_PIDS+=("$loop_pid")
        write_bytes "${logs}/example.com.access.log" 5000
        if [ "$loop" = first ]; then
            wait_for "the loop to rotate and compress a log" first_loop_done "$dir"
        else
            wait_for "the restarted loop to move the generations up" second_loop_done "$dir"
        fi
        kill "$loop_pid"
        wait "$loop_pid" 2>/dev/null || true
    done
    stop_fake_master "$dir"
    grep -Fqx 'Rotated the Nginx site logs: example.com.access.log' "${dir}/second.out" ||
        fail "the restarted loop did not report its rotation"
    [ "$(gzip -dc "${logs}/example.com.access.log.2.gz" | wc -c)" -eq 5000 ] ||
        fail "the generation of the first loop did not move up intact"
}

test_compose_log_limits
test_settings_documented
test_rotation_wiring
test_rotation_keeps_every_line
test_symbolic_links_untouched
test_generations_are_bounded
test_one_signal_per_check
test_rotation_waits_for_nginx
test_settings
test_compression
test_loop_survives_restart

echo "PASS: Container log limits and Nginx site log rotation"
