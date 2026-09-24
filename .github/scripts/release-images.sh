#!/usr/bin/env bash
#
# Turn what the images job built, plus docker/images.lock, into the arguments
# kvsctl-release takes.
#
#   release-images.sh <namespace> <version> <digests-dir> <out-dir>
#
# <namespace> is ghcr.io/<owner>/<repo>, <digests-dir> holds one file per
# built image containing a single "<service>=<digest>" line, where <service>
# is the compose service name and carries "@<php series>" when the image
# varies with PHP.
#
# Writes into <out-dir>:
#
#   images.spec       service=reference pairs for --images
#   digests.spec      service=digest pairs for --digests
#   php-series.spec   the published PHP series, comma separated
#   mariadb-from.spec the MariaDB majors the release accepts on disk
#
# References carry no digest: kvsctl-release reads each one from the registry
# itself, and --digests is what it cross-checks that answer against. Two
# independent sources have to agree before a release is signed.

set -euo pipefail

die() {
    printf 'release-images: %s\n' "$*" >&2
    exit 1
}

[ $# -eq 4 ] || die "usage: release-images.sh <namespace> <version> <digests-dir> <out-dir>"

namespace=$1
version=$2
digests_dir=$3
out_dir=$4

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
lock_file=${IMAGES_LOCK:-${repo_root}/docker/images.lock}

[ -d "$digests_dir" ] || die "$digests_dir does not exist"
[ -f "$lock_file" ] || die "$lock_file does not exist"
mkdir -p "$out_dir"

# The compose service name of an image this repository builds, and the
# repository it is published under.
repository_for() {
    case "$1" in
        nginx) printf 'nginx' ;;
        kvs-init) printf 'init' ;;
        manticore) printf 'manticore' ;;
        php-fpm) printf 'php' ;;
        cron) printf 'cron' ;;
        *) die "unknown built service: $1" ;;
    esac
}

# A reference from docker/images.lock, without its digest: the tag is what
# goes into --images, the digest goes into --digests.
lock_ref() {
    local name=$1 series=${2:--} entry_name entry_series ref

    while IFS=$'\t' read -r entry_name entry_series ref; do
        case "$entry_name" in ''|'#'*) continue ;; esac
        if [ "$entry_name" = "$name" ] && [ "$entry_series" = "$series" ]; then
            printf '%s\n' "$ref"
            return 0
        fi
    done <"$lock_file"
    die "no entry for $name $series in $lock_file"
}

mariadb_series() {
    local name series ref
    while IFS=$'\t' read -r name series ref; do
        [ "$name" = "mariadb" ] || continue
        printf '%s\n' "$series"
    done <"$lock_file" | sort -t. -k1,1n -k2,2n
}

images=()
digests=()
series_seen=()

# Images this repository builds, in the order a reader expects them.
for service in nginx kvs-init manticore; do
    file="${digests_dir}/${service}.txt"
    [ -f "$file" ] || die "no digest recorded for $service"
    digest=$(cut -d= -f2 <"$file")
    [ -n "$digest" ] || die "empty digest for $service"
    images+=("${service}=${namespace}/$(repository_for "$service"):${version}")
    digests+=("${service}=${digest}")
done

while IFS= read -r file; do
    line=$(cut -d= -f1 <"$file")
    digest=$(cut -d= -f2 <"$file")
    service=${line%@*}
    series=${line#*@}
    [ "$series" != "$line" ] || continue
    [ -n "$digest" ] || die "empty digest for $line"
    images+=("${service}@${series}=${namespace}/$(repository_for "$service"):${version}-php${series}")
    digests+=("${service}@${series}=${digest}")
    series_seen+=("$series")
done < <(find "$digests_dir" -name '*.txt' | sort)

[ ${#series_seen[@]} -gt 0 ] || die "no PHP variant image was recorded"

# Images the compose file runs unchanged. The release pins them too, so a
# stack that kvsctl manages never silently moves its database or its cache.
newest_mariadb=$(mariadb_series | tail -n 1)
for pair in \
    "mariadb:mariadb:${newest_mariadb}" \
    "memcached:memcached:-" \
    "dragonfly:dragonfly:-" \
    "acme:acme:-" \
    "phpmyadmin-init:alpine:-"; do
    service=${pair%%:*}
    rest=${pair#*:}
    name=${rest%%:*}
    series=${rest#*:}
    ref=$(lock_ref "$name" "$series")
    images+=("${service}=${ref%@*}")
    digests+=("${service}=${ref#*@}")
done

join_by() {
    local separator=$1
    shift
    local result=""
    local item
    for item in "$@"; do
        if [ -z "$result" ]; then
            result=$item
        else
            result="${result}${separator}${item}"
        fi
    done
    printf '%s' "$result"
}

join_by , "${images[@]}" >"${out_dir}/images.spec"
join_by , "${digests[@]}" >"${out_dir}/digests.spec"
printf '%s' "$(printf '%s\n' "${series_seen[@]}" | sort -u -t. -k1,1n -k2,2n | paste -sd, -)" \
    >"${out_dir}/php-series.spec"
printf '%s' "$(mariadb_series | paste -sd, -)" >"${out_dir}/mariadb-from.spec"

echo "images:       $(cat "${out_dir}/images.spec")"
echo "digests:      $(cat "${out_dir}/digests.spec")"
echo "php series:   $(cat "${out_dir}/php-series.spec")"
echo "mariadb from: $(cat "${out_dir}/mariadb-from.spec")"
