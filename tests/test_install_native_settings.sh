#!/bin/bash
# Execute the native storage queries on a fixture with local and external rows.
set -eo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source ./kvs-install.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
DOMAIN=media.example.com
URL="www.$DOMAIN"
KVS_PATH="$work/site"
mkdir -p "$KVS_PATH/admin/include"
cat >"$KVS_PATH/admin/include/setup.php" <<'PHP'
$config['tables_prefix'] = 'site_';
PHP

# Run the installer's SQL against persistent rows. Adapt MariaDB's upsert spelling
# and the functions SQLite does not provide.
cat >"$work/query.py" <<'PY'
import ipaddress
import re
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as db:
    db.create_function('regexp', 2, lambda pattern, value: bool(re.search(pattern, value)))
    db.create_function('regexp_replace', 3, lambda value, pattern, new: re.sub(pattern, new, value))
    db.create_function('substring_index', 3, lambda s, delim, n:
                       s.split(delim, 1)[0] if n == 1 else s.rsplit(delim, 1)[-1])
    def is_ipv6(value):
        try:
            return ipaddress.ip_address(value).version == 6
        except ValueError:
            return False
    db.create_function('is_ipv6', 1, is_ipv6)
    db.create_function('now', 0, lambda: '2000-01-01')
    db.create_function('json_unquote', 1, lambda value: value)
    if len(sys.argv) == 2:
        sql = sys.stdin.read().replace('ON DUPLICATE KEY UPDATE', 'ON CONFLICT DO UPDATE SET')
        db.executescript(sql)
    else:
        for row in db.execute(sys.argv[2]):
            print(*row, sep='|')
PY
query() { python3 "$work/query.py" "$work/storage.db" "$@"; }
mariadb() {
  case "$*" in
    "$DOMAIN") query ;;
    "-N $DOMAIN -e "*) query "$4" ;;
    *) return 2 ;;
  esac
}
fail() { echo "FAIL: $*" >&2; exit 1; }

query <<'SQL'
CREATE TABLE site_settings (section TEXT, satellite_prefix TEXT, value TEXT, added_date TEXT, version_control INTEGER,
    PRIMARY KEY(section, satellite_prefix));
SQL
limits() {
  query "SELECT json_extract(value,'$.server_type'), json_extract(value,'$.memory_limit_default'), json_extract(value,'$.file_upload_max_size') FROM site_settings"
}
configure_kvs_system_settings >/dev/null || fail 'fresh settings failed'
[[ "$(limits)" == 'nginx|256|2048' ]] || fail 'fresh system limits are wrong'
query <<'SQL'
UPDATE site_settings SET value = json_set(value,'$.server_type','other','$.memory_limit_default',384,'$.file_upload_max_size',128);
SQL
configure_kvs_system_settings >/dev/null || fail 'existing settings failed'
[[ "$(limits)" == 'nginx|384|128' ]] || fail 'existing system limits were reset'

query <<'SQL'
CREATE TABLE site_admin_servers (id INTEGER PRIMARY KEY, path TEXT, urls TEXT, streaming_skip_ssl_check INTEGER);
CREATE TABLE site_admin_conversion_servers (path TEXT);
INSERT INTO site_admin_servers VALUES
    (1, '%PROJECT_PATH%', 'http://media.example.com:8080/contents/a', 0),
    (2, '', 'https://other.example.com/contents/b', 0),
    (3, '', 'https://media.example.com.cdn.test/contents/c', 1),
    (4, '', 'https://www.media.example.com:8443/custom', 0),
    (5, '', 'https://media.example.com:8443', 0),
    (6, '', 'http://www.media.example.com', 0);
SQL
flags() { query 'SELECT streaming_skip_ssl_check FROM site_admin_servers ORDER BY id' | paste -sd,; }
configure_kvs_servers >/dev/null || fail 'mixed storage rejected'
[[ "$(flags)" == 1,0,1,1,1,1 ]] || fail 'initial TLS settings changed the wrong storage rows'
[[ "$(query 'SELECT urls FROM site_admin_servers WHERE id=1')" == "https://$URL/contents/a" ]] || fail 'local URL was not updated'
CERTIFICATE_MODE=public configure_kvs_servers_tls >/dev/null || fail 'public certificate rejected'
[[ "$(flags)" == 0,0,1,0,0,0 ]] || fail 'public certificate changed the wrong storage rows'
CERTIFICATE_MODE=selfsigned configure_kvs_servers_tls >/dev/null || fail 'self-signed certificate rejected'
[[ "$(flags)" == 1,0,1,1,1,1 ]] || fail 'self-signed certificate changed the wrong storage rows'

query <<'SQL'
DELETE FROM site_admin_servers WHERE id <> 5;
SQL
configure_kvs_servers >"$work/log" 2>&1 || fail 'a local origin alone was rejected'
if grep -iq external "$work/log"; then fail 'a local origin was classified as external'; fi
query <<'SQL'
CREATE TRIGGER keep_tls BEFORE UPDATE OF streaming_skip_ssl_check ON site_admin_servers
BEGIN SELECT RAISE(IGNORE); END;
SQL
if CERTIFICATE_MODE=public configure_kvs_servers_tls >/dev/null 2>&1; then fail 'a local TLS mismatch was accepted'; fi
query <<'SQL'
DROP TRIGGER keep_tls;
DELETE FROM site_admin_servers;
INSERT INTO site_admin_servers VALUES
    (2, '', 'https://other.example.com/contents/b', 0),
    (3, '', 'https://media.example.com.cdn.test/contents/c', 1);
SQL
configure_kvs_servers >"$work/log" 2>&1 || fail 'external-only storage rejected'
grep -iq external "$work/log" || fail 'external-only storage was not reported'
[[ "$(query 'SELECT urls FROM site_admin_servers ORDER BY id')" == $'https://other.example.com/contents/b\nhttps://media.example.com.cdn.test/contents/c' ]] ||
  fail 'external storage URLs changed'
query <<'SQL'
DELETE FROM site_admin_servers;
SQL
if configure_kvs_servers >/dev/null 2>&1; then fail 'empty storage accepted'; fi
# All three operations must recognize the same dotted local origin.
dotted="http://$DOMAIN.:8443/contents/a"
query <<<"INSERT INTO site_admin_servers VALUES (1,'','$dotted',0);"
query <<'SQL'
CREATE TRIGGER keep_url BEFORE UPDATE OF urls ON site_admin_servers
BEGIN SELECT RAISE(IGNORE); END;
SQL
if configure_kvs_servers >/dev/null 2>&1; then fail 'a stale dotted local URL was accepted'; fi
query 'DROP TRIGGER keep_url'
configure_kvs_servers >/dev/null || fail 'a dotted local URL was rejected'
[[ $(query 'SELECT urls FROM site_admin_servers') == "https://$URL/contents/a" ]] || fail 'a dotted URL was not rewritten'
query <<<"UPDATE site_admin_servers SET urls='https://$DOMAIN.:65535/custom', streaming_skip_ssl_check=0;"
configure_kvs_servers >"$work/log" 2>&1 || fail 'a dotted custom URL was rejected'
if grep -iq external "$work/log"; then fail 'a dotted custom URL was classified as external'; fi
[[ $(flags) == 1 ]] || fail 'a dotted custom URL missed the TLS filter'

for invalid in '' 'ftp://cdn.example.test' 'https://' 'https:///path' 'https://:8443' \
               'https://cdn..test' 'https://cdn-.test' 'https://[:::]' \
               'https://cdn.example.test:99999' 'https://cdn.example.test:65536' \
               'http://[2001:db8::1]:65536' "http://$DOMAIN.:65536/contents/a" \
               "http://$DOMAIN:0/contents/a" 'https://cdn.example.test:000'; do
  query <<<"DELETE FROM site_admin_servers; INSERT INTO site_admin_servers VALUES (1,'','$invalid',0);"
  if configure_kvs_servers >/dev/null 2>&1; then fail "invalid storage accepted: '$invalid'"; fi
done
for origin in 'https://cdn.example.test:8443' 'http://[2001:db8::1]:8080' \
              'http://cdn.example.test:1' 'http://[2001:db8::1]:65535' 'https://cdn.example.test:00080'; do
  query <<<"UPDATE site_admin_servers SET urls='$origin';"
  configure_kvs_servers >"$work/log" 2>&1 || fail "external origin rejected: $origin"
  grep -iq external "$work/log" || fail "external origin was not reported: $origin"
  [[ "$(flags)" == 0 ]] || fail "TLS setting changed for $origin"
done
echo 'Native storage settings passed'
