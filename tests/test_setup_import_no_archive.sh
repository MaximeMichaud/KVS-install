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
    extract_function remove_env_value
    extract_function set_env_value
    extract_function import_check_kvs_archive_version
    extract_function detect_ioncube
    extract_function import_save_nginx_config
    extract_function import_vouch_nginx_rewrites
    extract_function import_ensure_nginx_rewrites
    extract_function import_resume_nginx_rewrites
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
    # Nothing known and no archive: the loader stays as it is.
    IMPORT_SITE_IONCUBE="" detect_ioncube > "$TEST_DIR/out" || fail "detection must succeed without an archive"
    grep -q "^IONCUBE=YES$" .env || fail "without an answer the loader stays on"
    grep -q "Keeping IONCUBE=YES" "$TEST_DIR/out" || fail "what is kept is announced: $(cat "$TEST_DIR/out")"
    # A site in place decides before the archive, on a re-run as well.
    local site="$TEST_DIR/placed"
    mkdir -p "$site/admin/include"
    printf '<?php //004fe\nif(!extension_loaded("ionCube Loader")){die();}\n' > "$site/admin/include/functions_base.php"
    echo "IONCUBE=NO" > .env
    IMPORT_SITE_IONCUBE="" detect_ioncube "$site" > "$TEST_DIR/out" || fail "detection must succeed on a site in place"
    grep -q "^IONCUBE=YES$" .env || fail "an encoded site in place turns the loader on: $(cat .env)"
    grep -q "in the site under $site" "$TEST_DIR/out" || fail "the site in place is named as the source: $(cat "$TEST_DIR/out")"
    printf '<?php\nfunction sql() {}\n' > "$site/admin/include/functions_base.php"
    : > "kvs-archive/KVS_7.0.2_[example.com].zip"
    IMPORT_SITE_IONCUBE="" detect_ioncube "$site" > "$TEST_DIR/out" || fail "detection must succeed on a plain site in place"
    grep -q "^IONCUBE=NO$" .env || fail "a plain site in place turns the loader off, archive or not: $(cat .env)"
    rm -f "kvs-archive/KVS_7.0.2_[example.com].zip"
    pass "the encoding of the imported site decides"
}

test_unknown_archive_keeps_the_existing_loader_setting() {
    local value expected saved

    for value in NO YES absent; do
        fresh_workdir
        printf 'KEEP=stable\n' > .env
        unset IONCUBE
        expected=YES
        if [ "$value" != absent ]; then
            IONCUBE=$value
            expected=$value
            printf 'IONCUBE=%s\n' "$value" >> .env
        fi
        printf 'unreadable archive fixture\n' > 'kvs-archive/KVS_7.0.2_[example.com].zip'
        cp .env "$TEST_DIR/unknown-before.env"
        IMPORT_SITE_IONCUBE='' detect_ioncube "$TEST_DIR/no-site" > "$TEST_DIR/out" || fail "unknown encoding must keep the saved setting"
        grep -Fq 'Keeping the existing IonCube configuration.' "$TEST_DIR/out" ||
            fail "unknown encoding must not announce a new default while retaining $value"
        cmp -s .env "$TEST_DIR/unknown-before.env" || fail "unknown encoding changed the saved configuration"
        saved=$(env -u IONCUBE -u BASH_ENV bash -c 'source .env; printf "%s" "${IONCUBE:-YES}"')
        [ "$saved" = "$expected" ] || fail "unknown encoding did not preserve the effective loader setting"
    done
    pass "unknown encoding reports that the existing loader configuration is kept"
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
    grep -q "from $TEST_DIR/given.txt (kept in $IMPORT_STAGING/example.com.nginx_config.txt for the next pass)" <<< "$out" || fail "the operator's file is announced: $out"
    [ "$(cat "$site/_INSTALL/nginx_config.txt")" = "rewrite ^/given$ /given.php last;" ] || fail "the operator's file is copied into _INSTALL"
    [ "$(cat "$IMPORT_STAGING/example.com.nginx_config.txt")" = "rewrite ^/given$ /given.php last;" ] || fail "the operator's file is kept for the next pass"
    rm -rf "$site/_INSTALL"
    IMPORT_NGINX_REWRITES="$TEST_DIR/absent.txt"
    (import_ensure_nginx_rewrites "$site") > "$TEST_DIR/out" 2>&1 && fail "an unreadable operator file must stop the import"
    grep -q "not a readable, non-empty file" "$TEST_DIR/out" || fail "the unreadable file is named: $(cat "$TEST_DIR/out")"
    IMPORT_NGINX_REWRITES=""

    # A kept override survives even when an archive is also available.
    rm -rf "$site"
    mkdir -p "$site"
    : > "kvs-archive/KVS_7.0.2_[example.com].zip"
    out=$(import_ensure_nginx_rewrites "$site") || fail "a kept override takes priority"
    cmp "$IMPORT_STAGING/example.com.nginx_config.txt" "$site/_INSTALL/nginx_config.txt" || fail "the kept override wins over the archive"
    rm -f "$IMPORT_STAGING/example.com.nginx_config.txt" "$site/_INSTALL/nginx_config.txt"
    out=$(import_ensure_nginx_rewrites "$site") || fail "an archive is enough without an override"
    grep -q "from the KVS archive" <<< "$out" || fail "the archive is announced: $out"
    cp "$TEST_DIR/given.txt" "$IMPORT_STAGING/example.com.nginx_config.txt"
    rm -f "kvs-archive/KVS_7.0.2_[example.com].zip"

    # The next pass, the site's _INSTALL cleaned by the init: the kept copy serves.
    out=$(import_ensure_nginx_rewrites "$site") || fail "the kept copy is enough"
    grep -q "from the earlier pass ($IMPORT_STAGING/example.com.nginx_config.txt)" <<< "$out" || fail "the earlier pass is announced: $out"
    [ "$(cat "$site/_INSTALL/nginx_config.txt")" = "rewrite ^/given$ /given.php last;" ] || fail "the kept rules are written back"
    # The real domain taking over the files of the development one: the
    # copy of that domain serves and becomes this domain's.
    rm -rf "$site/_INSTALL"
    mv "$IMPORT_STAGING/example.com.nginx_config.txt" "$IMPORT_STAGING/dev.example.com.nginx_config.txt"
    IMPORT_REUSE_SITE_DIR=/var/www/dev.example.com
    out=$(import_ensure_nginx_rewrites "$site") || fail "the copy of the domain taken over is enough"
    grep -q "from the earlier pass ($IMPORT_STAGING/dev.example.com.nginx_config.txt)" <<< "$out" || fail "the domain taken over is announced: $out"
    [ "$(cat "$IMPORT_STAGING/example.com.nginx_config.txt")" = "rewrite ^/given$ /given.php last;" ] || fail "the copy now carries this domain's name too"
    IMPORT_REUSE_SITE_DIR=""
    rm -f "$IMPORT_STAGING"/*.nginx_config.txt
    rm -rf "$site/_INSTALL"

    # The old server's configuration: the rules of the site's server block.
    cat > "$TEST_DIR/old-nginx.conf" <<'EOF'
server {
    root /var/www/other;
    rewrite ^/other$ /other.php last;
}
server {
    root /var/www/website;
    rewrite ^/videos/$ /videos.php last;
    rewrite "^/video/([0-9]{1,8})/$" /view_video.php?id=$1 last;
}
EOF
    IMPORT_NGINX_CONFIG="$TEST_DIR/old-nginx.conf"
    out=$(import_ensure_nginx_rewrites "$site") || fail "the old server's rules are enough"
    grep -q "2 rules recovered from the old server's nginx configuration" <<< "$out" || fail "the recovered rules are counted: $out"
    grep -q "kept in $IMPORT_STAGING/example.com.nginx_config.txt for the next pass" <<< "$out" || fail "the kept copy is announced: $out"
    grep -q '^rewrite ^/videos/$ /videos.php last;$' "$IMPORT_STAGING/example.com.nginx_config.txt" || fail "the recovered rules are kept for the next pass"
    grep -q '^rewrite ^/videos/$ /videos.php last;$' "$site/_INSTALL/nginx_config.txt" || fail "the site's rules are written"
    grep -Fq 'rewrite "^/video/([0-9]{1,8})/$" /view_video.php?id=$1 last;' "$site/_INSTALL/nginx_config.txt" || fail "a quantifier in a rule does not break the block"
    grep -q '^# Rewrite rules recovered by kvs-install' "$site/_INSTALL/nginx_config.txt" || fail "the file says where it comes from"
    grep -q other "$site/_INSTALL/nginx_config.txt" && fail "the other site's rules stay out"
    # The remote site directory names the block when the project path differs.
    rm -rf "$site/_INSTALL"
    rm -f "$IMPORT_STAGING/example.com.nginx_config.txt"
    IMPORT_REMOTE_DIR=/var/www/website
    IMPORT_OLD_PATH=/home/old/www
    out=$(import_ensure_nginx_rewrites "$site") || fail "the remote directory names the block"
    grep -q "2 rules recovered" <<< "$out" || fail "the remote directory finds the block: $out"
    IMPORT_REMOTE_DIR=""
    IMPORT_OLD_PATH=/var/www/website

    # Nothing at all: the import stops and says what to provide.
    rm -rf "$site/_INSTALL"
    rm -f "$IMPORT_STAGING/example.com.nginx_config.txt"
    IMPORT_NGINX_CONFIG="$TEST_DIR/old-nginx.conf"
    IMPORT_OLD_PATH=/var/www/nothing
    (import_ensure_nginx_rewrites "$site") > "$TEST_DIR/out" 2>&1 && fail "no rules from anywhere must stop the import"
    grep -q "ERROR: no nginx rewrite rules for the site" "$TEST_DIR/out" || fail "the stop is explained: $(cat "$TEST_DIR/out")"
    grep -q "Set IMPORT_NGINX_REWRITES to the nginx_config.txt of KVS 7.0.2" "$TEST_DIR/out" || fail "the way out is given: $(cat "$TEST_DIR/out")"
    grep -q "saved in $TEST_DIR/old-nginx.conf" "$TEST_DIR/out" || fail "the saved configuration is pointed at"
    [ ! -e "$site/_INSTALL/nginx_config.txt" ] || fail "nothing is written on failure"
    IMPORT_OLD_PATH=/var/www/website

    # Outside an import, nothing happens...
    IMPORT_MODE=false
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "outside an import the function is a no-op"
    [ ! -s "$TEST_DIR/out" ] || fail "and says nothing"
    [ ! -e "$site/_INSTALL/nginx_config.txt" ] || fail "and writes nothing without a site in place"
    # ... unless the site is in place and a copy was
    # kept: a re-run with recreated volumes gives the init its source back.
    mkdir -p "$site/admin/include" "$IMPORT_STAGING"
    : > "$site/admin/include/setup.php"
    echo "rewrite ^/kept$ /kept.php last;" > "$IMPORT_STAGING/example.com.nginx_config.txt"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "a re-run restores the kept rules"
    [ ! -s "$TEST_DIR/out" ] || fail "quietly"
    [ "$(cat "$site/_INSTALL/nginx_config.txt")" = "rewrite ^/kept$ /kept.php last;" ] || fail "the kept rules are back in _INSTALL for the init"
    rm -rf "$site/_INSTALL"
    : > "kvs-archive/KVS_7.0.2_[example.com].zip"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "with an archive the kept override still wins"
    cmp "$IMPORT_STAGING/example.com.nginx_config.txt" "$site/_INSTALL/nginx_config.txt" || fail "the override survives on a re-run with an archive"
    rm -f "kvs-archive/KVS_7.0.2_[example.com].zip" "$IMPORT_STAGING/example.com.nginx_config.txt"
    IMPORT_MODE=true
    pass "the rewrites come from the site, the operator, the archive or the old server"
}

# The site belongs to the account PHP-FPM and cron run as: the init takes
# _INSTALL/nginx_config.txt only with the sha256 the setup exports for the
# rules it has just written there, never for a file it found and left.
test_the_init_gets_the_sha256_of_the_rules_written_for_it() {
    local site="$TEST_DIR/site"

    vouched_for() {
        [ "${KVS_NGINX_REWRITES_SHA256:-}" = "$(sha256sum < "$1" | cut -d' ' -f1)" ] ||
            fail "$2: the init gets ${KVS_NGINX_REWRITES_SHA256:-no sha256}, not that of $1"
    }
    fresh_workdir
    rm -rf "$site" "$IMPORT_STAGING"
    IMPORT_NGINX_CONFIG=""
    IMPORT_NGINX_REWRITES=""
    mkdir -p "$site/_INSTALL"
    echo "rewrite ^/shipped$ /shipped.php last;" > "$site/_INSTALL/nginx_config.txt"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "a shipped file is enough"
    vouched_for "$site/_INSTALL/nginx_config.txt" "the file the imported site shipped"

    rm -rf "$site/_INSTALL"
    echo "rewrite ^/given$ /given.php last;" > "$TEST_DIR/given.txt"
    IMPORT_NGINX_REWRITES="$TEST_DIR/given.txt"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "the operator's file is taken"
    vouched_for "$TEST_DIR/given.txt" "the operator's file"
    IMPORT_NGINX_REWRITES=""
    rm -rf "$site/_INSTALL"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "the kept copy is enough"
    vouched_for "$TEST_DIR/given.txt" "the copy kept from the earlier pass"
    rm -f "$IMPORT_STAGING/example.com.nginx_config.txt"
    rm -rf "$site/_INSTALL"

    # Rules the init takes from the archive: nothing to vouch for, and a
    # sha256 left in the environment is not passed on.
    : > "kvs-archive/KVS_7.0.2_[example.com].zip"
    export KVS_NGINX_REWRITES_SHA256=stale
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "an archive is enough"
    [ -z "${KVS_NGINX_REWRITES_SHA256+set}" ] || fail "the rules of the archive need no sha256: $KVS_NGINX_REWRITES_SHA256"
    rm -f "kvs-archive/KVS_7.0.2_[example.com].zip"

    cat > "$TEST_DIR/old-nginx.conf" <<'NGINX'
server {
    root /var/www/website;
    rewrite ^/videos/$ /videos.php last;
}
NGINX
    IMPORT_NGINX_CONFIG="$TEST_DIR/old-nginx.conf"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "the old server's rules are enough"
    cmp "$IMPORT_STAGING/example.com.nginx_config.txt" "$site/_INSTALL/nginx_config.txt" ||
        fail "the recovered rules are written to the site as kept"
    vouched_for "$IMPORT_STAGING/example.com.nginx_config.txt" "the recovered rules"
    IMPORT_NGINX_CONFIG=""

    # Outside an import: a file in the site is not the setup's to vouch for.
    IMPORT_MODE=false
    rm -f "$IMPORT_STAGING/example.com.nginx_config.txt"
    echo "rewrite ^/found$ /found.php last;" > "$site/_INSTALL/nginx_config.txt"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "outside an import the function is a no-op"
    [ -z "${KVS_NGINX_REWRITES_SHA256+set}" ] || fail "a file the setup did not write was vouched for"
    mkdir -p "$site/admin/include" "$IMPORT_STAGING"
    : > "$site/admin/include/setup.php"
    echo "rewrite ^/kept$ /kept.php last;" > "$IMPORT_STAGING/example.com.nginx_config.txt"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "a re-run restores the kept rules"
    vouched_for "$IMPORT_STAGING/example.com.nginx_config.txt" "the kept rules a re-run restores"
    IMPORT_MODE=true
    unset KVS_NGINX_REWRITES_SHA256
    rm -rf "$site" "$IMPORT_STAGING"
    pass "the init gets the sha256 of the rules written for it, and only of those"
}

# --resume-import selects no rules: the init must still get the sha256 of
# the rules the interrupted pass wrote, from the record that pass kept
# where the site's owner cannot reach it, and the rules go back into
# _INSTALL when the site lost or changed them in the meantime.
test_a_resumed_import_gives_the_init_the_rules_of_the_interrupted_pass() {
    local site="$TEST_DIR/site" vouched

    fresh_workdir
    rm -rf "$site" "$IMPORT_STAGING"
    IMPORT_NGINX_CONFIG=""
    IMPORT_SITE_DIR=$site
    echo "rewrite ^/given$ /given.php last;" > "$TEST_DIR/given.txt"
    IMPORT_NGINX_REWRITES="$TEST_DIR/given.txt"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "the operator's file is taken"
    IMPORT_NGINX_REWRITES=""
    vouched=$KVS_NGINX_REWRITES_SHA256
    unset KVS_NGINX_REWRITES_SHA256
    import_resume_nginx_rewrites "$IMPORT_STAGING" > "$TEST_DIR/out" || fail "a resume takes the rules of the interrupted pass"
    [ "${KVS_NGINX_REWRITES_SHA256:-}" = "$vouched" ] ||
        fail "the resumed init gets ${KVS_NGINX_REWRITES_SHA256:-no sha256}, not that of the interrupted pass ($vouched)"
    [ ! -s "$TEST_DIR/out" ] || fail "the site still has the rules, nothing is put back: $(cat "$TEST_DIR/out")"
    cmp "$TEST_DIR/given.txt" "$site/_INSTALL/nginx_config.txt" || fail "the site's rules are left as they are"

    # The file in the site changed since that pass: the record goes back.
    echo "rewrite ^/planted$ /planted.php last;" > "$site/_INSTALL/nginx_config.txt"
    unset KVS_NGINX_REWRITES_SHA256
    import_resume_nginx_rewrites "$IMPORT_STAGING" > "$TEST_DIR/out" || fail "a changed file is replaced"
    cmp "$TEST_DIR/given.txt" "$site/_INSTALL/nginx_config.txt" || fail "the rules of the interrupted pass are put back"
    [ "${KVS_NGINX_REWRITES_SHA256:-}" = "$vouched" ] || fail "and vouched for after a change"
    grep -q "put back into $site/_INSTALL/nginx_config.txt" "$TEST_DIR/out" || fail "the restore is announced: $(cat "$TEST_DIR/out")"
    rm -rf "$site/_INSTALL"
    unset KVS_NGINX_REWRITES_SHA256
    import_resume_nginx_rewrites "$IMPORT_STAGING" > "$TEST_DIR/out" || fail "a missing _INSTALL is recreated"
    cmp "$TEST_DIR/given.txt" "$site/_INSTALL/nginx_config.txt" || fail "the rules are put back into a recreated _INSTALL"
    [ "${KVS_NGINX_REWRITES_SHA256:-}" = "$vouched" ] || fail "and vouched for without _INSTALL"

    # The rules the site shipped are recorded from the copy the setup
    # hashed, not hashed in the site.
    rm -rf "$site/_INSTALL" "$IMPORT_STAGING"
    mkdir -p "$site/_INSTALL"
    echo "rewrite ^/shipped$ /shipped.php last;" > "$TEST_DIR/shipped.txt"
    cp "$TEST_DIR/shipped.txt" "$site/_INSTALL/nginx_config.txt"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "a shipped file is enough"
    vouched=$KVS_NGINX_REWRITES_SHA256
    rm -rf "$site/_INSTALL"
    unset KVS_NGINX_REWRITES_SHA256
    import_resume_nginx_rewrites "$IMPORT_STAGING" > "$TEST_DIR/out" || fail "a resume takes the shipped rules back"
    cmp "$TEST_DIR/shipped.txt" "$site/_INSTALL/nginx_config.txt" || fail "the shipped rules are put back"
    [ "${KVS_NGINX_REWRITES_SHA256:-}" = "$vouched" ] || fail "the shipped rules are vouched for on a resume"

    # A pass that vouched for nothing (the archive's rules) drops the record
    # of an earlier one: the resumed init gets no sha256, even a stale one.
    rm -rf "$site/_INSTALL"
    : > "kvs-archive/KVS_7.0.2_[example.com].zip"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/out" || fail "an archive is enough"
    export KVS_NGINX_REWRITES_SHA256=stale
    import_resume_nginx_rewrites "$IMPORT_STAGING" > "$TEST_DIR/out" || fail "a resume without a record goes on"
    [ -z "${KVS_NGINX_REWRITES_SHA256+set}" ] || fail "a pass that vouched for nothing gives no sha256: $KVS_NGINX_REWRITES_SHA256"
    [ ! -e "$site/_INSTALL/nginx_config.txt" ] || fail "and writes nothing"
    rm -f "kvs-archive/KVS_7.0.2_[example.com].zip"

    # A record that cannot be read stops the recovery.
    mkdir -p "$IMPORT_STAGING"
    : > "$IMPORT_STAGING/example.com.nginx_config.vouched"
    (import_resume_nginx_rewrites "$IMPORT_STAGING") > "$TEST_DIR/out" 2>&1 && fail "an empty record must stop the recovery"
    grep -q "recovery stopped" "$TEST_DIR/out" || fail "the stop is explained: $(cat "$TEST_DIR/out")"
    unset KVS_NGINX_REWRITES_SHA256 IMPORT_SITE_DIR
    rm -rf "$site" "$IMPORT_STAGING"
    pass "a resumed import gives the init the rules of the interrupted pass"
}

test_the_archive_is_optional_but_must_match_the_site
test_the_encoding_of_the_imported_site_decides
test_unknown_archive_keeps_the_existing_loader_setting
test_the_old_configuration_is_saved_next_to_the_import_marker
test_the_rewrites_come_from_the_site_the_operator_the_archive_or_the_old_server
test_the_init_gets_the_sha256_of_the_rules_written_for_it
test_a_resumed_import_gives_the_init_the_rules_of_the_interrupted_pass

echo "All $TESTS_RUN import-without-archive tests passed."
