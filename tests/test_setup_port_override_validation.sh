#!/bin/bash
# D2: a port override from the environment (HTTP_PORT, HTTPS_PORT, and the four
# 127.0.0.1-published ports) used to be written to .env with no check, then read
# back by `source .env`. A value like HTTP_PORT='80;touch X' therefore ran a
# command as root on the next source, and MARIADB_HOST_PORT=abc silently broke
# every later run. setup.sh now validates each override and refuses an invalid
# one before it ever reaches .env.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kvs-setup-port-override.XXXXXX")

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

env_value() {
    sed -n "s/^$2=//p" "$1" | head -n 1
}

make_setup_copy() {
    local destination="$1" log_dir="$2"
    # Keep EUID literal while redirecting setup logs into the disposable fixture.
    # shellcheck disable=SC2016
    sed \
        -e "s|/opt/kvs/logs|${log_dir}|g" \
        -e 's/if \[ "$EUID" -ne 0 \]; then/if false; then/' \
        "$REPO_ROOT/docker/setup.sh" > "$destination"
    chmod +x "$destination"
}

make_mocks() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/docker" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then echo "Docker version 28.0.0, build test"; exit 0; fi
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then echo "Docker Compose version v2.35.0"; exit 0; fi
# No existing containers or volumes for any project in these fixtures.
exit 0
EOF
    for tool in curl gum ss; do
        printf '#!/bin/bash\nexit 0\n' > "$bin_dir/$tool"
    done
    chmod +x "$bin_dir/docker" "$bin_dir/curl" "$bin_dir/gum" "$bin_dir/ss"
}

# A fresh .env with the shipped default ports, as a first run would see it.
make_env() {
    cp "$REPO_ROOT/docker/.env.example" "$1"
}

# run_with_override <case name> <NAME=value>...: run the setup copy headless
# with the given port overrides. Sets the globals
# `status`, `output_log` and `env_file` for the caller to assert on. The run
# mirrors the headless fixture that reaches the cache selection, so a valid
# override is persisted and the run continues, while an invalid one is refused
# at the override check, before `source .env` would execute it.
run_with_override() {
    local name="$1" work_dir
    shift
    local case_dir="$TMP_ROOT/$name"
    work_dir="$case_dir/docker"
    mkdir -p "$work_dir/kvs-archive" "$case_dir/bin" "$case_dir/logs"
    make_env "$work_dir/.env"
    make_setup_copy "$case_dir/setup.sh" "$case_dir/logs"
    make_mocks "$case_dir/bin"
    # set_php_bases resolves the PHP base next to the script; resolve-bases.sh
    # reads the lock one directory up from itself.
    cp "$REPO_ROOT/docker/bin/resolve-bases.sh" "$case_dir/bin/"
    cp "$REPO_ROOT/docker/images.lock" "$case_dir/"
    : > "$work_dir/kvs-archive/KVS_7.0.2_mysite.test.zip"

    output_log="$case_dir/output.log"
    env_file="$work_dir/.env"
    set +e
    timeout 120 env -C "$work_dir" \
        -u COMPOSE_PROJECT_NAME -u SITE_PREFIX -u SSL_PROVIDER \
        -u CACHE_CHOICE -u PREFIX_CHOICE -u SSL_CHOICE \
        PATH="$case_dir/bin:/usr/bin:/bin" \
        HEADLESS=y \
        PREFLIGHT_BYPASS=y \
        GEOIP_CHOICE=2 \
        DOMAIN=mysite.test \
        EMAIL=ops@mysite.test \
        "$@" \
        "$case_dir/setup.sh" > "$output_log" 2>&1
    status=$?
    set -e
    [ "$status" -ne 124 ] || fail "$name: setup hung (timeout)"
}

# 1. An HTTP_PORT carrying a shell command is refused before it is written, so
#    the override never reaches .env, the injected command never runs, and the
#    run stops at the override check. The unchanged .env is the primary signal:
#    the unvalidated value would otherwise be written verbatim (and then either
#    run on the next `source .env` or break every later run of the parser).
inject_marker="$TMP_ROOT/http-port-injected"
run_with_override http-injection "HTTP_PORT=80;touch ${inject_marker}"
got=$(env_value "$env_file" HTTP_PORT)
[ "$got" = "80" ] ||
    fail "HTTP_PORT injection: .env HTTP_PORT became '${got}', expected the unchanged 80"
[ "$status" -ne 0 ] ||
    fail "HTTP_PORT injection: setup exited 0, expected a refusal"
[ ! -e "$inject_marker" ] ||
    fail "HTTP_PORT injection: the injected command ran (${inject_marker} was created)"
grep -Fq "is not a valid port" "$output_log" ||
    fail "HTTP_PORT injection: no validation error in output: $(tail -n 3 "$output_log")"
# The refusal must happen at the override check, before the first `source .env`.
! grep -Fq "Cache Server" "$output_log" ||
    fail "HTTP_PORT injection: setup ran on past the override check instead of refusing"
echo "ok 1 - HTTP_PORT carrying a command is refused before it reaches .env"

# 2. A non-numeric loopback port is refused and .env keeps its default; such a
#    value would otherwise be written and break every later run. The unchanged
#    .env is the primary signal here too (an accepted `abc` parses cleanly, so
#    the run would continue rather than exit, making the exit code no witness).
run_with_override mariadb-abc MARIADB_HOST_PORT=abc
got=$(env_value "$env_file" MARIADB_HOST_PORT)
[ "$got" = "3306" ] ||
    fail "MARIADB_HOST_PORT=abc: .env became '${got}', expected the unchanged 3306"
[ "$status" -ne 0 ] ||
    fail "MARIADB_HOST_PORT=abc: setup exited 0, expected a refusal"
grep -Fq "is not a valid port" "$output_log" ||
    fail "MARIADB_HOST_PORT=abc: no validation error in output: $(tail -n 3 "$output_log")"
echo "ok 2 - a non-numeric loopback port override is refused and .env is intact"

# 3. A valid override still passes validation, is written to .env and the run
#    continues, so the check does not reject legitimate values.
run_with_override http-8080 HTTP_PORT=8080
grep -Fq "Cache Server" "$output_log" ||
    fail "HTTP_PORT=8080: a valid override did not pass validation (never reached the cache selection): $(tail -n 3 "$output_log")"
got=$(env_value "$env_file" HTTP_PORT)
[ "$got" = "8080" ] ||
    fail "HTTP_PORT=8080: .env HTTP_PORT is '${got}', expected 8080"
echo "ok 3 - a valid HTTP_PORT override passes validation and is written to .env"

# 4. Every override is checked before any is written: valid ones given next to
#    an invalid one are not saved either, so a refused run leaves .env as it
#    found it whatever order the overrides are looked at in.
run_with_override mixed MARIADB_HOST_PORT=3307 CACHE_HOST_PORT=11212 \
    MANTICORE_MYSQL_HOST_PORT=9316 MANTICORE_HTTP_HOST_PORT=9318 HTTPS_PORT=8443 \
    "HTTP_PORT=80;touch ${inject_marker}"
[ "$status" -ne 0 ] || fail "mixed overrides: setup exited 0, expected a refusal"
for pair in MARIADB_HOST_PORT=3306 CACHE_HOST_PORT=11211 MANTICORE_MYSQL_HOST_PORT=9306 \
    MANTICORE_HTTP_HOST_PORT=9308 HTTPS_PORT=443 HTTP_PORT=80; do
    got=$(env_value "$env_file" "${pair%%=*}")
    [ "$got" = "${pair#*=}" ] ||
        fail "mixed overrides: .env ${pair%%=*} became '${got}' although the run was refused"
done
[ ! -e "$inject_marker" ] || fail "mixed overrides: the injected command ran"
echo "ok 4 - a refused override leaves every other override out of .env"

# 5. An empty override stands for the default, as Compose reads
#    ${HTTP_PORT:-80}: it is accepted and the run goes on.
run_with_override http-empty HTTP_PORT=
grep -Fq "Cache Server" "$output_log" ||
    fail "HTTP_PORT=: an empty override was refused: $(tail -n 3 "$output_log")"
grep -Fxq 'HTTP_PORT=' "$env_file" ||
    fail "HTTP_PORT=: .env HTTP_PORT is '$(env_value "$env_file" HTTP_PORT)', expected empty"
echo "ok 5 - an empty port override is accepted as the default"

echo "PASS: setup validates port overrides before writing .env"
