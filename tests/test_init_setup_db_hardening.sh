#!/bin/bash
# The init rewrites admin/include/setup_db.php for the MariaDB container.
# Owners write that file by hand, KVS ships no installer for it, so the
# comma before each value carries whatever spacing they typed. Every define
# must reach the container's values, in the spaced form as in the compact
# one, and a define the rewrite cannot reach must stop the init instead of
# leaving the imported site on the old server's database.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-init-setup-db.XXXXXX)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cat > "$TEST_DIR/common.sh" <<'EOF'
KVS_PATH=${TEST_KVS_PATH:?}
log_info() { printf '[INFO] %s\n' "$1"; }
log_warn() { printf '[WARN] %s\n' "$1"; }
log_error() { printf '[ERROR] %s\n' "$1" >&2; }
get_project_url() { printf 'https://%s\n' "$DOMAIN"; }
EOF
sed "s|source /init/lib/common.sh|source ${TEST_DIR}/common.sh|" \
    "$ROOT_DIR/docker/init/docker-entrypoint.d/10-config-php.sh" > "$TEST_DIR/10-config-php.sh"

# The value of a define as PHP reads it: the text between the quotes.
define_value() {
    sed -n -E "s/^define\\('$2',[[:space:]]*'(([^'\\\\]|\\\\.)*)'\\);.*/\\1/p" "$1" | head -n 1
}

run_config() {
    local site="$1"

    TEST_KVS_PATH="$site" DOMAIN=example.com MARIADB_PASSWORD="it's a #pass&word" USE_WWW=false \
        bash "$TEST_DIR/10-config-php.sh"
}

# --- a hand-written file, one space after every comma ---------------------
site="$TEST_DIR/spaced"
mkdir -p "$site/admin/include"
cat > "$site/admin/include/setup_db.php" <<'EOF'
<?php
define('DB_HOST', '127.0.0.1:3306');
define('DB_LOGIN', 'old_user');
define('DB_PASS', 'old-password');
define('DB_DEVICE', 'old_database');
EOF
run_config "$site" > "$TEST_DIR/spaced.log" 2>&1 || fail "the rewrite of a spaced setup_db.php must succeed"
setup_db="$site/admin/include/setup_db.php"
[ "$(define_value "$setup_db" DB_HOST)" = mariadb ] ||
    fail "DB_HOST must point at the mariadb container (got '$(define_value "$setup_db" DB_HOST)')"
[ "$(define_value "$setup_db" DB_LOGIN)" = example.com ] ||
    fail "DB_LOGIN must be the site's database user (got '$(define_value "$setup_db" DB_LOGIN)')"
[ "$(define_value "$setup_db" DB_DEVICE)" = example.com ] ||
    fail "DB_DEVICE must be the site's database (got '$(define_value "$setup_db" DB_DEVICE)')"
[ "$(define_value "$setup_db" DB_PASS)" = "it\\'s a #pass&word" ] ||
    fail "DB_PASS must carry the container password (got '$(define_value "$setup_db" DB_PASS)')"
grep -Fq 'Database configured: mariadb/example.com' "$TEST_DIR/spaced.log" ||
    fail "the rewrite must be announced"

# --- the compact form KVS documents keeps working, twice ------------------
site="$TEST_DIR/compact"
mkdir -p "$site/admin/include"
cat > "$site/admin/include/setup_db.php" <<'EOF'
<?php
define('DB_HOST','localhost');
define('DB_LOGIN','old_user');
define('DB_PASS','old-password');
define('DB_DEVICE','old_database');
EOF
run_config "$site" > /dev/null 2>&1 || fail "the rewrite of a compact setup_db.php must succeed"
run_config "$site" > /dev/null 2>&1 || fail "the rewrite must be repeatable"
setup_db="$site/admin/include/setup_db.php"
grep -Fxq "define('DB_HOST','mariadb');" "$setup_db" || fail "compact DB_HOST was not rewritten"
grep -Fxq "define('DB_LOGIN','example.com');" "$setup_db" || fail "compact DB_LOGIN was not rewritten"
grep -Fxq "define('DB_DEVICE','example.com');" "$setup_db" || fail "compact DB_DEVICE was not rewritten"
[ "$(define_value "$setup_db" DB_PASS)" = "it\\'s a #pass&word" ] || fail "compact DB_PASS was not rewritten"
[ "$(stat -c '%a' "$setup_db")" = 600 ] || fail "setup_db.php must stay private"

# --- a define the rewrite cannot reach stops the init ----------------------
site="$TEST_DIR/unreachable"
mkdir -p "$site/admin/include"
cat > "$site/admin/include/setup_db.php" <<'EOF'
<?php
$host = 'localhost';
define('DB_HOST', $host);
define('DB_LOGIN', 'old_user');
define('DB_PASS', 'old-password');
define('DB_DEVICE', 'old_database');
EOF
if run_config "$site" > "$TEST_DIR/unreachable.log" 2>&1; then
    fail "a DB_HOST the rewrite cannot reach must stop the init"
fi
grep -Fq 'does not define DB_HOST' "$TEST_DIR/unreachable.log" ||
    fail "the unreachable define must be named"

echo "PASS: setup_db.php rewrite reaches hand-written defines"
