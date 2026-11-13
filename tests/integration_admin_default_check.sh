#!/bin/bash
# Real-MariaDB proof that setup.sh and kvs-init agree on when the primary KVS
# admin account still holds the archive default password. setup.sh generates
# the one-time password only when setup_default_admin_login names an account;
# 35-harden-admin-users.sh then refuses to leave user_id 1 on the default.
# They used to ask different questions (setup also required login='admin'
# and read a query error as "no default"), so a renamed account, or a first
# run stopped before kvs-init seeded the database, got no password from setup
# and kvs-init stopped on "still uses the archive default credential".
#
# The real setup function and the real 35-harden script run against the
# MariaDB docker/images.lock pins for the default series, without network.
# It never pulls an image: run-integration.sh does.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SERIES=$(sed -n 's/^MARIADB_VERSION=//p' "$ROOT_DIR/docker/.env.example")
IMAGE=${MARIADB_TEST_IMAGE:-$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get mariadb "$SERIES")}
docker image inspect "$IMAGE" >/dev/null
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-admin-default.XXXXXX")
container="kvs-admin-default-$RANDOM-$$"
password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
DOMAIN=admin-default.example.com
TABLES_PREFIX=ktvs_
cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        docker logs --tail 20 "$container" >&2 2>/dev/null || true
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

docker run -d --name "$container" --network none --memory 1g \
    -e MARIADB_ROOT_PASSWORD="$password" -e MARIADB_DATABASE="$DOMAIN" \
    "$IMAGE" >/dev/null
ready=no
for _ in $(seq 1 90); do
    if docker exec "$container" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
        ready=yes
        break
    fi
    sleep 1
done
[ "$ready" = yes ] || fail "MariaDB did not start"

sql() {
    docker exec -i -e MYSQL_PWD="$password" "$container" mariadb -uroot -N "$DOMAIN" -e "$1"
}

# What setup.sh runs, with its compose exec replaced by the test container.
run_root_mariadb() {
    docker exec -i -e MYSQL_PWD="$password" "$container" mariadb "$@" </dev/null
}
eval "$(sed -n '/^setup_default_admin_login() {/,/^}/p' "$ROOT_DIR/docker/setup.sh")"
declare -F setup_default_admin_login >/dev/null || fail "setup.sh has no setup_default_admin_login"

# The real 35-harden script, with the init library replaced by one that
# talks to the test container.
mkdir -p "$TEST_DIR/www/admin/data/system"
cat > "$TEST_DIR/common.sh" <<EOF
KVS_PATH="$TEST_DIR/www"
log_info() { printf '[INFO] %s\n' "\$1"; }
log_warn() { printf '[WARN] %s\n' "\$1"; }
log_error() { printf '[ERROR] %s\n' "\$1" >&2; }
get_tables_prefix() { printf '%s\n' "$TABLES_PREFIX"; }
db_query() { docker exec -i -e MYSQL_PWD="$password" "$container" mariadb -uroot -N -s "$DOMAIN" -e "\$1"; }
db_exec() { docker exec -i -e MYSQL_PWD="$password" "$container" mariadb -uroot "$DOMAIN" -e "\$1"; }
EOF
sed "s|source /init/lib/common.sh|source $TEST_DIR/common.sh|" \
    "$ROOT_DIR/docker/init/docker-entrypoint.d/35-harden-admin-users.sh" > "$TEST_DIR/harden.sh"
harden() {
    printf '{"admins":[{"id":"1","hash":"seed"}]}' > "$TEST_DIR/www/admin/data/system/ap.dat"
    KVS_ADMIN_PASSWORD="$1" DISABLE_KVS_SUPPORT_ACCESS=false \
        bash "$TEST_DIR/harden.sh" > "$TEST_DIR/harden.log" 2>&1
}

# The seed's table, as install_db.sql creates it for these columns.
seed_table() {
    sql "DROP TABLE IF EXISTS ${TABLES_PREFIX}admin_users;
        CREATE TABLE ${TABLES_PREFIX}admin_users (user_id INT PRIMARY KEY, login VARCHAR(100) NOT NULL,
            pass VARCHAR(32) NOT NULL, last_session_id VARCHAR(32) NOT NULL DEFAULT '');
        INSERT INTO ${TABLES_PREFIX}admin_users (user_id, login, pass) VALUES ($1, '$2', $3);"
}
DEFAULT_PASS="MD5(CONCAT('pass:',MD5('123')))"
OTHER_PASS="MD5(CONCAT('pass:',MD5('an-owner-chosen-password')))"
generated=test-only-generated-admin-password

# The query site-manager.sh start runs for the same decision. The pattern
# matches the script's literal ${TABLES_PREFIX}, so it stays unexpanded.
# shellcheck disable=SC2016
site_manager_query=$(grep -o 'SELECT login FROM ${TABLES_PREFIX}admin_users WHERE [^;]*;' \
    "$ROOT_DIR/docker/multi-site/site-manager.sh" | head -n 1 | sed "s/\\\\\"/'/g; s/\${TABLES_PREFIX}/$TABLES_PREFIX/")
[ -n "$site_manager_query" ] || fail "site-manager.sh has no default admin query"

# 1. Tables under another prefix only: kvs-init does not seed a database that
# has tables, so there is nothing setup may plan a password for. Reading the
# missing table as "will be seeded" would replace that hardened password
# whenever setup and kvs-init disagree on the prefix.
sql "CREATE TABLE kvs_admin_users (user_id INT PRIMARY KEY, login VARCHAR(100) NOT NULL, pass VARCHAR(32) NOT NULL);
    INSERT INTO kvs_admin_users VALUES (1, 'boss', $OTHER_PASS);"
if login=$(setup_default_admin_login 2>/dev/null); then
    fail "tables without the ${TABLES_PREFIX}admin_users table: setup went on (planned '$login')"
fi
sql "DROP TABLE kvs_admin_users;"
echo "PASS: a database with tables but no admin table under the prefix stops the check"

# 2. A first run stopped before kvs-init: the database has no table yet and
# kvs-init seeds it. setup must plan a password for the seed's admin account,
# which kvs-init then applies.
login=$(setup_default_admin_login) || fail "empty database: the check failed instead of planning a password"
[ "$login" = admin ] || fail "empty database: setup planned no password (got '$login')"
seed_table 1 admin "$DEFAULT_PASS"
harden "$generated" || { cat "$TEST_DIR/harden.log" >&2; fail "empty database: kvs-init refused the password setup planned"; }
[ "$(sql "SELECT COUNT(*) FROM ${TABLES_PREFIX}admin_users WHERE user_id=1 AND pass=$DEFAULT_PASS")" = 0 ] ||
    fail "empty database: the default password survived kvs-init"
echo "PASS: a database kvs-init will seed gets a one-time password kvs-init applies"

# 3. user 1 renamed by its owner, archive password kept: both checks see the
# default, setup names the real login, and kvs-init accepts the result.
seed_table 1 boss "$DEFAULT_PASS"
login=$(setup_default_admin_login) || fail "renamed default: the check failed"
[ "$login" = boss ] || fail "renamed default: setup named '$login', not the account's login boss"
[ "$(sql "$site_manager_query")" = boss ] || fail "renamed default: site-manager.sh does not name the account with the default password"
if harden ""; then
    fail "renamed default: kvs-init accepted the default password without a new one"
fi
harden "$generated" || { cat "$TEST_DIR/harden.log" >&2; fail "renamed default: kvs-init refused the password setup planned"; }
echo "PASS: a renamed account with the archive password gets a one-time password under its own login"

# 4. user 1 renamed and hardened: nothing to rotate, for setup, site-manager
# and kvs-init alike.
seed_table 1 boss "$OTHER_PASS"
login=$(setup_default_admin_login) || fail "hardened: the check failed"
[ -z "$login" ] || fail "hardened: setup planned to replace a hardened password (named '$login')"
[ -z "$(sql "$site_manager_query")" ] || fail "hardened: site-manager.sh sees a default password"
harden "" || { cat "$TEST_DIR/harden.log" >&2; fail "hardened: kvs-init refused a hardened account"; }
[ "$(sql "SELECT COUNT(*) FROM ${TABLES_PREFIX}admin_users WHERE user_id=1 AND pass=$OTHER_PASS")" = 1 ] ||
    fail "hardened: the owner's password changed"
echo "PASS: a hardened account keeps its password"

# 5. The archive admin account is not user 1: kvs-init does not look at it,
# and neither does setup.
sql "INSERT INTO ${TABLES_PREFIX}admin_users (user_id, login, pass) VALUES (7, 'admin', $DEFAULT_PASS);"
login=$(setup_default_admin_login) || fail "other user: the check failed"
[ -z "$login" ] || fail "other user: setup planned a password for an account kvs-init does not check"
echo "PASS: only user_id 1 decides, as in kvs-init"

# 6. MariaDB does not answer: setup must stop rather than read "no default".
docker stop "$container" >/dev/null
if setup_default_admin_login >/dev/null 2>&1; then
    fail "an unreachable MariaDB was read as an account without the default password"
fi
echo "PASS: setup stops when it cannot check the admin account ($IMAGE)"
