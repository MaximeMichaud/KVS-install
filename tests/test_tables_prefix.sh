#!/bin/bash
# The table prefix comes from the site's setup.php wherever a script names
# a KVS table: the init inside the container, the Docker setup, the
# standalone installer and the multi-site manager. Nothing assumes ktvs_
# beyond the fallback for a site that does not say.
#
# The functions under test are extracted from the scripts and read globals
# set here; the literal ${...} strings are what the scripts must contain.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-tables-prefix.XXXXXX)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

extract_function() {
    local file="$1"
    local name="$2"

    awk -v signature="${name}() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$file"
}

# A setup.php as KVS writes it, with the multi prefix first so that a
# sloppy match on tables_prefix would pick the wrong line.
write_setup() {
    local dir="$1"
    local prefix="$2"

    mkdir -p "$dir/admin/include"
    cat > "$dir/admin/include/setup.php" <<PHP
<?php
\$config['project_path']="/var/www/kvs";
\$config['tables_prefix_multi']="wrong_";
\$config['tables_prefix']="$prefix";
PHP
}

make_archive() {
    local dir="$1"
    local archive="$2"

    if command -v zip >/dev/null 2>&1; then
        (cd "$dir" && zip -q -r "$archive" admin)
    else
        (cd "$dir" && python3 -m zipfile -c "$archive" admin)
    fi
}

# --- the init reads the site inside the container ---------------------------
eval "$(extract_function "$ROOT_DIR/docker/init/lib/common.sh" get_tables_prefix)"
log_warn() {
    echo "[WARN] $*"
}
KVS_PATH="$TEST_DIR/init-site"
write_setup "$KVS_PATH" kvs7_
[ "$(get_tables_prefix)" = kvs7_ ] || fail "the init must read the site's own prefix"
write_setup "$KVS_PATH" "kt vs;"
output=$(get_tables_prefix 2> "$TEST_DIR/warn")
[ "$output" = ktvs_ ] || fail "an unusable prefix must fall back to ktvs_ (got '$output')"
grep -q 'No usable tables_prefix' "$TEST_DIR/warn" || fail "the fallback must be announced on stderr"
rm -f "$KVS_PATH/admin/include/setup.php"
[ "$(get_tables_prefix 2>/dev/null)" = ktvs_ ] || fail "a missing setup.php must fall back to ktvs_"

# --- the Docker setup: import, site in place, archive, fallback --------------
eval "$(extract_function "$ROOT_DIR/docker/setup.sh" setup_php_config_value)"
eval "$(extract_function "$ROOT_DIR/docker/setup.sh" kvs_tables_prefix)"
[ "$(setup_php_config_value tables_prefix < "$TEST_DIR/init-site/admin/include/setup.php" 2>/dev/null || true)" = "" ] ||
    fail "a missing file yields nothing"
write_setup "$TEST_DIR/init-site" kvs7_
[ "$(setup_php_config_value tables_prefix < "$TEST_DIR/init-site/admin/include/setup.php")" = kvs7_ ] ||
    fail "setup_php_config_value must match the exact key"
[ "$(setup_php_config_value tables_prefix_multi < "$TEST_DIR/init-site/admin/include/setup.php")" = wrong_ ] ||
    fail "setup_php_config_value must read the multi prefix on request"

mkdir -p "$TEST_DIR/docker/kvs-archive"
IMPORT_MODE=true
IMPORT_TABLES_PREFIX=old_
DOMAIN=example.com
output=$(cd "$TEST_DIR/docker" && kvs_tables_prefix)
[ "$output" = old_ ] || fail "an import must keep the imported site's prefix (got '$output')"
IMPORT_MODE=false
IMPORT_TABLES_PREFIX=""
output=$(cd "$TEST_DIR/docker" && kvs_tables_prefix)
[ "$output" = ktvs_ ] || fail "no site and no archive must fall back to ktvs_ (got '$output')"
write_setup "$TEST_DIR/archive-site" arch_
make_archive "$TEST_DIR/archive-site" "$TEST_DIR/docker/kvs-archive/KVS_7.0.2_[example.com].zip"
output=$(cd "$TEST_DIR/docker" && kvs_tables_prefix)
[ "$output" = arch_ ] || fail "a fresh install must read the archive's prefix (got '$output')"
if [ -d /var/www ]; then
    # /var/www/../..<absolute path> resolves to that path: the site in place
    # wins over the archive.
    write_setup "$TEST_DIR/placed" placed_
    DOMAIN="../..$TEST_DIR/placed"
    output=$(cd "$TEST_DIR/docker" && kvs_tables_prefix)
    [ "$output" = placed_ ] || fail "a site already in place must be read before the archive (got '$output')"
    DOMAIN=example.com
fi
grep -Fq 'set_env_value TABLES_PREFIX "$(kvs_tables_prefix)"' "$ROOT_DIR/docker/setup.sh" ||
    fail "the setup must write the prefix to .env"
grep -Fq 'TABLES_PREFIX=${TABLES_PREFIX:-ktvs_}' "$ROOT_DIR/docker/docker-compose.yml" ||
    fail "the Manticore container must receive the prefix from .env"
grep -Fq 'TABLES_PREFIX="${TABLES_PREFIX:-ktvs_}"' "$ROOT_DIR/docker/reconfigure.sh" ||
    fail "reconfigure.sh must read the prefix from .env"

# --- the standalone installer -------------------------------------------------
eval "$(extract_function "$ROOT_DIR/kvs-install.sh" kvs_tables_prefix)"
write_setup "$TEST_DIR/bare-site" bare_
KVS_PATH="$TEST_DIR/bare-site"
[ "$(kvs_tables_prefix)" = bare_ ] || fail "the installer must read the site it installed"
KVS_PATH="$TEST_DIR/nowhere"
[ "$(kvs_tables_prefix)" = ktvs_ ] || fail "the installer falls back to ktvs_ without a site"
grep -Fq 'INSERT INTO ${prefix}settings' "$ROOT_DIR/kvs-install.sh" ||
    fail "the installer's system settings must use the prefix"
grep -Fq 'UPDATE ${prefix}admin_servers' "$ROOT_DIR/kvs-install.sh" ||
    fail "the installer's server rows must use the prefix"
if grep -Fq "<<'EOSQL'" "$ROOT_DIR/kvs-install.sh"; then
    fail "a quoted heredoc would keep the prefix literal in the SQL"
fi

# --- the multi-site manager ------------------------------------------------------
eval "$(extract_function "$ROOT_DIR/docker/multi-site/site-manager.sh" site_tables_prefix)"
eval "$(extract_function "$ROOT_DIR/docker/multi-site/site-manager.sh" archive_tables_prefix)"
mkdir -p "$TEST_DIR/site-a"
echo "TABLES_PREFIX=multi_" > "$TEST_DIR/site-a/.env"
[ "$(cd "$TEST_DIR/site-a" && site_tables_prefix)" = multi_ ] || fail "the manager must read a site's .env"
echo "TABLES_PREFIX=kt vs;" > "$TEST_DIR/site-a/.env"
[ "$(cd "$TEST_DIR/site-a" && site_tables_prefix)" = ktvs_ ] || fail "an unusable prefix in .env falls back to ktvs_"
: > "$TEST_DIR/site-a/.env"
[ "$(cd "$TEST_DIR/site-a" && site_tables_prefix)" = ktvs_ ] || fail "a site without the value runs with ktvs_"
KVS_ARCHIVE_DIR="$TEST_DIR/docker/kvs-archive"
[ "$(archive_tables_prefix)" = arch_ ] || fail "a new site takes the archive's prefix"
KVS_ARCHIVE_DIR="$TEST_DIR/no-archive"
[ "$(archive_tables_prefix)" = ktvs_ ] || fail "no archive falls back to ktvs_"
grep -Fq 'TABLES_PREFIX=${tables_prefix}' "$ROOT_DIR/docker/multi-site/site-manager.sh" ||
    fail "a new site's .env must carry the prefix"
grep -Fq '-e "TABLES_PREFIX=$(site_tables_prefix)"' "$ROOT_DIR/docker/multi-site/site-manager.sh" ||
    fail "the admin checks must pass the prefix to the database container"

echo "PASS: table prefix read from the site everywhere"
