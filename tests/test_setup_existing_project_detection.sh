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

# The earlier changed-domain import acts on the saved project before the
# final prefix is chosen. Run its actual loading and decision blocks; the
# executable Docker double also catches calls made through xargs.
awk '
    $0 == "remove_env_value() {" || $0 == "set_env_value() {" ||
        $0 == "compose_files_for() {" || $0 == "require_compose_config() {" { capture = 1 }
    capture { print }
    capture && /^}$/ { capture = 0 }
' "$REPO_ROOT/docker/setup.sh" > "$TMP_ROOT/project-functions.sh"
awk '
    $0 == "# Load environment" { capture = 1 }
    $0 == "# Domain validation" { capture = 0 }
    capture { print }
' "$REPO_ROOT/docker/setup.sh" > "$TMP_ROOT/project-load.sh"
awk '
    /^# An import under a new domain gets its own stack:/ { capture = 1 }
    /^# Site prefix for container naming / { exit }
    capture { print }
' "$REPO_ROOT/docker/setup.sh" > "$TMP_ROOT/project-retire.sh"
mkdir -p "$TMP_ROOT/prior-bin"
cat > "$TMP_ROOT/prior-bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_CALL_LOG"
case "$1" in
    ps)
        [ "$#" -eq 4 ] && [ "$3" = --filter ] || exit 99
        case "$4" in
            label=com.docker.compose.project=kvs-saved) echo saved-container ;;
            label=com.docker.compose.project=kvs-decoy) echo decoy-container ;;
            label=com.docker.compose.project=kvs-inherited) echo inherited-container ;;
            label=com.docker.compose.project=kvs) echo legacy-container ;;
        esac
        exit 0
        ;;
esac
case "$*" in
    'compose config --quiet'|'stop saved-container'|'rm saved-container'|'network rm kvs-saved_kvs-network'|\
    'stop decoy-container'|'rm decoy-container'|'network rm kvs-decoy_kvs-network'|\
    'stop inherited-container'|'rm inherited-container'|'network rm kvs-inherited_kvs-network') exit 0 ;;
esac
echo FORBIDDEN_DOCKER_CALL >> "$DOCKER_CALL_LOG"
exit 99
EOF
chmod +x "$TMP_ROOT/prior-bin/docker"
cat > "$TMP_ROOT/project-driver.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$PROJECT_TEST_ROOT/project-functions.sh"
RED='' GREEN='' YELLOW='' NC=''
check_mariadb_stop_grace_period() { :; }
check_cloudflare_configuration() { :; }
source "$PROJECT_TEST_ROOT/project-load.sh"
DOMAIN=$NEXT_DOMAIN
IMPORT_MODE=true
set_env_value DOMAIN "$DOMAIN"
export DOMAIN
source "$PROJECT_TEST_ROOT/project-retire.sh"
EOF

for project_form in plain quoted exported commented indented duplicate reference real_fake fake_only absent inherited empty legacy; do
    for domain_change in same changed; do
        case_dir="$TMP_ROOT/prior-$project_form-$domain_change"
        mkdir -p "$case_dir"
        printf 'DOMAIN=example.test\nSITE_PREFIX=kvs-saved\nMODE=single\n' > "$case_dir/.env"
        expected_project=kvs-saved
        case "$project_form" in
            plain|real_fake) echo 'COMPOSE_PROJECT_NAME=kvs-saved' >> "$case_dir/.env" ;;
            quoted) echo "COMPOSE_PROJECT_NAME='kvs-saved'" >> "$case_dir/.env" ;;
            exported) echo 'export COMPOSE_PROJECT_NAME=kvs-saved' >> "$case_dir/.env" ;;
            commented) echo 'COMPOSE_PROJECT_NAME=kvs-saved # saved project' >> "$case_dir/.env" ;;
            indented) echo '  COMPOSE_PROJECT_NAME=kvs-saved' >> "$case_dir/.env" ;;
            duplicate) printf 'COMPOSE_PROJECT_NAME=kvs-decoy\nexport COMPOSE_PROJECT_NAME=kvs-saved\n' >> "$case_dir/.env" ;;
            reference)
                # shellcheck disable=SC2016  # Expanded only when setup loads the fixture.
                printf 'PROJECT_SEED=kvs-saved\nCOMPOSE_PROJECT_NAME="${PROJECT_SEED}"\n' >> "$case_dir/.env" ;;
            fake_only|absent|inherited) expected_project='' ;;
            empty) echo "COMPOSE_PROJECT_NAME=''" >> "$case_dir/.env"; expected_project='' ;;
            legacy) echo 'COMPOSE_PROJECT_NAME=kvs' >> "$case_dir/.env"; expected_project='' ;;
        esac
        case "$project_form" in
            real_fake|fake_only) printf '%s\n' 'KEEP="first' 'COMPOSE_PROJECT_NAME=kvs-decoy' 'last"' >> "$case_dir/.env" ;;
        esac
        chmod 600 "$case_dir/.env"
        next_domain=example.test
        [ "$domain_change" = same ] || next_domain=other.test
        (
            cd "$case_dir"
            unset COMPOSE_PROJECT_NAME
            [ "$project_form" != inherited ] || export COMPOSE_PROJECT_NAME=kvs-inherited
            PATH="$TMP_ROOT/prior-bin:$PATH" DOCKER_CALL_LOG="$case_dir/calls" PROJECT_TEST_ROOT="$TMP_ROOT" NEXT_DOMAIN="$next_domain" \
                bash "$TMP_ROOT/project-driver.sh"
        ) > "$case_dir/output" 2>&1 || fail "$project_form/$domain_change failed: $(cat "$case_dir/output")"
        : > "$case_dir/expected-calls"
        if [ "$domain_change" = changed ] && [ -n "$expected_project" ]; then
            printf '%s\n' 'ps -aq --filter label=com.docker.compose.project=kvs-saved' 'compose config --quiet' \
                'ps -q --filter label=com.docker.compose.project=kvs-saved' 'stop saved-container' \
                'ps -aq --filter label=com.docker.compose.project=kvs-saved' 'rm saved-container' \
                'network rm kvs-saved_kvs-network' > "$case_dir/expected-calls"
        fi
        [ -f "$case_dir/calls" ] || : > "$case_dir/calls"
        cmp -s "$case_dir/calls" "$case_dir/expected-calls" || fail "$project_form/$domain_change selected the wrong project: $(cat "$case_dir/calls")"
        [ "$(stat -c %a "$case_dir/.env")" = 600 ] || fail 'the saved file mode changed'
    done
done
echo 'ok 3 - changed-domain imports select the parsed saved project and exclude inherited-only or multiline lookalikes'

# A setup run exports the selected project before it inspects resources.
# Read the saved settings in a fresh process too: that export must not hide
# an older duplicate, a missing assignment, or damage to another value.
for prefix_path in choose normalize; do
    for project_form in plain quoted exported indented commented duplicate reference real_fake export_fake fake_only absent inherited shared_export; do
        case_dir="$TMP_ROOT/persist-$prefix_path-$project_form"
        work_dir="$case_dir/docker"
        mock_bin="$case_dir/bin"
        mkdir -p "$work_dir" "$case_dir/logs"
        saved_prefix=scope-target
        expected_project=scope-target
        if [ "$prefix_path" = choose ]; then saved_prefix=kvs; expected_project=kvs-mysite; fi
        sed -e 's/^DOMAIN=.*/DOMAIN=mysite.test/' -e "s/^SITE_PREFIX=.*/SITE_PREFIX=$saved_prefix/" \
            -e '/^COMPOSE_PROJECT_NAME=/d' "$REPO_ROOT/docker/.env.example" > "$work_dir/.env"
        printf '\nEXTRA=preserved\n' >> "$work_dir/.env"
        case "$project_form" in
            plain|real_fake) echo 'COMPOSE_PROJECT_NAME=kvs-old' >> "$work_dir/.env" ;;
            quoted) echo "COMPOSE_PROJECT_NAME='kvs-old'" >> "$work_dir/.env" ;;
            exported|export_fake) echo 'export COMPOSE_PROJECT_NAME=kvs-old' >> "$work_dir/.env" ;;
            indented) echo '  COMPOSE_PROJECT_NAME=kvs-old' >> "$work_dir/.env" ;;
            commented) echo 'COMPOSE_PROJECT_NAME=kvs-old # saved project' >> "$work_dir/.env" ;;
            duplicate) printf 'COMPOSE_PROJECT_NAME=kvs-decoy\nexport COMPOSE_PROJECT_NAME=kvs-old\n' >> "$work_dir/.env" ;;
            reference)
                # shellcheck disable=SC2016  # Expanded by the real setup loader.
                printf 'PROJECT_SEED=kvs-old\nCOMPOSE_PROJECT_NAME="${PROJECT_SEED}"\n' >> "$work_dir/.env" ;;
            shared_export) echo 'export COMPOSE_PROJECT_NAME="kvs-old" RELATED="preserved"' >> "$work_dir/.env" ;;
        esac
        case "$project_form" in
            real_fake|export_fake|fake_only) printf '%s\n' 'KEEP="first' 'COMPOSE_PROJECT_NAME=kvs-decoy' 'last"' >> "$work_dir/.env" ;;
        esac
        make_setup_copy "$case_dir/setup.sh" "$case_dir/logs"
        make_mocks "$mock_bin"
        status=0
        project_environment=()
        [ "$project_form" != inherited ] || project_environment=(COMPOSE_PROJECT_NAME=kvs-inherited)
        (
            cd "$work_dir"
            env -u COMPOSE_PROJECT_NAME "${project_environment[@]}" \
                PATH="$mock_bin:/usr/bin:/bin" DOCKER_CALL_LOG="$case_dir/docker-calls" \
                EXPECTED_PROJECT="$expected_project" INCLUDE_CURRENT_PROJECT=false \
                HEADLESS=y PREFLIGHT_BYPASS=y PREFIX_CHOICE=1 SSL_CHOICE=3 \
                "$case_dir/setup.sh"
        ) > "$case_dir/output" 2>&1 || status=$?
        [ "$status" -ne 0 ] || fail 'the fixture must stop before building, with no KVS archive'
        assert_file_contains "$case_dir/output" 'No KVS archive found in ./kvs-archive/'
        assert_file_contains "$case_dir/docker-calls" "ps -aq --filter label=com.docker.compose.project=$expected_project"
        assert_file_contains "$case_dir/docker-calls" "volume ls -q --filter label=com.docker.compose.project=$expected_project"
        (
            cd "$work_dir"
            # shellcheck disable=SC2016  # Read saved values in the fresh child shell.
            env -u COMPOSE_PROJECT_NAME -u KEEP -u RELATED \
                EXPECTED_PROJECT="$expected_project" PROJECT_FORM="$project_form" bash -c '
                set -eu
                source .env
                [ "${COMPOSE_PROJECT_NAME-}" = "$EXPECTED_PROJECT" ]
                [ "$SITE_PREFIX" = "$EXPECTED_PROJECT" ]
                [ "$EXTRA" = preserved ]
                case "$PROJECT_FORM" in
                    real_fake|export_fake|fake_only)
                        expected_keep=$(printf "%s\n" first COMPOSE_PROJECT_NAME=kvs-decoy last)
                        [ "$KEEP" = "$expected_keep" ] ;;
                    shared_export) [ "$RELATED" = preserved ] ;;
                esac
            '
        ) || fail "$prefix_path/$project_form did not preserve the saved project and unrelated values"
        [ "$(stat -c %a "$work_dir/.env")" = 600 ] || fail 'project persistence changed file permissions'
    done
done
echo 'ok 4 - selected and normalized projects survive a fresh load without changing unrelated values'
