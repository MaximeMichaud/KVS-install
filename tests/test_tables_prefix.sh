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
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/init/lib/common.sh"
SETUP_SCRIPT_DIR="$ROOT_DIR/docker"
SCRIPT_DIR="$ROOT_DIR/docker/multi-site"
log_warn() {
    echo "[WARN] $*"
}
DOMAIN=example.test
KVS_PATH="$TEST_DIR/init-site"
write_setup "$KVS_PATH" kvs7_
[ "$(get_tables_prefix)" = kvs7_ ] || fail "the init must read the site's own prefix"
for invalid in '' 'kvs-' 'kt vs;' 'a\033[31mRED\cb' $'a\033b' $'a\rb' 'é-'; do
    write_setup "$KVS_PATH" "$invalid"
    status=0
    output=$(get_tables_prefix 2> "$TEST_DIR/warn") || status=$?
    [ "$status" != 0 ] && [ -z "$output" ] || fail 'expected refusal'
    grep -Fq "$KVS_PATH/admin/include/setup.php" "$TEST_DIR/warn" || fail 'missing source path'
    grep -Fq "/var/www/$DOMAIN/admin/include/setup.php" "$TEST_DIR/warn" || fail 'missing host path'
    diagnostic=$(cat "$TEST_DIR/warn")
    if [ -n "$invalid" ] && [[ ${diagnostic//"$KVS_PATH"/} == *"$invalid"* ]]; then fail 'diagnostic echoed unusable identifier'; fi
done
eval "$(extract_function "$ROOT_DIR/docker/multi-site/site-manager.sh" kept_site_tables_prefix)"
for reader in get_tables_prefix kept_site_tables_prefix; do
    for value in "'part_' . 'more'" 'SITE_PREFIX' '"${prefix}_"' "'a' /* note */ . 'b'"; do
        printf "\$config['tables_prefix'] = %s;\n" "$value" > "$KVS_PATH/admin/include/setup.php"
        if result=$("$reader" "$KVS_PATH" 2> "$TEST_DIR/error"); then fail "$reader guessed $result"; fi
        [ -z "$result" ] || fail 'unexpected stdout for computed prefix'
        grep -Fq "$KVS_PATH/admin/include/setup.php" "$TEST_DIR/error" || fail 'missing prefix diagnostic'
    done
    for value in ktvs_ café_; do
        printf "\$config ['tables_prefix'] = '%s' /* installed */;\n" "$value" > "$KVS_PATH/admin/include/setup.php"
        [ "$("$reader" "$KVS_PATH")" = "$value" ] || fail "$reader lost a literal prefix"
    done
    printf '%s\n' "\$config['tables_prefix']='first_';" "\$config['tables_prefix']=OTHER;" > "$KVS_PATH/admin/include/setup.php"
    if "$reader" "$KVS_PATH"; then fail 'ambiguous second assignment accepted'; fi
    rm -f "$KVS_PATH/admin/include/setup.php"
    if "$reader" "$KVS_PATH"; then fail 'missing setup.php accepted'; fi
done

# --- the Docker setup: import, site in place, archive, fallback --------------
eval "$(extract_function "$ROOT_DIR/docker/setup.sh" setup_kvs_archive)"
eval "$(extract_function "$ROOT_DIR/docker/setup.sh" kvs_tables_prefix)"

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
mkdir -p "$TEST_DIR/computed/kvs-archive"
archive="$TEST_DIR/computed/kvs-archive/KVS_fixture.zip"
printf '%s\n' "\$config['tables_prefix'] = 'part_' . 'rest';" > "$TEST_DIR/archive-site/admin/include/setup.php"
make_archive "$TEST_DIR/archive-site" "$archive"
if (cd "$TEST_DIR/computed" && kvs_tables_prefix) > "$TEST_DIR/value" 2> "$TEST_DIR/error"; then
    fail "setup accepted a computed archive prefix"
fi
[ ! -s "$TEST_DIR/value" ] || fail "setup returned a prefix from a computed archive assignment"
grep -Fq "$archive:admin/include/setup.php" "$TEST_DIR/error" || fail 'missing setup archive diagnostic'
(
    SETUP_SCRIPT_DIR="$TEST_DIR/standalone"
    mkdir -p "$SETUP_SCRIPT_DIR/kvs-archive"
    cd "$SETUP_SCRIPT_DIR"
    archive=kvs-archive/KVS_fixture.zip
    cp "$TEST_DIR/docker/kvs-archive/KVS_7.0.2_[example.com].zip" "$archive"
    [ "$(setup_kvs_archive)" = "$archive" ] || fail 'standalone preflight lost the single archive'
    if kvs_tables_prefix > "$TEST_DIR/value" 2> "$TEST_DIR/error"; then
        fail 'standalone setup guessed the archived prefix without the reader'
    fi
    grep -Fq "$SETUP_SCRIPT_DIR/init/lib/kvs-archive.sh" "$TEST_DIR/error" || fail 'missing library diagnostic'
    cp "$archive" kvs-archive/KVS_other.zip
    if setup_kvs_archive > "$TEST_DIR/value" 2> "$TEST_DIR/error"; then
        fail 'standalone preflight chose between multiple archives'
    fi
    if [ -d /var/www ]; then
        write_setup "$TEST_DIR/standalone-site" placed_
        DOMAIN="../..$TEST_DIR/standalone-site"
        if kvs_tables_prefix > "$TEST_DIR/value" 2> "$TEST_DIR/error"; then
            fail 'standalone setup guessed the installed prefix without the reader'
        fi
        grep -Fq "$SETUP_SCRIPT_DIR/init/lib/kvs-archive.sh" "$TEST_DIR/error" || fail 'missing library diagnostic'
    fi
)
if [ -d /var/www ]; then
    # /var/www/../..<absolute path> resolves to that path: the site in place
    # wins over the archive.
    write_setup "$TEST_DIR/placed" placed_
    DOMAIN="../..$TEST_DIR/placed"
    output=$(cd "$TEST_DIR/docker" && kvs_tables_prefix)
    [ "$output" = placed_ ] || fail "a site already in place must be read before the archive (got '$output')"
    for expression in "'part_' . 'more'" "''" "'kvs-'" "getenv('P')"; do
        printf "\$config ['tables_prefix'] = %s;\n" "$expression" > "$TEST_DIR/placed/admin/include/setup.php"
        if TABLES_PREFIX=part_ kvs_tables_prefix > "$TEST_DIR/value" 2> "$TEST_DIR/error"; then fail "setup guessed a prefix"; fi
        grep -Fq "$DOMAIN/admin/include/setup.php" "$TEST_DIR/error" || fail "missing host path"
    done
    DOMAIN=example.com
fi
grep -Fq 'set_env_value TABLES_PREFIX "$TABLES_PREFIX"' "$ROOT_DIR/docker/setup.sh" ||
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
eval "$(extract_function "$ROOT_DIR/docker/multi-site/site-manager.sh" env_file_value)"
eval "$(extract_function "$ROOT_DIR/docker/multi-site/site-manager.sh" site_tables_prefix)"
eval "$(extract_function "$ROOT_DIR/docker/multi-site/site-manager.sh" archive_tables_prefix)"
mkdir -p "$TEST_DIR/site-a"
printf 'TABLES_PREFIX=old_\n export TABLES_PREFIX = "multi_" # current\r\n' > "$TEST_DIR/site-a/.env"
[ "$(cd "$TEST_DIR/site-a" && site_tables_prefix)" = multi_ ] || fail "the manager must read a site's .env"
for value in 'kt vs;' '${OTHER}' "multi_"$'\nTABLES_PREFIX=${OTHER}' ''; do
    echo "TABLES_PREFIX=$value" > "$TEST_DIR/site-a/.env"
    if (cd "$TEST_DIR/site-a" && site_tables_prefix) > "$TEST_DIR/value" 2> "$TEST_DIR/error"; then
        fail "an ambiguous or unusable environment prefix was accepted"
    fi
    [ ! -s "$TEST_DIR/value" ] || fail "unexpected prefix on stdout"
    grep -Fq "$TEST_DIR/site-a/.env" "$TEST_DIR/error" || fail "wrong prefix diagnostic"
done
: > "$TEST_DIR/site-a/.env"
if (cd "$TEST_DIR/site-a" && site_tables_prefix); then fail "missing environment prefix accepted"; fi
selected_archive="$TEST_DIR/docker/kvs-archive/KVS_7.0.2_[example.com].zip"
if (cd "$TEST_DIR/site-a" && site_tables_prefix "" "$selected_archive"); then
    fail "a stock archive was taken as evidence for an existing database without a saved or installed prefix"
fi
cat > "$TEST_DIR/site-a/.env" <<'ENV'
NOTE="a multiline setting with an escaped \" quote
TABLES_PREFIX=lookalike_
"
ENV
if (cd "$TEST_DIR/site-a" && site_tables_prefix); then fail "a prefix inside another value was accepted"; fi
echo "TABLES_PREFIX='multi_' # saved literal" >> "$TEST_DIR/site-a/.env"
[ "$(cd "$TEST_DIR/site-a" && site_tables_prefix)" = multi_ ] || fail "quoted literal rejected"
[ "$(archive_tables_prefix "$TEST_DIR/docker/kvs-archive/KVS_7.0.2_[example.com].zip")" = arch_ ] ||
    fail "a new site takes the archive's prefix"
[ "$(archive_tables_prefix "")" = ktvs_ ] || fail "no archive falls back to ktvs_"
write_setup "$TEST_DIR/archive-site" first_
printf '%s\n' "\$config ['tables_prefix']='bad_' . 'value';" >> "$TEST_DIR/archive-site/admin/include/setup.php"
bad_archive="$TEST_DIR/invalid.zip"
make_archive "$TEST_DIR/archive-site" "$bad_archive"
if archive_tables_prefix "$bad_archive" 2> "$TEST_DIR/error"; then fail 'accepted a computed archive prefix'; fi
grep -Fq "$bad_archive:admin/include/setup.php" "$TEST_DIR/error" || fail 'missing archive diagnostic'
grep -Fq 'TABLES_PREFIX=${tables_prefix}' "$ROOT_DIR/docker/multi-site/site-manager.sh" ||
    fail "a new site's .env must carry the prefix"
grep -Fq -- '-e "TABLES_PREFIX=$tables_prefix"' "$ROOT_DIR/docker/multi-site/site-manager.sh" ||
    fail "the admin checks must pass the prefix to the database container"

echo "PASS: table prefix read from the site everywhere"
