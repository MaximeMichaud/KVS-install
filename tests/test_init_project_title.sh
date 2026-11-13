#!/bin/bash
# kvs-init names a fresh site after its domain: the stock setup.php titles it
# "KVS", and 10-config-php.sh puts the domain there. A site imported from
# another server keeps the title it was given, and a rerun of the init,
# which setup.sh makes on every run, changes nothing.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d -t kvs-init-project-title.XXXXXX)

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

# write_site <dir> <project_path> <title>: setup.php as KVS writes it.
write_site() {
    mkdir -p "$1/admin/include"
    cat > "$1/admin/include/setup.php" <<PHP
<?php
\$config['project_path']="$2";
\$config['project_url']="https://old.example.com";
\$config['project_title']="$3";
PHP
    cat > "$1/admin/include/setup_db.php" <<'PHP'
<?php
define('DB_HOST','localhost');
define('DB_LOGIN','old_user');
define('DB_PASS','old-password');
define('DB_DEVICE','old_database');
PHP
}

title() {
    sed -n -E "s/^\\\$config\\['project_title'\\]=\"(.*)\";$/\\1/p" "$1/admin/include/setup.php"
}

run_config() {
    TEST_KVS_PATH="$1" DOMAIN=example.com MARIADB_PASSWORD=test-password USE_WWW=false \
        bash "$TEST_DIR/10-config-php.sh" > "$TEST_DIR/run.log" 2>&1 ||
        fail "the configuration of $1 failed: $(cat "$TEST_DIR/run.log")"
}

# A fresh archive: the placeholder path and the stock title.
site="$TEST_DIR/fresh"
write_site "$site" /PATH KVS
run_config "$site"
[ "$(title "$site")" = example.com ] || fail "a fresh site must be titled after its domain, got '$(title "$site")'"
run_config "$site"
[ "$(title "$site")" = example.com ] || fail "a rerun changed the title of a fresh site to '$(title "$site")'"

# A run stopped once the placeholder is gone, here by a project_path rewrite
# that fails, still leaves the fresh site titled after its domain: the next
# run no longer sees the placeholder.
site="$TEST_DIR/stopped"
write_site "$site" /PATH KVS
mkdir -p "$TEST_DIR/failing-sed"
cat > "$TEST_DIR/failing-sed/sed" <<EOF
#!/bin/sh
case "\$*" in
    *"-E -i"*project_path*) exit 1 ;;
esac
exec $(command -v sed) "\$@"
EOF
chmod 0755 "$TEST_DIR/failing-sed/sed"
if PATH="$TEST_DIR/failing-sed:$PATH" TEST_KVS_PATH="$site" DOMAIN=example.com \
    MARIADB_PASSWORD=test-password USE_WWW=false bash "$TEST_DIR/10-config-php.sh" \
    > "$TEST_DIR/stopped.log" 2>&1; then
    fail "the stopped run did not stop: $(cat "$TEST_DIR/stopped.log")"
fi
run_config "$site"
[ "$(title "$site")" = example.com ] ||
    fail "a fresh site whose first run stopped is titled '$(title "$site")'"

# Imported sites, whose titles hold "KVS", keep them run after run.
for imported_title in 'KVS Tube' 'KVS and KVS' 'My KVS'; do
    site="$TEST_DIR/imported"
    rm -rf "$site"
    write_site "$site" /home/old/www "$imported_title"
    for run in first second; do
        run_config "$site"
        [ "$(title "$site")" = "$imported_title" ] ||
            fail "the ${run} run changed the imported title '${imported_title}' to '$(title "$site")'"
    done
done

# A site already in its container path keeps its title too, "KVS" included.
site="$TEST_DIR/in-place"
write_site "$site" "$TEST_DIR/in-place" KVS
run_config "$site"
[ "$(title "$site")" = KVS ] || fail "a rerun on a site in place changed its title to '$(title "$site")'"

echo "PASS: kvs-init titles a fresh site after its domain and leaves other titles alone"
