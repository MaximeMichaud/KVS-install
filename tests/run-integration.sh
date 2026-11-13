#!/bin/bash
# The integration suites, on real containers, the way the tests workflow
# runs them:
#
#   tests/run-integration.sh [suite...]
#
# Without an argument it runs every suite listed below, otherwise the ones
# named, as integration_origin_security.sh for instance. They run on the
# images docker/images.lock pins, which this script pulls first: the suites
# never pull, and a pinned image that cannot be pulled fails the run, as a
# missing Docker does. The images a suite checks are built from this
# checkout: the nginx of integration_internal_tls.py here, the Manticore and
# the small PHP-FPM images by their suites.
#
# integration_cloudflare_realip.sh runs from tests/run.sh. The suites of the
# PHP-FPM and cron images, integration_php_security.py,
# integration_php_sessions.py and integration_cache.py, run in the docker
# images workflow, on the images its build jobs make: building those takes
# longer than every suite here together.
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(dirname "$TEST_DIR")

suites=(
    integration_origin_security.sh
    integration_nginx_healthcheck.sh
    integration_nginx_import.sh
    integration_nginx_log_rotation.sh
    integration_database_runtime.sh
    integration_import_collation.sh
    integration_native_import.sh
    integration_resume_import.sh
    integration_resume_compose.sh
    integration_php_fpm_resources.sh
    integration_php_image_downloads.sh
    integration_manticore_startup.sh
    integration_internal_tls.py
)
[ "$#" -eq 0 ] || suites=("$@")

lock() { "$ROOT_DIR/docker/bin/resolve-bases.sh" --get "$@"; }

if ! docker info >/dev/null 2>&1; then
    echo 'ERROR: the integration suites need a running Docker' >&2
    exit 1
fi

# Every image a suite runs: the default MariaDB series of docker/.env.example
# for the database runtime, 12.3 for the imports and 11.8 for Manticore, every
# series setup.sh offers (11.4, 11.8, 12.3) for the collation import, and the
# Caddy of the multi-site front end.
php_fpm=$(lock php-fpm 8.1)
php_cli=$(lock php-cli 8.1)
default_mariadb=$(sed -n 's/^MARIADB_VERSION=//p' "$ROOT_DIR/docker/.env.example")
images=("$php_fpm" "$php_cli")
for entry in nginx "mariadb $default_mariadb" "mariadb 12.3" "mariadb 11.8" "mariadb 11.4" alpine; do
    read -r name series <<<"$entry"
    image=$(lock "$name" ${series:+"$series"})
    images+=("$image")
done
caddy=$(sed -n 's/^ *image: *//p' "$ROOT_DIR/docker/multi-site/docker-compose.caddy.yml")
images+=("$caddy")
for image in "${images[@]}"; do
    docker image inspect "$image" >/dev/null 2>&1 || docker pull --quiet "$image" >/dev/null
done

nginx_image=
cleanup() {
    if [ -n "$nginx_image" ]; then
        docker image rm "$nginx_image" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

for suite in "${suites[@]}"; do
    [ -f "$TEST_DIR/$suite" ] || { echo "ERROR: no suite tests/$suite" >&2; exit 1; }
    echo "Running $suite"
    case "$suite" in
        integration_nginx_import.sh)
            NGINX_IMPORT_TEST_MODE="file" "$TEST_DIR/$suite"
            NGINX_IMPORT_TEST_MODE="source" "$TEST_DIR/$suite"
            ;;
        integration_internal_tls.py)
            if [ -z "$nginx_image" ]; then
                nginx_image="kvs-integration-nginx:$$"
                docker build --quiet --tag "$nginx_image" "$ROOT_DIR/docker/nginx" >/dev/null
            fi
            KVS_TLS_TEST_NGINX_IMAGE=$nginx_image KVS_TLS_TEST_PHP_IMAGE=$php_fpm \
                KVS_TLS_TEST_CRON_IMAGE=$php_cli python3 "$TEST_DIR/$suite"
            ;;
        *.py)
            python3 "$TEST_DIR/$suite"
            ;;
        *)
            "$TEST_DIR/$suite"
            ;;
    esac
done

echo "All integration suites passed"
