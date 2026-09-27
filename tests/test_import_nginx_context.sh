#!/bin/bash
# Synthetic nginx fixtures: no source-site configuration is used here.
# shellcheck disable=SC2034,SC2016
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-import-nginx-context.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
awk '
    /^import_ensure_nginx_rewrites\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/setup-functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/setup-functions.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
TESTS_RUN=0
pass() { TESTS_RUN=$((TESTS_RUN + 1)); echo "ok $TESTS_RUN - $*"; }

assert_refused() {
    if import_nginx_rewrites_from_config "$TEST_DIR/source.conf" /srv/example > "$TEST_DIR/result" 2> "$TEST_DIR/error"; then
        fail "$1 must be refused"
    fi
    [ ! -s "$TEST_DIR/result" ] || fail "$1 emitted partial rules"
    grep -q IMPORT_NGINX_REWRITES "$TEST_DIR/error" || fail "$1 omitted the explicit-file option"
    pass "$1 fails without partial output"
}

cat > "$TEST_DIR/source.conf" <<'NGINX'
server { root "/srv/example/";
    # Braces in comments do not change the context: } { rewrite ^ /bad;
    rewrite "^/item/([0-9]{1,3});$" "/view?id=$1#part" last;
    rewrite
        ^/old$
        /new last;
    location ~ "^/unused/[0-9]{2}/" { internal; }
}
NGINX
import_nginx_rewrites_from_config "$TEST_DIR/source.conf" /srv/example > "$TEST_DIR/result"
cat > "$TEST_DIR/expected" <<'NGINX'
rewrite "^/item/([0-9]{1,3});$" "/view?id=$1#part" last;
rewrite ^/old$ /new last;
NGINX
cmp "$TEST_DIR/expected" "$TEST_DIR/result" || fail "quoted and multiline directives must be preserved"
pass 'inline blocks, multiline directives, comments and quoted delimiters are parsed'

for body in \
    'location /limited/ { rewrite ^ /target last; }' \
    'if ($arg_preview = yes) { rewrite ^ /target last; }' \
    'location /limited/ { if ($arg_preview = yes) { rewrite ^ /target last; } }' \
    $'location /limited/ { # trailing comment\n rewrite ^ /target last;\n}' \
    $'location\n /limited/\n {\n rewrite ^ /target last;\n }' \
    'set $destination /target; rewrite ^ /$destination last;' \
    'return 403; rewrite ^ /target last;' \
    'break; rewrite ^ /target last;' \
    'if ($arg_preview = no) { return 403; } rewrite ^ /target last;'
do
    printf 'server { rewrite ^/plain$ /plain last; %s root /srv/example; }\n' "$body" > "$TEST_DIR/source.conf"
    assert_refused 'context-dependent rules'
done

cat > "$TEST_DIR/source.conf" <<'NGINX'
# configuration file /etc/nginx/nginx.conf:
http { include sites-enabled/*; }
# configuration file /etc/nginx/sites-enabled/example.conf:
server {
    include snippets/root.conf;
    include snippets/rules.conf;
    location /limited/ { include snippets/rules.conf; }
}
# configuration file /etc/nginx/snippets/root.conf:
root /srv/example;
# configuration file /etc/nginx/snippets/rules.conf:
rewrite ^ /target last;
NGINX
assert_refused 'the same include used at server and location levels'

cat > "$TEST_DIR/source.conf" <<'NGINX'
# configuration file /etc/nginx/nginx.conf:
http { include sites-enabled/*; }
# configuration file /etc/nginx/sites-enabled/example.conf:
server { root /srv/example; include snippets/rules.conf; }
# configuration file /etc/nginx/snippets/rules.conf:
location /limited/ { if ($arg_preview) { rewrite ^ /target last; } }
NGINX
assert_refused 'nested blocks declared in an included file'

for include in 'missing.conf' 'snippets/*.conf' '${dynamic_path}' 'rules.conf'; do
    cat > "$TEST_DIR/source.conf" <<NGINX
# configuration file /etc/nginx/nginx.conf:
server { root /srv/example; rewrite ^/plain\$ /plain last; include $include; }
# configuration file /etc/nginx/rules.conf:
include rules.conf;
NGINX
    assert_refused 'missing, dynamic or cyclic includes'
done

cat > "$TEST_DIR/source.conf" <<'NGINX'
server { root /srv/example; rewrite ^/plain$ /plain last; }
server { root /srv/example; location /limited/ { rewrite ^ /target last; } }
NGINX
assert_refused 'an unsafe second matching server'
for body in \
    'server { root /srv/example; rewrite ^ /target last;' \
    'server { root /srv/example; rewrite "^/unterminated /target last; }' \
    'server { root /srv/example; rewrite ^/item/[0-9]{2}/$ /target last; }'
do
    printf '%s\n' "$body" > "$TEST_DIR/source.conf"
    assert_refused 'malformed or unsupported syntax'
done

cat > "$TEST_DIR/source.conf" <<'NGINX'
server { root /srv/other; location /limited/ { rewrite ^ /target last; } }
server { root /srv/example; rewrite ^/plain$ /plain last; }
NGINX
[ "$(import_nginx_rewrites_from_config "$TEST_DIR/source.conf" /srv/example)" = 'rewrite ^/plain$ /plain last;' ] || fail 'an unrelated server must not contaminate recovery'
pass 'unrelated nested rules are excluded'

# Real setup selection and disk round trips, with all competing sources present.
RED='' NC='' DOMAIN=example.test IMPORT_MODE=true
IMPORT_NGINX_CONFIG="$TEST_DIR/source.conf"
IMPORT_OLD_PATH=/srv/example IMPORT_REMOTE_DIR='' IMPORT_REUSE_SITE_DIR=''
IMPORT_STAGING="$TEST_DIR/import"
site="$TEST_DIR/site"
mkdir -p "$site/_INSTALL" "$site/admin/include" "$IMPORT_STAGING" "$TEST_DIR/kvs-archive"
cd "$TEST_DIR"
: > "$site/admin/include/setup.php"
: > kvs-archive/KVS_7.0.2_fixture.zip
printf 'rewrite ^ /shipped last;\n' > "$site/_INSTALL/nginx_config.txt"
printf 'rewrite ^ /cached last;\n' > "$IMPORT_STAGING/$DOMAIN.nginx_config.txt"
cat > "$TEST_DIR/explicit.conf" <<'NGINX'
# Complete synthetic fragment; preserve its conditions and formatting.
location /limited/ {
    if ($arg_preview = yes) {
        rewrite ^ /preview last;
    }
    return 403;
}
NGINX
IMPORT_NGINX_REWRITES="$TEST_DIR/explicit.conf"
import_ensure_nginx_rewrites "$site" > "$TEST_DIR/setup-output"
cmp "$TEST_DIR/explicit.conf" "$site/_INSTALL/nginx_config.txt" || fail 'explicit blocks changed'
cmp "$TEST_DIR/explicit.conf" "$IMPORT_STAGING/$DOMAIN.nginx_config.txt" || fail 'explicit file was not persisted'
pass 'an explicit fragment overrides site, archive and saved copy without alteration'

for mode in true false; do
    IMPORT_MODE=$mode
    IMPORT_NGINX_REWRITES=''
    printf 'rewrite ^ /refreshed last;\n' > "$site/_INSTALL/nginx_config.txt"
    (
        export RED NC DOMAIN IMPORT_MODE IMPORT_STAGING IMPORT_NGINX_REWRITES IMPORT_REUSE_SITE_DIR
        bash -eu -c 'source "$1"; import_ensure_nginx_rewrites "$2"' bash "$TEST_DIR/setup-functions.sh" "$site"
    ) > "$TEST_DIR/setup-output"
    cmp "$TEST_DIR/explicit.conf" "$site/_INSTALL/nginx_config.txt" || fail "saved fragment lost on re-run ($mode)"
    IMPORT_NGINX_REWRITES="$TEST_DIR/explicit.conf"
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/setup-output"
    cmp "$TEST_DIR/explicit.conf" "$site/_INSTALL/nginx_config.txt" || fail "explicit file lost on re-run ($mode)"
done
pass 'fresh processes restore the saved fragment after a transfer or a completed import'

for source in "$site/_INSTALL/nginx_config.txt" "$IMPORT_STAGING/$DOMAIN.nginx_config.txt"; do
    IMPORT_NGINX_REWRITES=$source
    import_ensure_nginx_rewrites "$site" > "$TEST_DIR/setup-output"
    cmp "$TEST_DIR/explicit.conf" "$site/_INSTALL/nginx_config.txt" || fail 'using a destination as source corrupted the file'
    cmp "$TEST_DIR/explicit.conf" "$IMPORT_STAGING/$DOMAIN.nginx_config.txt" || fail 'using a destination as source corrupted the saved copy'
done
pass 'the explicit input can be either existing destination'

: > "$TEST_DIR/empty.conf"
for source in "$TEST_DIR/missing.conf" "$TEST_DIR/empty.conf" "$TEST_DIR"; do
    IMPORT_NGINX_REWRITES=$source
    if (import_ensure_nginx_rewrites "$site") > "$TEST_DIR/setup-output" 2>&1; then
        fail 'an invalid explicit source must stop even if other sources exist'
    fi
    cmp "$TEST_DIR/explicit.conf" "$site/_INSTALL/nginx_config.txt" || fail 'invalid input modified the target'
    cmp "$TEST_DIR/explicit.conf" "$IMPORT_STAGING/$DOMAIN.nginx_config.txt" || fail 'invalid input modified the saved copy'
done
pass 'invalid explicit sources leave both existing files intact'

IMPORT_MODE=true IMPORT_NGINX_REWRITES=''
rm -f "$site/_INSTALL/nginx_config.txt" "$IMPORT_STAGING/$DOMAIN.nginx_config.txt" kvs-archive/*.zip
printf 'server { root /srv/example; location /limited/ { rewrite ^ /target last; } }\n' > "$TEST_DIR/source.conf"
if (import_ensure_nginx_rewrites "$site") > "$TEST_DIR/setup-output" 2>&1; then
    fail 'setup must propagate ambiguous recovery failure'
fi
[ ! -e "$site/_INSTALL/nginx_config.txt" ] || fail 'setup wrote a partial target'
[ ! -e "$IMPORT_STAGING/$DOMAIN.nginx_config.txt" ] || fail 'setup persisted a partial target'
grep -q IMPORT_NGINX_REWRITES "$TEST_DIR/setup-output" || fail 'setup omitted the headless override'
pass 'setup stops an ambiguous recovery without writing or persisting a fragment'
echo "All $TESTS_RUN nginx import context tests passed."
