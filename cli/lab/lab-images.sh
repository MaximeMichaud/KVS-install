#!/bin/bash
# Builds the images of a release lab from a running instance: the images
# the setup built become version A in a registry, a derived version B adds
# a layer of random bytes (a real download), version C ships a php-fpm that
# refuses to start. The derived versions leave the engine once pushed, so a
# later pull downloads them as it would from a public registry. Prints one
# "service=ref" list per version for kvsctl-release, plus the same B list in
# the variant form "service@series=ref" that publishes php-fpm and cron once
# per PHP series.
#
# Usage: lab-images.sh <docker dir of the instance> <registry host:port> <vA> <vB> <vC> [payload MB] [PHP series]
set -euo pipefail

docker_dir=$1
registry=$2
version_a=$3
version_b=$4
version_c=$5
payload_mb=${6:-64}

cd "$docker_dir"
# The PHP series of the instance, for the variant list: the seventh argument,
# or PHP_VERSION from the .env the setup wrote beside the compose file.
php_series=${7:-}
if [ -z "$php_series" ] && [ -f .env ]; then
    php_series=$(sed -n 's/^PHP_VERSION=//p' .env | tr -d '"' | head -n 1)
fi
php_series=${php_series:-8.1}
list_a=()
list_b=()
list_c=()
list_b_variant=()
for service in nginx php-fpm cron kvs-init manticore; do
    container=$(docker compose ps -a -q "$service" 2>/dev/null | head -n 1 || true)
    if [ -z "$container" ]; then
        echo "skip $service: no container" >&2
        continue
    fi
    source_image=$(docker inspect -f '{{.Config.Image}}' "$container")
    name=$service
    case "$service" in
        php-fpm) name=php ;;
        kvs-init) name=init ;;
    esac
    repo="$registry/kvs-install/$name"
    docker tag "$source_image" "$repo:$version_a"
    docker push -q "$repo:$version_a" >/dev/null
    printf 'FROM %s\nLABEL org.opencontainers.image.version=%s\nRUN dd if=/dev/urandom of=/lab-payload.bin bs=1M count=%s 2>/dev/null\n' "$repo:$version_a" "$version_b" "$payload_mb" |
        docker build -q -t "$repo:$version_b" - >/dev/null
    docker push -q "$repo:$version_b" >/dev/null
    if [ "$service" = php-fpm ]; then
        printf 'FROM %s\nLABEL org.opencontainers.image.version=%s\nCMD ["sh", "-c", "echo php-fpm of the broken release refuses to start >&2; exit 1"]\n' "$repo:$version_b" "$version_c" |
            docker build -q -t "$repo:$version_c" - >/dev/null
    else
        printf 'FROM %s\nLABEL org.opencontainers.image.version=%s\n' "$repo:$version_b" "$version_c" |
            docker build -q -t "$repo:$version_c" - >/dev/null
    fi
    docker push -q "$repo:$version_c" >/dev/null
    docker rmi -f "$repo:$version_c" "$repo:$version_b" >/dev/null
    list_a+=("$service=$repo:$version_a")
    list_b+=("$service=$repo:$version_b")
    list_c+=("$service=$repo:$version_c")
    case "$service" in
        php-fpm | cron) list_b_variant+=("$service@$php_series=$repo:$version_b") ;;
        *) list_b_variant+=("$service=$repo:$version_b") ;;
    esac
    echo "pushed $repo: $version_a $version_b $version_c" >&2
done
join() { local IFS=,; echo "$*"; }
echo "IMAGES_A=$(join "${list_a[@]}")"
echo "IMAGES_B=$(join "${list_b[@]}")"
echo "IMAGES_C=$(join "${list_c[@]}")"
# The same images as IMAGES_B, named the way a release that publishes php-fpm
# and cron per PHP series names them: kvsctl-release files those two under
# variants.php[series] and the override reads their image from .env.
echo "IMAGES_B_VARIANT=$(join "${list_b_variant[@]}")"
