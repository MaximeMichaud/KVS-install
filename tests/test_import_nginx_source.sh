#!/bin/bash
# Recover routing from a source report into a fresh destination, using only fixtures.
# Domain changes in individual cases must remain inside their test subshell.
# shellcheck disable=SC2034,SC2016,SC2329,SC2030,SC2031
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-nginx-source.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
for name in import_prepare_source_nginx_rewrites import_ensure_nginx_rewrites import_save_nginx_config import_inspect_remote; do
    awk -v signature="$name() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$ROOT_DIR/docker/setup.sh"
done > "$TEST_DIR/setup-functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/setup-functions.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); echo "ok $passed - $*"; }

cat > "$TEST_DIR/source.conf" <<'NGINX'
# configuration file /etc/nginx/nginx.conf:
http { include sites-enabled/*; }
# configuration file /etc/nginx/sites-enabled/other.conf:
server { root /srv/other; rewrite ^ /other last; }
# configuration file /etc/nginx/sites-enabled/example.conf:
server {
    listen 443 ssl;
    root $base;
    set $base /srv/example;
    error_page 404 /404.php;
    include common/site.conf;
    include moderation-privacy.conf;
}
# configuration file /etc/nginx/common/site.conf:
access_log /var/log/nginx/example.log;
include snippets/routes.conf;
rewrite ^/ordinary$ /ordinary.php last;
# configuration file /etc/nginx/snippets/routes.conf:
location /private/ {
    if ($arg_access != "yes") { return 403; }
    rewrite ^/private/(.*)$ /asset/$1 last;
}
location /asset/ {
    internal;
    add_header Cache-Control "private, no-store" always;
    include fastcgi_params;
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    fastcgi_param SCRIPT_FILENAME $document_root/handler.php;
}
# configuration file /etc/nginx/fastcgi_params:
fastcgi_param REQUEST_METHOD $request_method;
fastcgi_param QUERY_STRING $query_string;
NGINX
cat "$ROOT_DIR/tests/fixtures/nginx-auth-request.conf" >> "$TEST_DIR/source.conf"

# Match the report format received through the existing SSH detection.
awk '{ printf "nginx_config_%d=%s\n", NR, $0 }' "$TEST_DIR/source.conf" > "$TEST_DIR/report"
RED='' NC='' DOMAIN=example.test IMPORT_MODE=true IMPORT_NGINX_REWRITES=source
IMPORT_OLD_PATH=/srv/example IMPORT_REMOTE_DIR=/srv/example IMPORT_REUSE_SITE_DIR=''
IMPORT_STAGING="$TEST_DIR/import"
IMPORT_NGINX_CONFIG="$TEST_DIR/received.conf"
site="$TEST_DIR/fresh-site"
import_nginx_config_save "$TEST_DIR/report" "$IMPORT_NGINX_CONFIG" >/dev/null
import_prepare_source_nginx_rewrites
[ ! -e "$site" ] || fail 'preparation touched the site before transfer'
[ ! -e "$IMPORT_STAGING" ] || fail 'preparation overwrote persisted rules'
import_ensure_nginx_rewrites "$site" > "$TEST_DIR/setup.log"
output="$site/_INSTALL/nginx_config.txt"
grep -Fxq 'location /private/ {' "$output" || fail 'missing original location'
grep -Fxq '    if ($arg_access != "yes") {' "$output" || fail 'lost condition scope'
grep -Fxq '    rewrite ^/private/(.*)$ /asset/$1 last;' "$output" || fail 'lost scoped rewrite'
grep -Fxq 'location /asset/ {' "$output" || fail 'lost sibling handler'
grep -Fxq '    internal;' "$output" || fail 'lost handler protection'
grep -Fxq '    fastcgi_pass php-fpm:9000;' "$output" || fail 'PHP socket not adapted'
grep -Fxq '    fastcgi_param REQUEST_METHOD $request_method;' "$output" || fail 'FastCGI include not expanded'
grep -Fxq 'error_page 404 /404.php;' "$output" || fail 'lost fallback'
grep -Fxq 'rewrite ^/ordinary$ /ordinary.php last;' "$output" || fail 'lost ordinary rule'
grep -Fxq '    auth_request /_screen_auth;' "$output" || fail 'lost authorization subrequest'
grep -Fxq '    auth_request_set $screen_check $upstream_http_x_auth_check;' "$output" || fail 'lost authorization result'
grep -Fxq 'location = /_screen_auth {' "$output" || fail 'lost exact authorization handler'
grep -Fxq '    fastcgi_param SCREEN_VIDEO_ID $screen_video;' "$output" || fail 'lost authorization parameters'
grep -Fxq '    fastcgi_pass_request_body off;' "$output" || fail 'lost body suppression'
grep -Fxq '    fastcgi_param CONTENT_LENGTH "";' "$output" || fail 'lost empty body length'
if grep -Eq 'unix:|/srv/|include |^listen |^rewrite \^/private/' "$output"; then
    fail 'output retains source dependencies or a flattened rewrite'
fi
cmp "$output" "$IMPORT_STAGING/$DOMAIN.nginx_config.txt" || fail 'source output not saved'
pass 'a fresh destination recovers complete scoped fragments from a source report'

cp "$output" "$TEST_DIR/expected.conf"
printf 'rewrite ^ /stock last;\n' > "$output"
IMPORT_MODE=false IMPORT_NGINX_CONFIG='' IMPORT_NGINX_SOURCE_RULES=''
(
    export RED NC DOMAIN IMPORT_MODE IMPORT_NGINX_REWRITES IMPORT_STAGING
    bash -eu -c 'source "$1"; import_ensure_nginx_rewrites "$2"' bash "$TEST_DIR/setup-functions.sh" "$site"
) > "$TEST_DIR/setup.log"
cmp "$TEST_DIR/expected.conf" "$output" || fail 'a later run lost source rules'
pass 'a fresh process restores saved source rules without contacting the old server'

# An unsupported dependency must not replace either existing rules file.
assert_refused() {
    IMPORT_MODE=true IMPORT_NGINX_CONFIG="$TEST_DIR/candidate.conf" IMPORT_NGINX_SOURCE_RULES=''
    if (import_ensure_nginx_rewrites "$site") > "$TEST_DIR/error" 2>&1; then fail "$1 was accepted"; fi
    cmp "$TEST_DIR/expected.conf" "$output" || fail "$1 changed active staging"
    cmp "$TEST_DIR/expected.conf" "$IMPORT_STAGING/$DOMAIN.nginx_config.txt" || fail "$1 changed saved rules"
    grep -q IMPORT_NGINX_REWRITES "$TEST_DIR/error" || fail "$1 omitted the file alternative"
    pass "$1 stops without replacing existing rules"
}

sed 's@unix:/run/php/php8.3-fpm.sock@unix:/run/other.sock@' "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
assert_refused 'an unknown upstream'
grep -Fq '/etc/nginx/snippets/routes.conf:9: fastcgi_pass is not a supported local PHP backend' "$TEST_DIR/error" ||
    fail 'unsupported backend error must identify its original file and line'
if grep -Fq '/run/other.sock' "$TEST_DIR/error"; then fail 'diagnostics exposed a directive argument'; fi
sed 's@fastcgi_param SCRIPT_FILENAME \$document_root/handler.php;@fastcgi_param SCRIPT_FILENAME /srv/example/handler.php;@' \
    "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
assert_refused 'an absolute script path'
sed 's@internal;@alias /srv/shared/;@' "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
assert_refused 'an external filesystem dependency'
sed 's@include fastcgi_params;@include unavailable.conf;@' "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
assert_refused 'an unavailable include'
sed 's@location /private/@location /@' "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
assert_refused 'a root location conflicting with the target vhost'

sed 's@location = /_screen_auth@location = /different_auth@' "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
assert_refused 'an authorization endpoint missing from the imported routing'
grep -q 'auth_request requires an imported exact internal location' "$TEST_DIR/error" || fail 'missing authorization endpoint was not explained'
sed '/^internal;$/d' "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
assert_refused 'an authorization endpoint without internal protection'
sed 's@auth_request /_screen_auth;@auth_request $arg_auth;@' "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
assert_refused 'a dynamic authorization URI'
sed 's@include moderation-privacy-backend.conf;@include missing-backend.conf;@' "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
assert_refused 'an authorization backend missing from the source dump'

cat > "$TEST_DIR/candidate.conf" <<'NGINX'
# configuration file /etc/nginx/unrelated.conf:
server { root /srv/other; include unrelated-auth.conf; }
# configuration file /etc/nginx/unrelated-auth.conf:
location = /_screen_auth { internal; return 204; }
rewrite ^/other$ /index.php last;
NGINX
sed 's@location = /_screen_auth@location = /different_auth@' "$TEST_DIR/source.conf" >> "$TEST_DIR/candidate.conf"
assert_refused 'an authorization endpoint present only in another virtual host'

cat > "$TEST_DIR/candidate.conf" <<'NGINX'
server {
    root /srv/example;
    rewrite ^/ordinary$ /ordinary.php last;
    location /private/ { auth_request /_screen_auth; }
    location = /_screen_auth { internal; return 403; }
}
NGINX
assert_refused 'inline authorization outside a complete imported fragment'
if import_nginx_rewrites_from_config "$TEST_DIR/candidate.conf" /srv/example > "$TEST_DIR/result" 2> "$TEST_DIR/error"; then
    fail 'plain extraction discarded inline authorization'
fi
[ ! -s "$TEST_DIR/result" ] || fail 'plain extraction emitted rules without authorization'
pass 'plain extraction refuses to discard authorization from an inline location'

sed '/listen 443 ssl;/a\    auth_request /_screen_auth;\n    auth_request_set $server_check $upstream_status;' \
    "$TEST_DIR/source.conf" | sed '/location = \/_screen_auth {/a\    auth_request off;' > "$TEST_DIR/candidate.conf"
import_nginx_rewrites_from_config "$TEST_DIR/candidate.conf" /srv/example '' source > "$TEST_DIR/result"
grep -Fxq 'auth_request /_screen_auth;' "$TEST_DIR/result" || fail 'server authorization was discarded'
grep -Fxq 'auth_request_set $server_check $upstream_status;' "$TEST_DIR/result" || fail 'server authorization result was discarded'
grep -Fxq '    auth_request off;' "$TEST_DIR/result" || fail 'explicit authorization inheritance override was discarded'
pass 'server authorization and an explicit off override retain their original scope'

cat "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
cat >> "$TEST_DIR/candidate.conf" <<'NGINX'
# configuration file /etc/nginx/sites-enabled/alternate.conf:
server { root /srv/example; rewrite ^ /different.php last; }
NGINX
assert_refused 'different routing in matching virtual hosts'

# Equivalent HTTP/HTTPS virtual hosts must not duplicate their locations.
cat "$TEST_DIR/source.conf" > "$TEST_DIR/candidate.conf"
cat >> "$TEST_DIR/candidate.conf" <<'NGINX'
# configuration file /etc/nginx/sites-enabled/duplicate.conf:
server {
    root /srv/example;
    error_page 404 /404.php;
    include common/site.conf;
    include moderation-privacy.conf;
}
NGINX
import_nginx_rewrites_from_config "$TEST_DIR/candidate.conf" /srv/example '' source > "$TEST_DIR/result"
[ "$(grep -c '^location /private/' "$TEST_DIR/result")" -eq 1 ] || fail 'duplicate server fragments were emitted'
pass 'identical routing in multiple virtual hosts is emitted once'

# The main site, CDN endpoints and a development vhost may share a root.
# Only the original site domain and its www alias may contribute routing.
sed '/listen 443 ssl;/a\    server_name example.test www.example.test;' \
    "$TEST_DIR/source.conf" > "$TEST_DIR/named-source.conf"
cat >> "$TEST_DIR/named-source.conf" <<'NGINX'
# configuration file /etc/nginx/sites-enabled/cdn.conf:
server {
    server_name cdn.example.test;
    root /srv/example/contents;
    location / { rewrite ^ /cdn last; }
}
# configuration file /etc/nginx/sites-enabled/dev.conf:
server {
    server_name dev.example.test;
    root /srv/example;
    rewrite ^ /development last;
}
NGINX
import_nginx_rewrites_from_config "$TEST_DIR/named-source.conf" /srv/example '' source example.test > "$TEST_DIR/named-result"
import_nginx_rewrites_from_config "$TEST_DIR/source.conf" /srv/example '' source > "$TEST_DIR/unnamed-result"
cmp "$TEST_DIR/named-result" "$TEST_DIR/unnamed-result" || fail 'CDN or development routing contaminated the original host'
pass 'source host excludes CDN and development virtual hosts sharing the site directory'
(
    DOMAIN=destination.test IMPORT_DETECTED_DOMAIN=example.test
    IMPORT_NGINX_CONFIG="$TEST_DIR/named-source.conf"
    import_prepare_source_nginx_rewrites
    printf '%s\n' "$IMPORT_NGINX_SOURCE_RULES" > "$TEST_DIR/prepared-result"
)
# Command substitution removes the trailing newline, so compare normalized text.
[ "$(cat "$TEST_DIR/prepared-result")" = "$(cat "$TEST_DIR/unnamed-result")" ] ||
    fail 'setup selected the destination hostname instead of the source hostname'
pass 'setup selects the detected source host when the destination domain differs'

sed 's/server_name example.test www.example.test;/server_name www.example.test;/' \
    "$TEST_DIR/named-source.conf" > "$TEST_DIR/www-source.conf"
import_nginx_rewrites_from_config "$TEST_DIR/www-source.conf" /srv/example '' source example.test > "$TEST_DIR/named-result"
cmp "$TEST_DIR/named-result" "$TEST_DIR/unnamed-result" || fail 'the canonical www site was not selected'
pass 'source domain also selects its canonical www virtual host'

if import_nginx_rewrites_from_config "$TEST_DIR/named-source.conf" /srv/example '' source missing.test \
    > "$TEST_DIR/named-result" 2> "$TEST_DIR/error"; then fail 'unknown source domain selected another site'; fi
[ ! -s "$TEST_DIR/named-result" ] || fail 'unknown source domain emitted partial routing'
grep -q 'no exact source server_name' "$TEST_DIR/error" || fail 'missing source host must be explained'
pass 'missing source host is refused without falling back to another site'

cat "$TEST_DIR/named-source.conf" > "$TEST_DIR/conflicting-source.conf"
cat >> "$TEST_DIR/conflicting-source.conf" <<'NGINX'
# configuration file /etc/nginx/sites-enabled/conflicting.conf:
server { server_name example.test; root /srv/example; rewrite ^ /different last; }
NGINX
if import_nginx_rewrites_from_config "$TEST_DIR/conflicting-source.conf" /srv/example '' source example.test \
    > "$TEST_DIR/named-result" 2> "$TEST_DIR/error"; then fail 'conflicting original-host routes were accepted'; fi
[ ! -s "$TEST_DIR/named-result" ] || fail 'conflicting hosts emitted partial routing'
pass 'different routes for the same original hostname still fail closed'

# The ordinary extraction mode still refuses this configuration.
if import_nginx_rewrites_from_config "$TEST_DIR/source.conf" /srv/example > "$TEST_DIR/result" 2> "$TEST_DIR/error"; then
    [ ! -s "$TEST_DIR/result" ] || fail 'plain extraction accepted scoped fragments'
fi
[ ! -s "$TEST_DIR/result" ] || fail 'plain extraction emitted partial rules'
pass 'source recovery is opt-in'

# Exercise actual headless inspection with a fixture-backed SSH boundary.
# Unsupported routing must fail before any site take-over or transfer preparation.
(
    cd "$TEST_DIR"
    mkdir logs
    LOG_DIR="$TEST_DIR/logs"
    HEADLESS=y GREEN='' YELLOW='' CYAN=''
    IMPORT_TRANSFER_JOBS=4 IMPORT_SIZE_TIMEOUT=300 IMPORT_REMOTE_PASSWORD=fixture
    IMPORT_REMOTE_HOST=example.test IMPORT_REMOTE_PORT=22 IMPORT_REMOTE_USER=root
    IMPORT_SSH_KEY='' IMPORT_SSH_ACCEPT_NEW=y IMPORT_EXCLUDE='' IMPORT_INCLUDE=''
    IMPORT_DATABASE_FORMAT=auto IMPORT_REMOTE_SUDO_ERROR=''
    IMPORT_EXPORTER="$ROOT_DIR/kvs-export.sh"
    IMPORT_NGINX_REWRITES=source IMPORT_MODE=true IMPORT_NGINX_SOURCE_RULES=''
    import_ensure_tool() { return 0; }
    import_ssh_setup() { IMPORT_SSH_TARGET=root@example.test; }
    import_ssh_close() { return 0; }
    import_remote_privileges() { IMPORT_REMOTE_PRIVILEGES=root; }
    import_remote_show_entries() { return 0; }
    import_remote_show_servers() { return 0; }
    import_remote_load_excludes() { return 0; }
    import_remote_free_space_check() { return 0; }
    import_destination_ready() { touch "$TEST_DIR/destination-reached"; }
    import_remote_detect() { cp "$TEST_DIR/ssh-report" "$3"; }
    make_report() {
        printf 'kvs_export=1\nsite_dir=/srv/example\nproject_path=/srv/example\nkvs_version=7.0.2\n'
        printf 'tables_prefix=ktvs_\ndb_ok=yes\ndb_non_transactional=0\nrsync=yes\ncompressor=gzip\n'
        printf 'domain=example.test\n'
        awk '{ printf "nginx_config_%d=%s\n", NR, $0 }' "$1"
    }
    sed 's@unix:/run/php/php8.3-fpm.sock@unix:/run/unknown.sock@' named-source.conf > incompatible.conf
    make_report incompatible.conf > ssh-report
    if (import_inspect_remote) > inspection.log 2>&1; then fail 'headless inspection accepted incompatible routing'; fi
    [ ! -e destination-reached ] || fail 'headless inspection prepared the site before refusing routing'
    cmp expected.conf "$IMPORT_STAGING/$DOMAIN.nginx_config.txt" || fail 'failed inspection overwrote saved routing'
    make_report named-source.conf > ssh-report
    import_inspect_remote > inspection.log 2>&1
    [ -e destination-reached ] || fail 'compatible routing did not complete headless inspection'
    [[ "$IMPORT_NGINX_SOURCE_RULES" == *'fastcgi_pass php-fpm:9000;'* ]] || fail 'inspection did not prepare the PHP adaptation'
    IMPORT_SITE_VERSION=''  # No later test may reuse inspection state.
)
pass 'headless SSH inspection prepares compatible source routing and rejects unsupported routing before transfer'
echo "All $passed nginx source recovery tests passed."
