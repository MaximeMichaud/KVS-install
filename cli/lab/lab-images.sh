#!/bin/bash
# A maintainer's tool, to try kvsctl against real pulls without publishing
# anything. From a stack that docker/setup.sh built and runs, it makes the
# images of three releases in a registry of the lab:
#   <vA>  the images the setup built, as they are;
#   <vB>  the same images with a layer of random bytes, a real download;
#   <vC>  vB with a php-fpm that refuses to start, a release that fails.
# The images of vB and vC leave the engine once pushed, so an upgrade pulls
# them as it would from a public registry. MariaDB is not rebuilt: every
# version pins the image the stack runs, as the variant of its series.
#
# It prints, for each version, the --images and --digests lists that
# kvsctl-release bundle and manifest take, with php-fpm, cron and mariadb as
# variants of their series (service@series=...): every pin of a release is
# ref@digest. The bundles, the signed manifest and the server that serves
# them are left to the maintainer; docs/releasing.md describes the real
# pipeline, and KVSCTL_RELEASE_KEY with --manifest point kvsctl at the lab.
#
# Usage: lab-images.sh <docker dir of the stack> <registry host:port> <vA> <vB> <vC> [payload MB] [PHP series]
set -euo pipefail

if [ "$#" -lt 5 ]; then
    echo "usage: $0 <docker dir of the stack> <registry host:port> <vA> <vB> <vC> [payload MB] [PHP series]" >&2
    exit 2
fi
docker_dir=$1
registry=$2
version_a=$3
version_b=$4
version_c=$5
payload_mb=${6:-64}

cd "$docker_dir"

# env_value prints a setting of the .env the setup wrote beside the compose
# file, without its quotes.
env_value() {
    sed -n "s/^$1=//p" .env 2>/dev/null | tr -d '"' | head -n 1
}

# digest_of prints the digest the registry gave an image, read from the
# repo digests the engine recorded when it pushed or pulled it.
digest_of() {
    docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$1" |
        sed -n 's/^[^@]*@\(sha256:[0-9a-f]*\)$/\1/p' | head -n 1
}

php_series=${7:-$(env_value PHP_VERSION)}
php_series=${php_series:-8.1}
images_a=()
images_b=()
images_c=()
digests_a=()
digests_b=()
digests_c=()
for service in nginx php-fpm cron kvs-init manticore; do
    container=$(docker compose ps -a -q "$service" 2>/dev/null | head -n 1 || true)
    if [ -z "$container" ]; then
        echo "skip $service: no container" >&2
        continue
    fi
    source_image=$(docker inspect -f '{{.Config.Image}}' "$container")
    name=$service
    key=$service
    case "$service" in
        php-fpm)
            name=php
            key="php-fpm@$php_series"
            ;;
        cron) key="cron@$php_series" ;;
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
    images_a+=("$key=$repo:$version_a")
    images_b+=("$key=$repo:$version_b")
    images_c+=("$key=$repo:$version_c")
    digests_a+=("$key=$(digest_of "$repo:$version_a")")
    digests_b+=("$key=$(digest_of "$repo:$version_b")")
    digests_c+=("$key=$(digest_of "$repo:$version_c")")
    docker rmi -f "$repo:$version_c" "$repo:$version_b" >/dev/null
    echo "pushed $repo: $version_a $version_b $version_c" >&2
done

container=$(docker compose ps -a -q mariadb 2>/dev/null | head -n 1 || true)
if [ -n "$container" ]; then
    source_image=$(docker inspect -f '{{.Config.Image}}' "$container")
    ref=${source_image%@*}
    series=$(printf '%s\n' "$ref" | sed -n 's/^.*:\([0-9][0-9]*\.[0-9][0-9]*\)[^:/]*$/\1/p')
    series=${series:-$(env_value MARIADB_VERSION)}
    digest=$(digest_of "$source_image")
    if [ -n "$series" ] && [ -n "$digest" ]; then
        images_a+=("mariadb@$series=$ref")
        images_b+=("mariadb@$series=$ref")
        images_c+=("mariadb@$series=$ref")
        digests_a+=("mariadb@$series=$digest")
        digests_b+=("mariadb@$series=$digest")
        digests_c+=("mariadb@$series=$digest")
    else
        echo "skip mariadb: the series or the registry digest of $source_image is unknown" >&2
    fi
else
    echo "skip mariadb: no container" >&2
fi

if [ "${#images_a[@]}" -eq 0 ]; then
    echo "no service of the stack in $docker_dir has a container" >&2
    exit 1
fi
join() {
    local IFS=,
    echo "$*"
}
echo "IMAGES_A=$(join "${images_a[@]}")"
echo "DIGESTS_A=$(join "${digests_a[@]}")"
echo "IMAGES_B=$(join "${images_b[@]}")"
echo "DIGESTS_B=$(join "${digests_b[@]}")"
echo "IMAGES_C=$(join "${images_c[@]}")"
echo "DIGESTS_C=$(join "${digests_c[@]}")"
