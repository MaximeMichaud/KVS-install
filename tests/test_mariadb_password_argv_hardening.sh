#!/bin/bash
# Mock commands and sourced helpers are intentionally invoked dynamically.
# shellcheck disable=SC2034,SC2329
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
SECRET='test-only-mariadb-argv-secret'
ROOT_SECRET='setupRootArgvSecret123'
KVS_SECRET='setupKvsArgvSecret456'

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_secret_is_not_an_argument() {
    local log_file="$1"
    local secret="$2"
    local context="$3"
    local line

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            argument=*)
                [[ "${line#argument=}" != *"$secret"* ]] || fail "$context"
                ;;
        esac
    done < "$log_file"
}

extract_function() {
    local function_name="$1"
    local source_file="$2"

    awk -v declaration="${function_name}() {" '
        $0 == declaration { copying = 1 }
        copying { print }
        copying && $0 == "}" { exit }
    ' "$source_file"
}

count_env_line() {
    local env_file="$1"
    local key="$2"
    local value="$3"
    local line
    local count=0

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "${key}=${value}" ]; then
            count=$((count + 1))
        fi
    done < "$env_file"
    printf '%s\n' "$count"
}

production_files=(
    "$ROOT_DIR/docker/setup.sh"
    "$ROOT_DIR/docker/init/lib/common.sh"
    "$ROOT_DIR"/docker/init/docker-entrypoint.d/*.sh
    "$ROOT_DIR/docker/manticore/docker-entrypoint.sh"
    "$ROOT_DIR/docker/multi-site/site-manager.sh"
)

# Keep the variable reference literal because this scans shell source code.
# shellcheck disable=SC2016
if grep -nF -- '-p"$MARIADB' "${production_files[@]}"; then
    fail "a MariaDB command still passes a password through -p"
fi

common_log="$TEST_DIR/common.log"
(
    mariadb() {
        printf 'password=%s\n' "${MYSQL_PWD:-<unset>}" >> "$common_log"
        printf 'argument=%s\n' "$@" >> "$common_log"
    }

    DOMAIN=example.com
    MARIADB_PASSWORD="$SECRET"
    USE_WWW=false
    # shellcheck disable=SC1090,SC1091
    source "$ROOT_DIR/docker/init/lib/common.sh"

    db_exec 'SELECT 1'
    db_query 'SELECT 2'
    db_is_ready
)

[ "$(count_env_line "$common_log" password "$SECRET")" -eq 3 ] ||
    fail "not all shared database helpers authenticated through MYSQL_PWD"
assert_secret_is_not_an_argument "$common_log" "$SECRET" \
    "the shared MariaDB password was exposed through process arguments"

settings_script="$TEST_DIR/70-system-settings.sh"
sed "s|source /init/lib/common.sh|source $ROOT_DIR/docker/init/lib/common.sh|" \
    "$ROOT_DIR/docker/init/docker-entrypoint.d/70-system-settings.sh" \
    > "$settings_script"
chmod +x "$settings_script"

settings_log="$TEST_DIR/settings.log"
export settings_log
mariadb() {
    printf 'password=%s\n' "${MYSQL_PWD:-<unset>}" >> "$settings_log"
    printf 'argument=%s\n' "$@" >> "$settings_log"
    cat >/dev/null
}
export -f mariadb

DOMAIN=example.com \
MARIADB_PASSWORD="$SECRET" \
    bash "$settings_script" >/dev/null

[ "$(count_env_line "$settings_log" password "$SECRET")" -eq 1 ] ||
    fail "the system settings update did not authenticate through MYSQL_PWD"
assert_secret_is_not_an_argument "$settings_log" "$SECRET" \
    "the settings MariaDB password was exposed through process arguments"

# setup.sh must rely on the container environment for root authentication. The
# helper's Docker and MariaDB argv are captured independently.
setup_root_helper="$TEST_DIR/setup-root-helper.sh"
extract_function run_root_mariadb "$ROOT_DIR/docker/setup.sh" > \
    "$setup_root_helper"
[ -s "$setup_root_helper" ] || fail "could not extract run_root_mariadb"

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/mariadb" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'password=%s\n' "${MYSQL_PWD:-<unset>}" >> "${SETUP_ROOT_LOG:?}"
printf 'command=mariadb\n' >> "$SETUP_ROOT_LOG"
printf 'argument=%s\n' "$@" >> "$SETUP_ROOT_LOG"
EOF
chmod +x "$TEST_DIR/bin/mariadb"

setup_root_log="$TEST_DIR/setup-root.log"
(
    export PATH="$TEST_DIR/bin:$PATH"
    export SETUP_ROOT_LOG="$setup_root_log"
    export MARIADB_ROOT_PASSWORD="$ROOT_SECRET"

    docker() {
        local script

        printf 'command=docker\n' >> "$SETUP_ROOT_LOG"
        printf 'argument=%s\n' "$@" >> "$SETUP_ROOT_LOG"
        [ "$#" -ge 8 ] && [ "$1" = compose ] && [ "$2" = exec ] &&
            [ "$3" = -T ] && [ "$4" = mariadb ] && [ "$5" = sh ] &&
            [ "$6" = -c ] || return 97
        script="$7"
        shift 7
        command sh -c "$script" "$@"
    }

    # shellcheck disable=SC1090
    source "$setup_root_helper"
    run_root_mariadb -u root -e 'SELECT 1'
)

[ "$(count_env_line "$setup_root_log" password "$ROOT_SECRET")" -eq 1 ] ||
    fail "setup root helper did not authenticate through MYSQL_PWD"
assert_secret_is_not_an_argument "$setup_root_log" "$ROOT_SECRET" \
    "the setup root password was exposed through process arguments"
if grep -Eq '^argument=-p' "$setup_root_log"; then
    fail "the setup root helper used a MariaDB -p argument"
fi

# Persist both generated passwords through the atomic helper while recording
# every external command argument. Values may only flow through shell builtins
# and file contents, never sed, grep, or another external argv.
setup_env_helper="$TEST_DIR/setup-env-helper.sh"
extract_function set_env_value "$ROOT_DIR/docker/setup.sh" > \
    "$setup_env_helper"
[ -s "$setup_env_helper" ] || fail "could not extract set_env_value"

setup_env_dir="$TEST_DIR/setup-env"
mkdir -p "$setup_env_dir"
cat > "$setup_env_dir/.env" <<'EOF'
DOMAIN=example.com
MARIADB_ROOT_PASSWORD=CHANGE_ME_ROOT_PASSWORD
MARIADB_PASSWORD=CHANGE_ME_KVS_PASSWORD
EOF

external_log="$TEST_DIR/setup-env-external.log"
(
    cd "$setup_env_dir"
    export EXTERNAL_ARG_LOG="$external_log"

    trace_external() {
        local command_name="$1"
        shift

        printf 'command=%s\n' "$command_name" >> "$EXTERNAL_ARG_LOG"
        printf 'argument=%s\n' "$@" >> "$EXTERNAL_ARG_LOG"
    }

    stat() { trace_external stat "$@"; command stat "$@"; }
    mktemp() { trace_external mktemp "$@"; command mktemp "$@"; }
    sed() { trace_external sed "$@"; command sed "$@"; }
    chmod() { trace_external chmod "$@"; command chmod "$@"; }
    chown() { trace_external chown "$@"; command chown "$@"; }
    mv() { trace_external mv "$@"; command mv "$@"; }
    rm() { trace_external rm "$@"; command rm "$@"; }
    grep() { trace_external grep "$@"; command grep "$@"; }

    # shellcheck disable=SC1090
    source "$setup_env_helper"
    set_env_value MARIADB_ROOT_PASSWORD "$ROOT_SECRET"
    set_env_value MARIADB_PASSWORD "$KVS_SECRET"
)

[ "$(count_env_line "$setup_env_dir/.env" MARIADB_ROOT_PASSWORD \
    "$ROOT_SECRET")" -eq 1 ] ||
    fail "the root password was not persisted exactly once"
[ "$(count_env_line "$setup_env_dir/.env" MARIADB_PASSWORD \
    "$KVS_SECRET")" -eq 1 ] ||
    fail "the KVS password was not persisted exactly once"
assert_secret_is_not_an_argument "$external_log" "$ROOT_SECRET" \
    "the persisted root password leaked into an external command argument"
assert_secret_is_not_an_argument "$external_log" "$KVS_SECRET" \
    "the persisted KVS password leaked into an external command argument"
[ "$(grep -c '^command=sed$' "$external_log")" -eq 2 ] ||
    fail "set_env_value did not perform one bounded sed filter per password"
if grep -Eq '^command=grep$' "$external_log"; then
    fail "set_env_value unexpectedly delegated value verification to grep"
fi
[ "$(stat -c '%a' "$setup_env_dir/.env")" = 600 ] ||
    fail "the atomically persisted .env mode is not 0600"
if compgen -G "$setup_env_dir/.env.tmp.*" >/dev/null; then
    fail "set_env_value left a temporary file behind"
fi

# Keep these literal references static so a future call-site regression is
# caught without placing either runtime password in a command argument.
# shellcheck disable=SC2016
grep -Fq 'set_env_value MARIADB_ROOT_PASSWORD "$MARIADB_ROOT_PASSWORD"' \
    "$ROOT_DIR/docker/setup.sh" ||
    fail "setup.sh does not persist the generated root password atomically"
# shellcheck disable=SC2016
grep -Fq 'set_env_value MARIADB_PASSWORD "$MARIADB_PASSWORD"' \
    "$ROOT_DIR/docker/setup.sh" ||
    fail "setup.sh does not persist the generated KVS password atomically"

echo "PASS: MariaDB password argument hardening"
