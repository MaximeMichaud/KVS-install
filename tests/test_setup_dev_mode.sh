#!/bin/bash
# D9: ./setup.sh --dev runs headless, and used to export DOMAIN=example.com
# and EMAIL=dev@localhost.local before the environment overrides were
# captured. The placeholder domain then replaced the one saved in .env and
# the headless domain check refused it, so --dev never got past it; the dev
# address replaced a saved one the same way. --dev now keeps what .env
# holds, an explicit DOMAIN or EMAIL still wins, the dev address only fills
# in where no real one was given or saved, and a first run without DOMAIN
# says how to give one.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kvs-setup-dev-mode.XXXXXX")

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# env_value <file> <key>: the value of key, written plain or exported.
env_value() {
    sed -n -E "s/^(export[[:space:]]+)?${2}=//p" "$1" | head -n 1
}

assert_env() {
    local key="$1" want="$2" got
    got=$(env_value "$WORK_DIR/.env" "$key")
    [ "$got" = "$want" ] || fail "${CASE}: ${key}: expected '${want}', got '${got}': $(tail -n 5 "$CASE_DIR/output.log")"
}

# An installed site: generated passwords, a real domain and address.
make_installed_env() {
    cp "$REPO_ROOT/docker/.env.example" "$1"
    sed -i \
        -e 's/^DOMAIN=.*/DOMAIN=mysite.test/' \
        -e 's/^EMAIL=.*/EMAIL=ops@mysite.test/' \
        -e 's/^SITE_PREFIX=.*/SITE_PREFIX=kvs-mysite/' \
        -e 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=kvs-mysite/' \
        -e 's/^SSL_PROVIDER=.*/SSL_PROVIDER=selfsigned/' \
        -e 's/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=Generated1/' \
        -e 's/^MARIADB_PASSWORD=.*/MARIADB_PASSWORD=Generated2/' \
        "$1"
}

# run_case <name> <prepare function|none> [VAR=value...]
# Runs a copy of docker/setup.sh with --dev and no DOMAIN or EMAIL unless
# given. Docker and the network are stubs; the run goes past the domain,
# email and MariaDB selections, then stops at the first runtime step the
# fixture does not provide. The timeout guards against a hang.
run_case() {
    local name="$1" prepare="$2"
    shift 2
    CASE=$name
    CASE_DIR="$TMP_ROOT/$name"
    WORK_DIR="$CASE_DIR/docker"
    mkdir -p "$WORK_DIR/kvs-archive" "$CASE_DIR/bin" "$CASE_DIR/logs"
    cp "$REPO_ROOT/docker/.env.example" "$WORK_DIR/.env.example"
    [ "$prepare" = none ] || "$prepare" "$WORK_DIR/.env"
    # Keep EUID literal while redirecting setup logs into the fixture.
    # shellcheck disable=SC2016
    sed \
        -e "s|/opt/kvs/logs|${CASE_DIR}/logs|g" \
        -e 's/if \[ "$EUID" -ne 0 \]; then/if false; then/' \
        "$REPO_ROOT/docker/setup.sh" > "$CASE_DIR/setup.sh"
    chmod +x "$CASE_DIR/setup.sh"
    cat > "$CASE_DIR/bin/docker" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then echo "Docker version 28.0.0, build test"; exit 0; fi
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then echo "Docker Compose version v2.35.0"; exit 0; fi
exit 0
EOF
    for tool in curl gum ss; do
        printf '#!/bin/bash\nexit 0\n' > "$CASE_DIR/bin/$tool"
    done
    chmod +x "$CASE_DIR/bin/"*
    cp "$REPO_ROOT/docker/bin/resolve-bases.sh" "$CASE_DIR/bin/"
    cp "$REPO_ROOT/docker/images.lock" "$CASE_DIR/"
    : > "$WORK_DIR/kvs-archive/KVS_7.0.2_mysite.test.zip"
    set +e
    timeout 120 env -C "$WORK_DIR" \
        -u DOMAIN -u EMAIL -u KVS_EMAIL -u HEADLESS -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES \
        -u SITE_PREFIX -u SSL_PROVIDER -u SSL_CHOICE -u CACHE_CHOICE -u PREFIX_CHOICE \
        PATH="$CASE_DIR/bin:/usr/bin:/bin" "$@" \
        "$CASE_DIR/setup.sh" --dev > "$CASE_DIR/output.log" 2>&1
    STATUS=$?
    set -e
}

# The run went past the domain and email checks to the MariaDB selection.
assert_past_domain_and_email() {
    if grep -q 'Set DOMAIN to a real domain\|Set EMAIL to a valid address\|Invalid domain format' "$CASE_DIR/output.log"; then
        fail "${CASE}: --dev stopped at the domain or email check: $(grep -m1 'ERROR' "$CASE_DIR/output.log")"
    fi
    grep -q 'Selected MariaDB' "$CASE_DIR/output.log" ||
        fail "${CASE}: --dev did not reach the MariaDB selection: $(tail -n 5 "$CASE_DIR/output.log")"
}

run_case saved-domain make_installed_env
assert_past_domain_and_email
assert_env DOMAIN mysite.test
assert_env EMAIL ops@mysite.test
echo 'PASS: --dev keeps the domain and email saved in .env'

# The dev-mode banner says what VOLUME_CHOICE=1 does to an installed site.
banner=$(tr -s ' \n' ' ' < "$CASE_DIR/output.log")
grep -Fq 'Stops existing containers and deletes the database volume of an existing installation (the site starts with an empty database)' <<< "$banner" ||
    fail "${CASE}: the dev-mode banner must say that the database volume of an existing installation is deleted: $(grep -m3 '•' "$CASE_DIR/output.log")"
grep -Fq 'Auto-cleanup' "$CASE_DIR/output.log" &&
    fail "${CASE}: the dev-mode banner must not hide the volume deletion behind Auto-cleanup"
echo 'PASS: the --dev banner says that the database volume of an existing installation is deleted'

run_case explicit-email make_installed_env EMAIL=dev2@mysite.test
assert_past_domain_and_email
assert_env DOMAIN mysite.test
assert_env EMAIL dev2@mysite.test
echo 'PASS: an explicit EMAIL still overrides the saved one under --dev'

run_case fresh-with-domain none DOMAIN=fresh.test
assert_past_domain_and_email
assert_env DOMAIN fresh.test
assert_env EMAIL dev@localhost.local
echo 'PASS: a first --dev run with DOMAIN gets the dev address in place of the placeholder'

# KVS_EMAIL, the legacy name kvs-install.sh documents, is the address the
# ACME check falls back to when EMAIL is empty or the placeholder. The dev
# address must not take its place.
run_case legacy-kvs-email none DOMAIN=fresh.test KVS_EMAIL=ops@mysite.test
assert_past_domain_and_email
assert_env DOMAIN fresh.test
assert_env EMAIL ops@mysite.test
echo 'PASS: a first --dev run keeps a legacy KVS_EMAIL instead of the dev address'

run_case fresh-without-domain none
[ "$STATUS" -ne 0 ] || fail "${CASE}: a first --dev run without DOMAIN must stop"
grep -q 'Set DOMAIN to a real domain' "$CASE_DIR/output.log" ||
    fail "${CASE}: the refusal must name DOMAIN: $(tail -n 5 "$CASE_DIR/output.log")"
grep -Fq 'DOMAIN=mysite.test ./setup.sh --dev' "$CASE_DIR/output.log" ||
    fail "${CASE}: the refusal must show how to give a domain to --dev: $(tail -n 5 "$CASE_DIR/output.log")"
echo 'PASS: a first --dev run without DOMAIN says how to give one'

# --dev answers VOLUME_CHOICE=1, so on an installed site it deletes the
# database volume. The help must say so plainly.
help=$(bash "$REPO_ROOT/docker/setup.sh" --help | tr -s ' \n' ' ') ||
    fail 'setup.sh --help failed'
grep -Fq -- '- Deletes the database volume of an existing installation: the site starts again with an empty database' <<< "$help" ||
    fail "--help must say that --dev deletes the database volume of an existing installation: $help"
grep -Fq 'On an installed site it deletes the # database volume and starts again with an empty database.' <<< "$help" ||
    fail "the --dev example must say that it deletes the database volume of an installed site: $help"
echo 'PASS: --help says that --dev deletes the database volume of an existing installation'
