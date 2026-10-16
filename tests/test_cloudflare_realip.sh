#!/bin/bash
# Exercise settings through the actual entrypoint and Compose without
# touching the host's Nginx. Real HTTP/FastCGI tests live in the integration suite.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/var/tmp}/kvs-cloudflare.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
unset CLOUDFLARE_ENABLED MODE COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME

mkdir -p "$TEST_DIR/etc/nginx/globals" "$TEST_DIR/etc/nginx/conf.d" "$TEST_DIR/bin"
printf 'set_real_ip_from 192.0.2.0/24;\n' > "$TEST_DIR/etc/nginx/globals/cloudflare-ip-list.conf"
printf '# Manual configuration must survive.\n' > "$TEST_DIR/etc/nginx/conf.d/manual.conf"
sed \
    -e "s|/etc/nginx|$TEST_DIR/etc/nginx|g" \
    -e "s|/run/kvs-nginx|$TEST_DIR/run/kvs-nginx|g" \
    -e 's|exec /docker-entrypoint.sh "$@"|exec "$@"|' \
    -e '\|^/usr/local/bin/rotate-site-logs &$|c\: # No background task in this fixture.' \
    "$ROOT_DIR/docker/nginx/docker-entrypoint.sh" > "$TEST_DIR/entrypoint.sh"
sed "s|/run/kvs-nginx|$TEST_DIR/run/kvs-nginx|g" \
    "$ROOT_DIR/docker/nginx/cloudflare-realip-check.sh" > "$TEST_DIR/cloudflare-check.sh"
cat > "$TEST_DIR/bin/nginx" <<'SH'
#!/bin/sh
[ "$1" = -T ] || exit 99
if [ "${MOCK_NGINX_FAIL:-false}" = true ]; then
    echo 'nginx: "real_ip_header" directive is duplicate in manual.conf:2' >&2
    exit 1
fi
[ "${MOCK_NGINX_OLD:-false}" != true ] || exit 0
printf '# configuration file %s/run/kvs-nginx/cloudflare-realip.conf:\n' "$CLOUDFLARE_TEST_ROOT"
SH
chmod +x "$TEST_DIR/bin/nginx"
export CLOUDFLARE_TEST_ROOT="$TEST_DIR"
export PATH="$TEST_DIR/bin:$PATH"
runtime="$TEST_DIR/run/kvs-nginx/cloudflare-realip.conf"

# Unset/empty/false preserve manual settings. Repeated starts replace a
# single runtime file, and false removes a previously generated file.
SSL_PROVIDER=none sh "$TEST_DIR/entrypoint.sh" true
[ ! -e "$runtime" ] || fail 'an absent setting enabled Cloudflare'
for value in true true false true ''; do
    CLOUDFLARE_ENABLED="$value" SSL_PROVIDER=none sh "$TEST_DIR/entrypoint.sh" sh "$TEST_DIR/cloudflare-check.sh"
    if [ "$value" = true ]; then
        grep -Fxq 'real_ip_header CF-Connecting-IP;' "$runtime" || fail 'CF header missing'
        [ "$(find "$TEST_DIR/run/kvs-nginx" -type f | wc -l)" -eq 1 ] || fail 'temporary files accumulated'
    else
        [ ! -e "$runtime" ] || fail 'disabling left a generated config'
    fi
    grep -Fxq '# Manual configuration must survive.' "$TEST_DIR/etc/nginx/conf.d/manual.conf" ||
        fail 'a manual file was changed'
done

for value in TRUE yes 1 invalid 'true;return 200;'; do
    if CLOUDFLARE_ENABLED="$value" SSL_PROVIDER=none sh "$TEST_DIR/entrypoint.sh" true > "$TEST_DIR/output" 2>&1; then
        fail "invalid setting accepted: $value"
    fi
    grep -Fq 'CLOUDFLARE_ENABLED must be true or false' "$TEST_DIR/output" || fail 'invalid setting was not explained'
done
for mode in multi unknown; do
    if MODE="$mode" CLOUDFLARE_ENABLED=true SSL_PROVIDER=none sh "$TEST_DIR/entrypoint.sh" true > "$TEST_DIR/output" 2>&1; then
        fail "unsupported mode accepted: $mode"
    fi
    grep -Fq 'single-site mode only' "$TEST_DIR/output" || fail 'unsupported mode was not explained'
done
for flag in MOCK_NGINX_OLD MOCK_NGINX_FAIL; do
    if env "$flag=true" CLOUDFLARE_ENABLED=true SSL_PROVIDER=none sh "$TEST_DIR/entrypoint.sh" sh "$TEST_DIR/cloudflare-check.sh" > "$TEST_DIR/output" 2>&1; then
        fail "$flag allowed a config that cannot activate Cloudflare"
    fi
    grep -Eq 'does not load|existing manual Real IP' "$TEST_DIR/output" || fail 'configuration conflict was not explained'
done
: > "$TEST_DIR/etc/nginx/globals/cloudflare-ip-list.conf"
if CLOUDFLARE_ENABLED=true SSL_PROVIDER=none sh "$TEST_DIR/entrypoint.sh" true > "$TEST_DIR/output" 2>&1; then
    fail 'an empty Cloudflare list was accepted'
fi
grep -Fq 'non-empty Cloudflare IP list' "$TEST_DIR/output" || fail 'empty list was not explained'

# The setup validates a saved setting, including during import recovery.
awk '
    /^check_cloudflare_configuration\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/setup-check.sh"
for value in false true ''; do
    CLOUDFLARE_ENABLED="$value" MODE=single bash -c '. "$1"; check_cloudflare_configuration' bash "$TEST_DIR/setup-check.sh"
done
if CLOUDFLARE_ENABLED=invalid bash -c '. "$1"; check_cloudflare_configuration' bash "$TEST_DIR/setup-check.sh" 2>/dev/null; then
    fail 'setup accepted an invalid setting'
fi
if CLOUDFLARE_ENABLED=true MODE=multi bash -c '. "$1"; check_cloudflare_configuration' bash "$TEST_DIR/setup-check.sh" 2>/dev/null; then
    fail 'setup accepted Cloudflare in multi-site mode'
fi

# Compose must carry the persisted value and the effective mode in every
# layout, including an override used with an older .env lacking MODE.
for layout in single multi site; do
    case "$layout" in
        single) files=(-f "$ROOT_DIR/docker/docker-compose.yml"); mode=single ;;
        multi) files=(-f "$ROOT_DIR/docker/docker-compose.yml" -f "$ROOT_DIR/docker/docker-compose.multi.yml"); mode=multi ;;
        site) files=(-f "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template"); mode=multi ;;
    esac
    for value in false true ''; do
        printf 'DOMAIN=example.test\nSITE_PREFIX=kvs-test\nMARIADB_PASSWORD=test\nMARIADB_ROOT_PASSWORD=test\nCLOUDFLARE_ENABLED=%s\n' "$value" > "$TEST_DIR/env"
        docker compose --env-file "$TEST_DIR/env" "${files[@]}" config --format json > "$TEST_DIR/compose.json"
        jq -e --arg value "${value:-false}" --arg mode "$mode" \
            '.services.nginx.environment.CLOUDFLARE_ENABLED == $value and .services.nginx.environment.MODE == $mode' \
            "$TEST_DIR/compose.json" >/dev/null || fail "$layout did not propagate the setting/mode"
    done
done
echo 'PASS: Cloudflare settings, lifecycle, validation, manual configuration and Compose propagation'
