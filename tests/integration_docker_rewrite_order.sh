#!/bin/bash
# Check the first matching regex after expanding a harmless site asset rule.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import re

for path in ('conf/nginx/templates/kvs.conf.tpl', 'docker/multi-site/nginx/kvs-caddy.conf.template'):
    config = Path(path).read_text().replace('include /etc/nginx/includes/kvs-rewrites.conf;',
                                           r'location ~* \.(js|css|png|txt)$ { expires 1h; }')
    rules = [(re.compile(pattern, re.I if kind == '~*' else 0), body.strip())
             for kind, pattern, body in re.findall(r'^    location (~\*?) (\S+) (\{.*?)(?=^    }|^    location|\Z)', config, re.M | re.S)]
    cases = {'admin/data/file.js': 'deny all;', 'admin/include/file.css': 'deny all;',
             'admin/plugins/p/file.txt': 'deny all;', '.fixture/file.png': 'deny all;',
             'admin/include/uploader.php': 'try_files', 'admin/include/get_upload_status.php': 'try_files'}
    for ext in ('js', 'css', 'png'):
        cases['admin/plugins/p/file.' + ext] = 'expires 1h;'
    for resource, expected in cases.items():
        body = next((body for pattern, body in rules if pattern.search('/' + resource)), '')
        assert expected in body, (path, resource, body)
PY
image=$(docker/bin/resolve-bases.sh --get nginx)
docker image inspect "$image" >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/site/admin/data" "$work/site/admin/plugins/p" "$work/ssl/fixture.test"
for file in admin/data/file.js admin/plugins/p/file.{js,css,png}; do
    echo fixture > "$work/site/$file"
done
printf '%s\n' 'location ~* \.(js|css|png|txt)$ { expires 1h; }' > "$work/kvs-rewrites.conf"
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj /CN=fixture.test \
    -keyout "$work/ssl/fixture.test/key.pem" -out "$work/ssl/fixture.test/cert.pem" >/dev/null 2>&1
export DOMAIN=fixture.test PUBLIC_HOST_RULES='fixture.test 1;' MAIN_SERVER_NAME=fixture.test
export PUBLIC_SERVER_NAMES=fixture.test KVS_ROOT=/fixture/site PHP_FPM_UPSTREAM=localhost:9000
export PROJECT_HTTPS_PORT=443 REDIRECT_HOST=fixture.test HTTPS_PORT_SUFFIX='' WWW_REDIRECT_BLOCK='' RESOLVER_LINE=''
for template in conf/nginx/templates/kvs.conf.tpl docker/multi-site/nginx/kvs-caddy.conf.template; do
    # shellcheck disable=SC2016  # Only substitute template variables.
    envsubst '${DOMAIN} ${PUBLIC_HOST_RULES} ${MAIN_SERVER_NAME} ${PUBLIC_SERVER_NAMES} ${KVS_ROOT} ${PHP_FPM_UPSTREAM} ${PROJECT_HTTPS_PORT} ${REDIRECT_HOST} ${HTTPS_PORT_SUFFIX} ${WWW_REDIRECT_BLOCK} ${RESOLVER_LINE}' \
        < "$template" > "$work/site.conf"
    scheme=https port=443
    if [[ "$template" == *caddy* ]]; then scheme=http port=80; fi
    docker run --rm --network none --pull never -v "$work/site:/fixture/site:ro" \
        -v "$work/ssl:/etc/nginx/ssl:ro" -v "$work/site.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$work/kvs-rewrites.conf:/etc/nginx/includes/kvs-rewrites.conf:ro" \
        --entrypoint sh "$image" -ec '
            sed -i "s/worker_processes  *auto;/worker_processes 1;/" /etc/nginx/nginx.conf
            nginx
            get() { curl -ksS --noproxy "*" --connect-to "fixture.test:$2:localhost:$2" --max-time 5 "$1://fixture.test/$3" "$4" "$5"; }
            [ "$(get "$1" "$2" admin/data/file.js -w "%{http_code}" | tail -c 3)" = 403 ]
            for ext in js css png; do
                [ "$(get "$1" "$2" "admin/plugins/p/file.$ext" -w "%{http_code}")" = "$(printf "fixture\n200")" ]
            done
        ' sh "$scheme" "$port"
done
echo 'PASS: imported asset rules respect both Docker origin policies'
