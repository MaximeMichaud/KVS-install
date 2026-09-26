#!/bin/bash
# An import without the KVS archive: the site's version, encoding and
# nginx rewrites come from the site itself, from the operator or from the
# old server's nginx configuration; an archive, when there is one, must
# be of the site's version.
# shellcheck disable=SC2034  # Variables are consumed by extracted production functions.
# shellcheck disable=SC2329  # Stub functions are called by the extracted production code.
# shellcheck disable=SC2016  # grep patterns hold literal dollar signs.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-import-noarchive.XXXXXX)
TESTS_RUN=0

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "ok $TESTS_RUN - $1"
}

extract_function() {
    local name="$1"

    awk -v signature="${name}() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$ROOT_DIR/docker/setup.sh"
}

# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
functions_file="$TEST_DIR/functions.sh"
{
    extract_function import_check_kvs_archive_version
    extract_function detect_ioncube
    extract_function import_save_nginx_config
    extract_function import_ensure_nginx_rewrites
} > "$functions_file"
# shellcheck source=/dev/null
source "$functions_file"

RED='' GREEN='' YELLOW='' CYAN='' NC=''
DOMAIN=example.com
IMPORT_MODE=true
IMPORT_SITE_VERSION=7.0.2
IMPORT_OLD_PATH=/var/www/website
IMPORT_REMOTE_DIR=""
IMPORT_NGINX_REWRITES=""
IMPORT_NGINX_CONFIG=""
IMPORT_SITE_IONCUBE=""
IMPORT_STAGING="$TEST_DIR/import"

fresh_workdir() {
    rm -rf "$TEST_DIR/work"
    mkdir -p "$TEST_DIR/work/kvs-archive"
    cd "$TEST_DIR/work"
}

test_the_archive_is_optional_but_must_match_the_site() {
    local out

    fresh_workdir
    out=$(import_check_kvs_archive_version) || fail "no archive must not stop an import"
    grep -q "none needed" <<< "$out" || fail "the operator is told no archive is needed: $out"

    : > "kvs-archive/KVS_7.0.1_[example.com].zip"
    import_archive_version() { echo 7.0.1; }
    out=$(import_check_kvs_archive_version 2>&1) && fail "an archive of another version must stop the import"
    grep -q "use the archive of the same version" <<< "$out" || fail "the mismatch is explained: $out"
    import_archive_version() { echo 7.0.2; }
    import_check_kvs_archive_version > /dev/null || fail "an archive of the site's version passes"
    unset -f import_archive_version
    pass "the archive is optional but must match the site"
}

test_the_encoding_of_the_imported_site_decides() {
    fresh_workdir
    echo "IONCUBE=YES" > .env
    IMPORT_SITE_IONCUBE=no detect_ioncube > "$TEST_DIR/out" || fail "detection must succeed"
    grep -q "^IONCUBE=NO$" .env || fail "a plain site turns the loader off: $(cat .env)"
    grep -q "Plain PHP files detected in the imported site" "$TEST_DIR/out" || fail "the source of the answer is named"
    IMPORT_SITE_IONCUBE=yes detect_ioncube > "$TEST_DIR/out" || fail "detection must succeed"
    grep -q "^IONCUBE=YES$" .env || fail "an encoded site turns the loader on: $(cat .env)"
    # Nothing known and no archive: the loader stays on.
    IMPORT_SITE_IONCUBE="" detect_ioncube > "$TEST_DIR/out" || fail "detection must succeed without an archive"
    grep -q "^IONCUBE=YES$" .env || fail "without an answer the loader stays on"
    grep -q "Defaulting to IonCube=YES" "$TEST_DIR/out" || fail "the default is announced"
    pass "the encoding of the imported site decides"
}

test_the_old_configuration_is_saved_next_to_the_import_marker() {
    local report="$TEST_DIR/report.txt"

    fresh_workdir
    printf 'kvs_export=1\nnginx_config_1=server {\nnginx_config_2=}\n' > "$report"
    IMPORT_NGINX_CONFIG=""
    import_save_nginx_config "$report" > "$TEST_DIR/out" || fail "saving must succeed"
    [ "$IMPORT_NGINX_CONFIG" = "$IMPORT_STAGING/example.com.old-nginx.conf" ] || fail "the file sits next to the marker: $IMPORT_NGINX_CONFIG"
    [ "$(cat "$IMPORT_NGINX_CONFIG")" = $'server {\n}' ] || fail "the configuration is written back as text"
    grep -q "merge custom rules into conf/nginx/templates/kvs.conf.tpl" "$TEST_DIR/out" || fail "the operator is told where the custom rules go"
    printf 'kvs_export=1\n' > "$report"
    import_save_nginx_config "$report" > "$TEST_DIR/out" || fail "a report without a configuration is not an error"
    [ -z "$IMPORT_NGINX_CONFIG" ] || fail "no configuration, no file"
    [ ! -e "$IMPORT_STAGING/example.com.old-nginx.conf" ] || fail "the earlier file is removed"
    pass "the old configuration is saved next to the import marker"
}

test_the_rewrites_come_from_the_site_the_operator_the_archive_or_the_old_server() {
    local site="$TEST_DIR/site" out

    fresh_workdir
    IMPORT_NGINX_CONFIG=""
    IMPORT_NGINX_REWRITES=""
    # The site kept its _INSTALL directory: nothing to do.
    mkdir -p "$site/_INSTALL"
    echo "rewrite ^/shipped$ /shipped.php last;" > "$site/_INSTALL/nginx_config.txt"
    out=$(import_ensure_nginx_rewrites "$site") || fail "a shipped file is enough"
    grep -q "from the site's _INSTALL/nginx_config.txt" <<< "$out" || fail "the shipped file is announced: $out"
    grep -q shipped "$site/_INSTALL/nginx_config.txt" || fail "the shipped file is untouched"

    # The operator's file.
    rm -rf "$site"
    mkdir -p "$site"
    echo "rewrite ^/given$ /given.php last;" > "$TEST_DIR/given.txt"
    IMPORT_NGINX_REWRITES="$TEST_DIR/given.txt"
    out=$(import_ensure_nginx_rewrites "$site") || fail "the operator's file is taken"
    grep -q "from $TEST_DIR/given.txt" <<< "$out" || fail "the operator's file is announced: $out"
    [ "$(cat "$site/_INSTALL/nginx_config.txt")" = "rewrite ^/given$ /given.php last;" ] || fail "the operator's file is copied into _INSTALL"
    rm -rf "$site/_INSTALL"
    IMPORT_NGINX_REWRITES="$TEST_DIR/absent.txt"
    (import_ensure_nginx_rewrites "$site") > "$TEST_DIR/out" 2>&1 && fail "an unreadable operator file must stop the import"
    grep -q "not a readable, non-empty file" "$TEST_DIR/out" || fail "the unreadable file is named: $(cat "$TEST_DIR/out")"
    IMPORT_NGINX_REWRITES=""

    # An archive in kvs-archive/: the init extracts the rules from it.
    rm -rf "$site"
    mkdir -p "$site"
    : > "kvs-archive/KVS_7.0.2_[example.com].zip"
    out=$(import_ensure_nginx_rewrites "$site") || fail "an archive is enough"
    grep -q "from the KVS archive" <<< "$out" || fail "the archive is announced: $out"
    [ ! -e "$site/_INSTALL/nginx_config.txt" ] || fail "nothing is written when the archive serves"
    rm -f "kvs-archive/KVS_7.0.2_[example.com].zip"

    # The old server's configuration: the rules of the site's server block.
    cat > "$TEST_DIR/old-nginx.conf" <<'EOF'
server {
    root /var/www/other;
    rewrite ^/other$ /other.php last;
}
server {
    root /var/www/website;
    rewrite ^/videos/$ /videos.php last;
    rewrite ^/video/([0-9]{1,8})/$ /view_video.php?id=$1 last;
}
EOF
    IMPORT_NGINX_CONFIG="$TEST_DIR/old-nginx.conf"
    out=$(import_ensure_nginx_rewrites "$site") || fail "the old server's rules are enough"
    grep -q "2 rules recovered from the old server's nginx configuration" <<< "$out" || fail "the recovered rules are counted: $out"
    grep -q '^rewrite ^/videos/$ /videos.php last;$' "$site/_INSTALL/nginx_config.txt" || fail "the site's rules are written"
    grep -q '^rewrite ^/video/(\[0-9\]{1,8})/$ /view_video.php?id=$1 last;$' "$site/_INSTALL/nginx_config.txt" || fail "a quantifier in a rule does not break the block"
    grep -q '^# Rewrite rules recovered by kvs-install' "$site/_INSTALL/nginx_config.txt" || fail "the file says where it comes from"
    grep -q other "$site/_INSTALL/nginx_config.txt" && fail "the other site's rules stay out"
    # The remote site directory names the block when the project path differs.
    rm -rf "$site/_INSTALL"
    IMPORT_REMOTE_DIR=/var/www/website
    IMPORT_OLD_PATH=/home/old/www
    out=$(import_ensure_nginx_rewrites "$site") || fail "the remote directory names the block"
    grep -q "2 rules recovered" <<< "$out" || fail "the remote directory finds the block: $out"
    IMPORT_REMOTE_DIR=""
    IMPORT_OLD_PATH=/var/www/website

    # Nothing at all: the import stops and says what to provide.
    rm -rf "$site/_INSTALL"
    IMPORT_NGINX_CONFIG="$TEST_DIR/old-nginx.conf"
    IMPORT_OLD_PATH=/var/www/nothing
    (import_ensure_nginx_rewrites "$site") > "$TEST_DIR/out" 2>&1 && fail "no rules from anywhere must stop the import"
    grep -q "ERROR: no nginx rewrite rules for the site" "$TEST_DIR/out" || fail "the stop is explained: $(cat "$TEST_DIR/out")"
    grep -q "Set IMPORT_NGINX_REWRITES to the nginx_config.txt of KVS 7.0.2" "$TEST_DIR/out" || fail "the way out is given: $(cat "$TEST_DIR/out")"
    grep -q "saved in $TEST_DIR/old-nginx.conf" "$TEST_DIR/out" || fail "the saved configuration is pointed at"
    [ ! -e "$site/_INSTALL/nginx_config.txt" ] || fail "nothing is written on failure"
    IMPORT_OLD_PATH=/var/www/website

    # Outside an import, nothing happens.
    IMPORT_MODE=false
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "outside an import the function is a no-op"
    [ ! -s "$TEST_DIR/out" ] || fail "and says nothing"
    IMPORT_MODE=true
    pass "the rewrites come from the site, the operator, the archive or the old server"
}

test_the_archive_is_optional_but_must_match_the_site
test_the_encoding_of_the_imported_site_decides
test_the_old_configuration_is_saved_next_to_the_import_marker
test_the_rewrites_come_from_the_site_the_operator_the_archive_or_the_old_server

echo "All $TESTS_RUN import-without-archive tests passed."
