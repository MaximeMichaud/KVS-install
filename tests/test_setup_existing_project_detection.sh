#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/kvs-setup-existing-project.XXXXXX)
PROJECT_NAME="scope-target"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local expected="$2"

    grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_file_not_contains() {
    local file="$1"
    local unexpected="$2"

    if grep -Fq -- "$unexpected" "$file"; then
        fail "$file unexpectedly contains: $unexpected"
    fi
}

make_setup_copy() {
    local destination="$1"
    local log_dir="$2"

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
printf '%s\n' "$*" >> "$DOCKER_CALL_LOG"

if [ "${1:-}" = "--version" ]; then
    echo "Docker version 28.0.0, build test"
    exit 0
fi
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then
    echo "Docker Compose version v2.35.0"
    exit 0
fi

if [ "${1:-}" = "ps" ]; then
    if [[ " $* " == *" --filter label=com.docker.compose.project=${EXPECTED_PROJECT} "* ]]; then
        if [ "${INCLUDE_CURRENT_PROJECT:-false}" = "true" ]; then
            printf '%s\n' current-container-1 current-container-2
        fi
    else
        # A broad name-based query sees unrelated containers that deliberately
        # use the same service suffixes as KVS.
        printf '%s\n' unrelated-php unrelated-nginx unrelated-cron
    fi
    exit 0
fi

if [ "${1:-}" = "volume" ] && [ "${2:-}" = "ls" ]; then
    if [[ " $* " == *" --filter label=com.docker.compose.project=${EXPECTED_PROJECT} "* ]]; then
        if [ "${INCLUDE_CURRENT_PROJECT:-false}" = "true" ]; then
            echo current-volume-1
        fi
    else
        printf '%s\n' unrelated-volume-1 unrelated-volume-2
    fi
    exit 0
fi

exit 0
EOF
    cat > "$bin_dir/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$bin_dir/gum" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$bin_dir/ss" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$bin_dir/docker" "$bin_dir/curl" "$bin_dir/gum" "$bin_dir/ss"
}

run_case() {
    local case_name="$1"
    local include_current="$2"
    local case_dir="$TMP_ROOT/$case_name"
    local work_dir="$case_dir/work"
    local mock_bin="$case_dir/bin"
    local setup_copy="$case_dir/setup.sh"
    local output="$case_dir/output.log"
    local docker_calls="$case_dir/docker-calls.log"
    local status

    mkdir -p "$work_dir" "$case_dir/logs"
    cp "$REPO_ROOT/docker/.env.example" "$work_dir/.env"
    sed -i \
        -e 's/^DOMAIN=.*/DOMAIN=mysite.test/' \
        -e "s/^SITE_PREFIX=.*/SITE_PREFIX=${PROJECT_NAME}/" \
        -e "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=${PROJECT_NAME}/" \
        "$work_dir/.env"
    make_setup_copy "$setup_copy" "$case_dir/logs"
    make_mocks "$mock_bin"

    set +e
    (
        cd "$work_dir"
        env -u COMPOSE_PROJECT_NAME \
            PATH="$mock_bin:/usr/bin:/bin" \
            DOCKER_CALL_LOG="$docker_calls" \
            EXPECTED_PROJECT="$PROJECT_NAME" \
            INCLUDE_CURRENT_PROJECT="$include_current" \
            HEADLESS=y \
            PREFLIGHT_BYPASS=y \
            DOMAIN=mysite.test \
            EMAIL=ops@mysite.test \
            SSL_CHOICE=3 \
            "$setup_copy"
    ) > "$output" 2>&1
    status=$?
    set -e

    [ "$status" -ne 0 ] || fail "setup should stop because the KVS archive fixture is absent"
    assert_file_contains "$output" "No KVS archive found in ./kvs-archive/"
    assert_file_contains "$docker_calls" \
        "ps -aq --filter label=com.docker.compose.project=${PROJECT_NAME}"
    assert_file_contains "$docker_calls" \
        "volume ls -q --filter label=com.docker.compose.project=${PROJECT_NAME}"
    assert_file_not_contains "$docker_calls" "--format {{.Names}}"
    assert_file_not_contains "$docker_calls" "--filter name=docker_"
}

run_fresh_install_case() {
    local case_dir="$TMP_ROOT/fresh-install"
    local work_dir="$case_dir/docker"
    local mock_bin="$case_dir/bin"
    local setup_copy="$case_dir/setup.sh"
    local output="$case_dir/output.log"
    local docker_calls="$case_dir/docker-calls.log"
    local expected_project="kvs-mysite"
    local status

    mkdir -p "$work_dir" "$case_dir/logs"
    cp "$REPO_ROOT/docker/.env.example" "$work_dir/.env.example"
    make_setup_copy "$setup_copy" "$case_dir/logs"
    make_mocks "$mock_bin"

    set +e
    (
        cd "$work_dir"
        env -u COMPOSE_PROJECT_NAME \
            PATH="$mock_bin:/usr/bin:/bin" \
            DOCKER_CALL_LOG="$docker_calls" \
            EXPECTED_PROJECT="$expected_project" \
            INCLUDE_CURRENT_PROJECT=false \
            HEADLESS=y \
            PREFLIGHT_BYPASS=y \
            DOMAIN=mysite.test \
            EMAIL=ops@mysite.test \
            PREFIX_CHOICE=1 \
            SSL_CHOICE=3 \
            "$setup_copy"
    ) > "$output" 2>&1
    status=$?
    set -e

    [ "$status" -ne 0 ] || fail "fresh setup should stop because the KVS archive fixture is absent"
    assert_file_contains "$output" "No KVS archive found in ./kvs-archive/"
    assert_file_contains "$work_dir/.env" "COMPOSE_PROJECT_NAME=$expected_project"
    assert_file_contains "$docker_calls" \
        "ps -aq --filter label=com.docker.compose.project=${expected_project}"
    assert_file_contains "$docker_calls" \
        "volume ls -q --filter label=com.docker.compose.project=${expected_project}"
    assert_file_not_contains "$docker_calls" \
        "label=com.docker.compose.project=docker"
    assert_file_not_contains "$output" \
        "WARNING: Re-running on existing installation"
}

run_case foreign-only false
assert_file_not_contains "$TMP_ROOT/foreign-only/output.log" \
    "WARNING: Re-running on existing installation"

run_case current-project true
assert_file_contains "$TMP_ROOT/current-project/output.log" \
    "WARNING: Re-running on existing installation (2 container(s), 1 volume(s))"

echo "ok 1 - setup scopes existing-resource detection to the Compose project from .env"

run_fresh_install_case
echo "ok 2 - fresh setup detects resources only after deriving the final Compose project"
