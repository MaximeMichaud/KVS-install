#!/bin/bash
# Exercise the rendered native vhost with a broad, harmless PHP rewrite.
set -euo pipefail
cd "$(dirname "$0")/.."
image=$(docker/bin/resolve-bases.sh --get nginx)
docker image inspect "$image" >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/config" "$work/ssl/example.test" "$work/site/admin/plugins/x"
cp -R conf/nginx/globals "$work/globals"
cp conf/nginx/conf.d/domain.conf "$work/config/site.conf"
(
    set +u
    source ./kvs-install.sh
    DOMAIN=example.test PHP=8.3 USE_WWW=false
    set_site_hostnames
    render_nginx_site_config "$work/config/site.conf"
)
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 1 \
    -subj /CN=example.test -keyout "$work/ssl/example.test/key.pem" -out "$work/ssl/example.test/cert.pem" 2>/dev/null
for ext in css js png; do printf 'plugin asset' > "$work/site/admin/plugins/x/file.$ext"; done
for path in admin/include/x.php admin/plugins/x/y.php contents/x.php blocks/x.php langs/x.php template/x.php tmp/x.php \
    admin/include/uploader.php admin/include/get_upload_status.php; do
    mkdir -p "$work/site/${path%/*}"
    touch "$work/site/$path"
done
chmod -R a+rX "$work/site"
for dir in blocks langs template tmp; do
    printf 'location /%s/ { internal; }\n' "$dir"
done > "$work/globals/kvs.conf"
printf '%s\n' 'location ~* \.php$ { return 200 "imported PHP handler"; }' >> "$work/globals/kvs.conf"
cat > "$work/nginx.conf" <<'NGINX'
worker_processes 1;
thread_pool default threads=2;
events {}
http {
    include mime.types;
    include /etc/nginx/conf.d/*.conf;
}
NGINX
docker run -i --rm --pull never --network none --memory 64m --pids-limit 32 \
    -v "$work/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$work/config:/etc/nginx/conf.d:ro" \
    -v "$work/globals:/etc/nginx/globals:ro" -v "$work/ssl:/etc/nginx/ssl:ro" -v "$work/site:/var/www/example.test:ro" \
    --entrypoint sh "$image" -eu <<'SH'
nginx -t
nginx
status() {
    curl --max-time 5 --noproxy '*' -ksS --resolve example.test:443:127.0.0.1 \
        -o /tmp/response -w '%{http_code}' "https://example.test/$1"
}
failed=0
for path in admin/include/x.php admin/plugins/x/y.php contents/x.php blocks/x.php langs/x.php template/x.php tmp/x.php; do
    code=$(status "$path")
    echo "$path: HTTP $code"
    case "$code" in
        403|404) ;;
        *) echo "FAIL: expected the native guard to deny $path" >&2; failed=1 ;;
    esac
done
check_served() {
    code=$(status "$1")
    echo "$1: HTTP $code"
    if [ "$code" != 200 ] || [ "$(cat /tmp/response)" != "$2" ]; then
        echo "FAIL: unexpected response for $1" >&2
        failed=1
    fi
}
for ext in css js png; do check_served "admin/plugins/x/file.$ext" 'plugin asset'; done
for script in uploader get_upload_status; do check_served "admin/include/$script.php" 'imported PHP handler'; done
nginx -s stop
exit "$failed"
SH
echo 'PASS: native PHP guards precede imported rewrites, plugin assets and upload routes remain available'
