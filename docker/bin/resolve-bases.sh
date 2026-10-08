#!/usr/bin/env bash
#
# Resolve every image this stack builds on, or runs, to an immutable digest
# and write docker/images.lock. The lock is what makes a build here and a
# build in the CI produce the same bytes: a tag moves, a digest does not.
#
#   resolve-bases.sh                    regenerate docker/images.lock, the
#                                       base defaults of the Dockerfiles and
#                                       the images the compose files pin
#   resolve-bases.sh --check            fail if the lock is not what the
#                                       registry serves today, or a
#                                       Dockerfile default or a pinned
#                                       compose image is not the lock
#   resolve-bases.sh --check-dockerfiles
#                                       only the Dockerfile defaults and the
#                                       pinned compose images against the
#                                       lock (no registry, no docker)
#   resolve-bases.sh --get NAME SERIES  print one pinned reference
#
# The tag of each entry is a human decision and lives in the tables below.
# Bump a tag here, run the script, commit the lock, the Dockerfiles and the
# compose files: the default of every Dockerfile, and the image of every
# service of COMPOSE_IMAGES, follows the entry of its name and series.

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LOCK_FILE=${IMAGES_LOCK:-${SCRIPT_DIR}/../images.lock}
DOCKER_DIR=${RESOLVE_BASES_DOCKER_DIR:-${SCRIPT_DIR}/..}

# The PHP series the PHP-FPM and cron images build when no PHP_VERSION is
# given: the default of their PHP_VERSION argument, and of PHP_VERSION in
# the compose files.
DEFAULT_PHP_SERIES=8.1

# Dockerfiles whose base build argument defaults to an entry of the lock, as
# file<TAB>argument<TAB>name<TAB>series of the entry. A plain "docker build",
# Compose and the release CI build from that default (the CI passes
# PHP_BASE only for the PHP series it publishes), so it has to be the
# locked reference. The entry is found by its name and series, never by the
# tag the default names: after a tag bump in the tables below, the default
# still names the old tag, and the entry of the new one replaces it.
DOCKERFILES=(
    "php/Dockerfile	PHP_BASE	php-fpm	${DEFAULT_PHP_SERIES}"
    "cron/Dockerfile	PHP_BASE	php-cli	${DEFAULT_PHP_SERIES}"
    "nginx/Dockerfile	NGINX_BASE	nginx	-"
    "init/Dockerfile	DEBIAN_BASE	debian	-"
    "manticore/Dockerfile	MANTICORE_BASE	manticore	-"
)

# Compose services whose image is an entry of the lock, as
# file<TAB>service<TAB>name<TAB>series of the entry. phpmyadmin-init runs
# init.sh with the BusyBox tools of its Alpine, the one the tests run it
# with and a release pins: a stack without a release would otherwise run
# whatever alpine:latest is on the day it pulls.
COMPOSE_IMAGES=(
    "docker-compose.yml	phpmyadmin-init	alpine	-"
    "multi-site/docker-compose.site.yml.template	phpmyadmin-init	alpine	-"
)

# name<TAB>series<TAB>tag. "-" is the series of an image that does not vary.
# php-fpm and php-cli carry one line per series setup.sh may select
# (SUPPORTED_PHP_VERSIONS). PHP 7.4 has none: its php:7.4-* images are
# Debian 11, which lacks packages the PHP-FPM and cron images install.
BUILD_BASES=(
    "php-fpm	8.1	php:8.1-fpm"
    "php-fpm	8.2	php:8.2-fpm"
    "php-fpm	8.3	php:8.3-fpm"
    "php-fpm	8.4	php:8.4-fpm"
    "php-cli	8.1	php:8.1-cli"
    "php-cli	8.2	php:8.2-cli"
    "php-cli	8.3	php:8.3-cli"
    "php-cli	8.4	php:8.4-cli"
    "nginx	-	nginx:mainline"
    "debian	-	debian:trixie-slim"
    "manticore	-	manticoresearch/manticore:29.9.0"
)

# Images the compose file runs as they are. They are not build bases, but a
# release pins them too, so they are resolved here as well. mariadb carries
# one line per series setup.sh offers (MARIADB_LTS_VERSIONS), each on the
# newest patch tag of its series: a stack keeps its series across releases,
# so a series missing here is a stack no release can upgrade.
RUNTIME_IMAGES=(
    "mariadb	11.4	mariadb:11.4.13"
    "mariadb	11.8	mariadb:11.8.9"
    "mariadb	12.3	mariadb:12.3.3"
    "memcached	-	memcached:1.6.45-alpine"
    "dragonfly	-	docker.dragonflydb.io/dragonflydb/dragonfly:v1.35.1"
    "acme	-	neilpang/acme.sh:3.1.6"
    "alpine	-	alpine:3.24.2"
)

die() {
    printf 'resolve-bases: %s\n' "$*" >&2
    exit 1
}

require_docker() {
    command -v docker >/dev/null 2>&1 ||
        die "docker is required to read a registry digest"
    docker buildx version >/dev/null 2>&1 ||
        die "docker buildx is required (docker buildx imagetools inspect)"
    command -v sha256sum >/dev/null 2>&1 ||
        die "sha256sum is required to compute the digest of a manifest"
}

# Print the digest of the manifest a tag points at. For a multi-platform tag
# this is the index digest, which is what FROM and docker pull accept. The
# digest of a manifest is the sha256 of its bytes, which --raw prints as the
# registry served them: buildx fetches that one manifest. A --format template
# would make it fetch the index again and every manifest the index lists,
# one per platform and one per attestation, and Docker Hub counts manifest
# fetches against its pull limit.
resolve_digest() {
    local ref=$1 sum

    sum=$(docker buildx imagetools inspect --raw "$ref" 2>/dev/null | sha256sum) ||
        die "cannot read the digest of $ref"
    # No answer at all has a sha256 too, but it is no manifest.
    [ "$sum" != "$(sha256sum </dev/null)" ] || die "$ref returned an empty manifest"
    printf 'sha256:%s' "${sum%% *}"
}

# Bash runs a command substitution without errexit, and the lock is built
# inside one: every failure is passed on by hand, or a registry that refuses
# an answer (a rate limit) would leave a lock line with no digest, and
# --check would call the lock stale instead of naming the failure.
emit_table() {
    local entry name series tag digest

    for entry in "$@"; do
        IFS=$'\t' read -r name series tag <<<"$entry"
        digest=$(resolve_digest "$tag") || return 1
        printf '%s\t%s\t%s@%s\n' "$name" "$series" "$tag" "$digest"
    done
}

generate() {
    cat <<'HEADER'
# Generated by docker/bin/resolve-bases.sh. Do not edit by hand.
#
# name<TAB>series<TAB>reference@digest
#
# A tag moves, a digest does not. Every Dockerfile takes its base as a build
# argument (PHP_BASE, NGINX_BASE, DEBIAN_BASE, MANTICORE_BASE) whose default
# is the line below for the default series, so a plain "docker build" and the
# release CI resolve the same bytes. Building another PHP series means
# passing the PHP_BASE of that series:
#
#   docker build --build-arg PHP_VERSION=8.3 \
#       --build-arg PHP_BASE="$(docker/bin/resolve-bases.sh --get php-fpm 8.3)" \
#       docker/php
#
# PHP 7.4 has no line: its php:7.4-* images are Debian 11, which lacks
# packages the PHP-FPM and cron images install, and receive no security
# update. setup.sh refuses a KVS archive that needs it.
HEADER
    printf '#\n# Resolved on %s.\n\n' "$(date -u +%Y-%m-%d)"
    printf '# Build bases\n'
    emit_table "${BUILD_BASES[@]}" || return 1
    printf '\n# Images the compose file runs unchanged\n'
    emit_table "${RUNTIME_IMAGES[@]}" || return 1
}

# The reference the lock pins for an entry, by its name and series.
lock_entry() {
    local lock=$1 want_name=$2 want_series=$3 name series ref

    while IFS=$'\t' read -r name series ref; do
        case "$name" in ''|'#'*) continue ;; esac
        if [ "$name" = "$want_name" ] && [ "$series" = "$want_series" ]; then
            printf '%s\n' "$ref"
            return 0
        fi
    done <"$lock"
    return 1
}

# Compare (check) or align (write) the base default of every Dockerfile with
# the lock.
dockerfile_bases() {
    local mode=$1 lock=$2 entry file arg name series path line ref locked status=0

    [ -f "$lock" ] || die "$lock does not exist"
    for entry in "${DOCKERFILES[@]}"; do
        IFS=$'\t' read -r file arg name series <<<"$entry"
        path="${DOCKER_DIR}/${file}"
        [ -f "$path" ] || die "$path does not exist"
        line=$(grep -m 1 -E "^ARG ${arg}=" "$path") ||
            die "$path has no ARG ${arg}= line"
        ref=${line#*=}
        locked=$(lock_entry "$lock" "$name" "$series") ||
            die "$file builds on the $name $series entry, which $lock does not have"
        [ "$ref" != "$locked" ] || continue
        if [ "$mode" = write ]; then
            sed -i "s|^ARG ${arg}=.*\$|ARG ${arg}=${locked}|" "$path"
            printf 'updated %s\n' "$file"
        else
            printf 'resolve-bases: %s: %s=%s, the lock pins %s\n' "$file" "$arg" "$ref" "$locked" >&2
            status=1
        fi
    done
    return "$status"
}

# The line number and the reference of the image of a service in a compose
# file, tab separated: the image key of the service block, which ends at the
# next key of the service level or above. Comments do not end it.
service_image() {
    awk -v service="  $2:" '
        $0 == service { inside = 1; next }
        inside && /^[^ #]|^ [^ #]|^  [^ #]/ { exit }
        inside && /^    image: / { sub(/^    image: /, ""); print NR "\t" $0; found = 1; exit }
        END { exit !found }' "$1"
}

# Compare (check) or align (write) the image of every service of
# COMPOSE_IMAGES with the lock.
compose_images() {
    local mode=$1 lock=$2 entry file service name series path found number ref locked status=0

    [ -f "$lock" ] || die "$lock does not exist"
    for entry in "${COMPOSE_IMAGES[@]}"; do
        IFS=$'\t' read -r file service name series <<<"$entry"
        path="${DOCKER_DIR}/${file}"
        [ -f "$path" ] || die "$path does not exist"
        found=$(service_image "$path" "$service") ||
            die "$path has no image line for the service $service"
        number=${found%%$'\t'*}
        ref=${found#*$'\t'}
        locked=$(lock_entry "$lock" "$name" "$series") ||
            die "$file runs the $name $series entry for $service, which $lock does not have"
        [ "$ref" != "$locked" ] || continue
        if [ "$mode" = write ]; then
            sed -i "${number}s|^    image: .*\$|    image: ${locked}|" "$path"
            printf 'updated %s\n' "$file"
        else
            printf 'resolve-bases: %s: the image of %s is %s, the lock pins %s\n' "$file" "$service" "$ref" "$locked" >&2
            status=1
        fi
    done
    return "$status"
}

lookup() {
    local want_name=$1 want_series=${2:--}

    [ -f "$LOCK_FILE" ] || die "$LOCK_FILE does not exist"
    lock_entry "$LOCK_FILE" "$want_name" "$want_series" ||
        die "no entry for $want_name $want_series in $LOCK_FILE"
}

# Stop when a Dockerfile default or a compose image is not the lock: the
# checks name each of them first, then the first failure stops the script.
stop_off_lock() {
    [ "$1" -eq 1 ] || die "a Dockerfile does not build on the lock; run docker/bin/resolve-bases.sh"
    [ "$2" -eq 1 ] || die "a compose file does not run the image of the lock; run docker/bin/resolve-bases.sh"
}

main() {
    local generated dockerfiles_ok=1 compose_ok=1

    case "${1:-}" in
        --get)
            [ $# -ge 2 ] || die "--get needs a name and an optional series"
            lookup "$2" "${3:--}"
            ;;
        --check)
            require_docker
            [ -f "$LOCK_FILE" ] || die "$LOCK_FILE does not exist"
            dockerfile_bases check "$LOCK_FILE" || dockerfiles_ok=0
            compose_images check "$LOCK_FILE" || compose_ok=0
            generated=$(generate) || exit 1
            # The generation date is the only line allowed to differ.
            if diff -u \
                <(grep -v '^# Resolved on ' "$LOCK_FILE") \
                <(printf '%s\n' "$generated" | grep -v '^# Resolved on '); then
                echo "images.lock matches the registry"
            else
                die "images.lock is stale; run docker/bin/resolve-bases.sh"
            fi
            stop_off_lock "$dockerfiles_ok" "$compose_ok"
            ;;
        --check-dockerfiles)
            dockerfile_bases check "$LOCK_FILE" || dockerfiles_ok=0
            compose_images check "$LOCK_FILE" || compose_ok=0
            stop_off_lock "$dockerfiles_ok" "$compose_ok"
            echo "the Dockerfiles build on the lock and the compose files run its images"
            ;;
        ''|--write)
            require_docker
            # Resolved in full before anything is written, so a failure
            # leaves the lock as it was.
            generated=$(generate) || exit 1
            printf '%s\n' "$generated" >"${LOCK_FILE}.tmp"
            mv -- "${LOCK_FILE}.tmp" "$LOCK_FILE"
            printf 'wrote %s\n' "$LOCK_FILE"
            dockerfile_bases write "$LOCK_FILE"
            compose_images write "$LOCK_FILE"
            ;;
        -h|--help)
            # The comment at the top of this file, up to its first blank line.
            awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
}

main "$@"
