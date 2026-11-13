#!/bin/bash
# D1: a re-run must not overwrite the prefix, SSL provider or cache a previous
# run saved in .env, and a fresh install must still get the generated
# kvs-<domain> prefix. SITE_PREFIX=kvs is both the legacy prefix (option 2) and
# the placeholder .env.example ships: it is a saved choice when .env records it
# (SITE_PREFIX_LEGACY=yes) or when that .env has been through a setup already,
# and a placeholder otherwise or when a new selection is pending
# (SITE_PREFIX_RESELECT=yes, written by a retirement for a new domain). A
# silent change of SITE_PREFIX renames the Compose project and orphans the old
# database, so the prefix cases are the severe ones.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/kvs-setup-headless-choices.XXXXXX)

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

# env_value <file> <key>: the value of key, written plain or exported.
env_value() {
    sed -n -E "s/^(export[[:space:]]+)?${2}=//p" "$1" | head -n 1
}

assert_env() {
    local file="$1" key="$2" want="$3" got
    got=$(env_value "$file" "$key")
    [ "$got" = "$want" ] || fail "${CASE}: ${key}: expected '${want}', got '${got}'"
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

# A legacy, self-signed, Memcached site as an earlier setup left it: its
# MariaDB passwords were generated, and the cache line is exported, which
# set_env_value keeps as it is.
make_installed_env() {
    local env_file="$1"
    cp "$REPO_ROOT/docker/.env.example" "$env_file"
    sed -i \
        -e 's/^DOMAIN=.*/DOMAIN=mysite.test/' \
        -e 's/^SITE_PREFIX=.*/SITE_PREFIX=kvs/' \
        -e 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=kvs/' \
        -e 's/^SSL_PROVIDER=.*/SSL_PROVIDER=selfsigned/' \
        -e 's/^COMPOSE_PROFILES=.*/export COMPOSE_PROFILES=memcached/' \
        -e 's/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=Generated1/' \
        -e 's/^MARIADB_PASSWORD=.*/MARIADB_PASSWORD=Generated2/' \
        "$env_file"
}

# run_case <name> <headless|interactive> <answers> <prepare function|none>
# Runs the setup copy with no *_CHOICE. A KVS archive, the base resolver and
# the lock let the run reach the cache selection; it then stops at the first
# runtime helper the fixture does not provide (or, interactively, at the
# email question once the answers run out), after the prefix and SSL
# selections have run. The timeout guards against a future hang.
run_case() {
    local name="$1" mode="$2" answers="$3" prepare="$4" status
    CASE=$name
    CASE_DIR="$TMP_ROOT/$name"
    WORK_DIR="$CASE_DIR/docker"
    mkdir -p "$WORK_DIR/kvs-archive" "$CASE_DIR/bin" "$CASE_DIR/logs"
    cp "$REPO_ROOT/docker/.env.example" "$WORK_DIR/.env.example"
    [ "$prepare" = none ] || "$prepare" "$WORK_DIR/.env"
    make_setup_copy "$CASE_DIR/setup.sh" "$CASE_DIR/logs"
    make_mocks "$CASE_DIR/bin"
    # set_php_bases resolves the PHP base next to the script; resolve-bases.sh
    # reads the lock one directory up from itself.
    cp "$REPO_ROOT/docker/bin/resolve-bases.sh" "$CASE_DIR/bin/"
    cp "$REPO_ROOT/docker/images.lock" "$CASE_DIR/"
    : > "$WORK_DIR/kvs-archive/KVS_7.0.2_mysite.test.zip"
    local -a headless=()
    if [ "$mode" = headless ]; then
        headless=(HEADLESS=y DOMAIN=mysite.test EMAIL=ops@mysite.test)
    else
        # gum would take over the prompts; the plain read path is the one
        # an operator's Enter reaches.
        rm "$CASE_DIR/bin/gum"
    fi
    set +e
    printf '%b' "$answers" | timeout 120 env -C "$WORK_DIR" \
        -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES -u SITE_PREFIX -u SSL_PROVIDER \
        -u CACHE_CHOICE -u PREFIX_CHOICE -u SSL_CHOICE -u HEADLESS \
        -u SITE_PREFIX_LEGACY -u SITE_PREFIX_RESELECT \
        PATH="$CASE_DIR/bin:/usr/bin:/bin" \
        PREFLIGHT_BYPASS=y \
        GEOIP_CHOICE=2 \
        "${headless[@]}" \
        "$CASE_DIR/setup.sh" > "$CASE_DIR/output.log" 2>&1
    status=$?
    set -e
    [ "$status" -ne 124 ] || fail "${name}: setup hung (timeout) instead of running the selections"
    ENV_FILE="$WORK_DIR/.env"
    # The run must reach past the SSL selection, or the .env checks are vacuous.
    grep -Fq "SSL Certificate Provider" "$CASE_DIR/output.log" ||
        fail "${name}: setup did not reach the SSL selection: $(tail -n 3 "$CASE_DIR/output.log")"
}

# 1. A fresh headless install: .env is copied from .env.example, whose kvs is
# the placeholder, so the generated prefix is used as documented.
run_case fresh-headless headless '' none
assert_env "$ENV_FILE" SITE_PREFIX kvs-mysite
assert_env "$ENV_FILE" COMPOSE_PROJECT_NAME kvs-mysite
assert_env "$ENV_FILE" SITE_PREFIX_LEGACY ''
echo "ok 1 - a fresh headless install gets the generated kvs-<domain> prefix"

# 2. A headless re-run over an installed legacy site keeps every saved choice.
run_case installed-headless headless '' make_installed_env
grep -Fq "Cache Server" "$CASE_DIR/output.log" ||
    fail "${CASE}: setup did not reach the cache selection: $(tail -n 3 "$CASE_DIR/output.log")"
assert_env "$ENV_FILE" SITE_PREFIX kvs
assert_env "$ENV_FILE" COMPOSE_PROJECT_NAME kvs
assert_env "$ENV_FILE" SSL_PROVIDER selfsigned
assert_env "$ENV_FILE" COMPOSE_PROFILES memcached
assert_env "$ENV_FILE" SITE_PREFIX_LEGACY yes
echo "ok 2 - a headless re-run keeps the saved legacy prefix, self-signed SSL and an exported Memcached profile"

# 3. An interactive re-run of the same site answered with Enter: the prefix
# question is not asked again, so Enter cannot rename the project.
run_case installed-interactive interactive '\n\n\n\n\n\n' make_installed_env
assert_env "$ENV_FILE" SITE_PREFIX kvs
assert_env "$ENV_FILE" COMPOSE_PROJECT_NAME kvs
if sed 's/\x1b\[[0-9;]*m//g' "$CASE_DIR/output.log" | grep -Fq 'Select [1-3] (default: 1)'; then
    fail "${CASE}: the prefix question was asked again for a saved legacy prefix"
fi
echo "ok 3 - an interactive re-run does not offer to rename a saved legacy prefix"

# 4. Option 2 chosen on a fresh install is recorded at once, before the
# MariaDB passwords exist, so a run stopped right after it keeps kvs. The
# .env is the one kvs-install.sh prepares: .env.example with the domain.
make_fresh_env() {
    cp "$REPO_ROOT/docker/.env.example" "$1"
    sed -i 's/^DOMAIN=.*/DOMAIN=mysite.test/' "$1"
}
run_case legacy-chosen interactive '\n2\n\n\n\n\n' make_fresh_env
assert_env "$ENV_FILE" SITE_PREFIX kvs
assert_env "$ENV_FILE" SITE_PREFIX_LEGACY yes
legacy_env="$TMP_ROOT/legacy-chosen.env"
cp "$ENV_FILE" "$legacy_env"
copy_legacy_env() { cp "$legacy_env" "$1"; }
run_case legacy-chosen-rerun headless '' copy_legacy_env
assert_env "$ENV_FILE" SITE_PREFIX kvs
assert_env "$ENV_FILE" COMPOSE_PROJECT_NAME kvs
echo "ok 4 - the legacy option is saved when chosen and kept by the next headless run"

# 5. A selection left pending by a retirement for a new domain survives an
# interrupted run: the next headless run generates the prefix and clears the
# signal, and an earlier legacy record does not count any more.
make_pending_env() {
    make_installed_env "$1"
    printf 'SITE_PREFIX_LEGACY=yes\nSITE_PREFIX_RESELECT=yes\n' >> "$1"
}
run_case pending-reselect headless '' make_pending_env
assert_env "$ENV_FILE" SITE_PREFIX kvs-mysite
assert_env "$ENV_FILE" COMPOSE_PROJECT_NAME kvs-mysite
assert_env "$ENV_FILE" SITE_PREFIX_RESELECT ''
assert_env "$ENV_FILE" SITE_PREFIX_LEGACY ''
echo "ok 5 - a pending reselection from a retirement generates a fresh prefix and is cleared"

# 6. The retirement for a new domain records the pending selection in .env
# (case 5 starts from that state) and drops the legacy record.
CASE=request-selection
unit_dir="$TMP_ROOT/$CASE"
mkdir -p "$unit_dir"
for function_name in remove_env_value set_env_value retirement_request_prefix_selection; do
    sed -n "/^${function_name}() {/,/^}/p" "$REPO_ROOT/docker/setup.sh"
done > "$unit_dir/functions.sh"
grep -q '^retirement_request_prefix_selection() {' "$unit_dir/functions.sh" ||
    fail "${CASE}: retirement_request_prefix_selection is missing from setup.sh"
printf 'DOMAIN=new.test\nSITE_PREFIX=kvs-old\nSITE_PREFIX_LEGACY=yes\nMARIADB_PASSWORD=Generated2\n' > "$unit_dir/.env"
(
    cd "$unit_dir"
    # shellcheck disable=SC1091
    source ./functions.sh
    retirement_request_prefix_selection
) || fail "${CASE}: retirement_request_prefix_selection failed"
assert_env "$unit_dir/.env" SITE_PREFIX kvs
assert_env "$unit_dir/.env" SITE_PREFIX_RESELECT yes
assert_env "$unit_dir/.env" SITE_PREFIX_LEGACY ''
echo "ok 6 - a retirement for a new domain saves the pending prefix selection"

echo "PASS: setup keeps saved prefix, SSL and cache choices and still names a fresh install"
