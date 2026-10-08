#!/bin/bash
# docker/bin/resolve-bases.sh turns the tags of its tables into
# docker/images.lock through the registry. The digest of each tag is the
# sha256 of the manifest the registry serves, fetched once per tag. What the
# registry answers is written to the lock and checked against it. A
# registry that refuses an answer (a rate limit, no network) or sends an
# empty one must stop both with the name of the image, leave the lock as it
# was, and never have a good lock called stale.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-resolve-bases.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The docker CLI standing in for the registry. It answers only
# "buildx imagetools inspect --raw <tag>", with a manifest made from the tag
# and MOCK_DIGEST_SALT and no final newline, the way buildx prints the bytes
# the registry served. A tag that starts with MOCK_REFUSE gets the error a
# rate limit gives, one that starts with MOCK_EMPTY gets no bytes at all.
# Every inspect is logged to MOCK_LOG.
manifest() { printf '{"schemaVersion":2,"tag":"%s","salt":"%s"}' "$1" "${2:-}"; }
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/bash
[ "${1:-}" = buildx ] || exit 1
case "${2:-}" in
    version) exit 0 ;;
    imagetools)
        printf '%s\n' "$*" >> "$MOCK_LOG"
        ref=${*: -1}
        if [ -n "${MOCK_REFUSE:-}" ] && [[ "$ref" == "$MOCK_REFUSE"* ]]; then
            echo "ERROR: unexpected status from HEAD request: 429 Too Many Requests" >&2
            exit 1
        fi
        [ $# -eq 5 ] && [ "$3" = inspect ] && [ "$4" = --raw ] || exit 1
        if [ -n "${MOCK_EMPTY:-}" ] && [[ "$ref" == "$MOCK_EMPTY"* ]]; then
            exit 0
        fi
        printf '{"schemaVersion":2,"tag":"%s","salt":"%s"}' "$ref" "${MOCK_DIGEST_SALT:-}"
        ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/docker"

lock="$TEST_DIR/images.lock"
calls="$TEST_DIR/calls"
# The Dockerfiles and the compose files the script aligns with the lock:
# copies, so a write never touches the repository.
docker_dir="$TEST_DIR/docker"
compose_files=(docker-compose.yml multi-site/docker-compose.site.yml.template)
copy_files() {
    local image file

    for image in php cron nginx init manticore; do
        mkdir -p "$docker_dir/$image"
        cp "$ROOT_DIR/docker/$image/Dockerfile" "$docker_dir/$image/Dockerfile"
    done
    for file in "${compose_files[@]}"; do
        mkdir -p "$(dirname "$docker_dir/$file")"
        cp "$ROOT_DIR/docker/$file" "$docker_dir/$file"
    done
}
copy_files
resolve() {
    PATH="$TEST_DIR/bin:$PATH" IMAGES_LOCK="$lock" MOCK_LOG="$calls" \
        RESOLVE_BASES_DOCKER_DIR="$docker_dir" "$ROOT_DIR/docker/bin/resolve-bases.sh" "$@"
}

# The Dockerfiles of the repository build on the lock of the repository,
# and its compose files run the images of it.
"$ROOT_DIR/docker/bin/resolve-bases.sh" --check-dockerfiles > "$TEST_DIR/out" 2>&1 ||
    fail "a Dockerfile base default or a compose image is not the reference docker/images.lock pins: $(cat "$TEST_DIR/out")"
for file in "${compose_files[@]}"; do
    grep -Fxq "    image: $("$ROOT_DIR/docker/bin/resolve-bases.sh" --get alpine -)" "$ROOT_DIR/docker/$file" ||
        fail "docker/$file must run phpmyadmin-init on the Alpine of the lock: $(grep -n 'alpine' "$ROOT_DIR/docker/$file")"
done
echo "PASS: the base default of every Dockerfile, and the image the compose files pin, is the reference of the lock"

resolve > "$TEST_DIR/out" 2>&1 || fail "the lock was not written: $(cat "$TEST_DIR/out")"
tab=$'\t'
entries=$(grep -c '^[a-z]' "$lock")
[ "$(grep -Ec "^[a-z-]+${tab}[0-9.-]+${tab}[^@${tab}]+@sha256:[0-9a-f]{64}$" "$lock")" -eq "$entries" ] ||
    fail "every lock line must carry a reference and its digest: $(cat "$lock")"
[ "$(resolve --get mariadb 12.3)" = "$(sed -n "s/^mariadb${tab}12\.3${tab}//p" "$lock")" ] ||
    fail "--get does not read the MariaDB 12.3 line of the lock"
# The digest is the sha256 of exactly the bytes served, nothing added.
ref=$(resolve --get mariadb 12.3)
tag=${ref%@*}
[ "$ref" = "${tag}@sha256:$(manifest "$tag" | sha256sum | cut -d' ' -f1)" ] ||
    fail "the digest of $tag must be the sha256 of its manifest, got $ref"
# One fetch of the manifest per image. A --format template would fetch every
# manifest of the index again, and the mock refuses it.
[ "$(grep -c '^buildx imagetools inspect --raw ' "$calls")" -eq "$entries" ] &&
    [ "$(wc -l < "$calls")" -eq "$entries" ] ||
    fail "each image must be inspected once, for its raw manifest: $(cat "$calls")"
resolve --check > "$TEST_DIR/out" 2>&1 || fail "a lock fresh from the registry must pass --check: $(cat "$TEST_DIR/out")"
grep -Fxq 'images.lock matches the registry' "$TEST_DIR/out" || fail "--check must say the lock matches"
cp "$lock" "$TEST_DIR/images.lock.good"
echo "PASS: the lock is written from the registry and checked against it"

# A refused answer stops the write with the image named; the lock stays.
if MOCK_REFUSE=php:8.3-cli resolve > "$TEST_DIR/out" 2>&1; then
    fail "the lock was written although the registry refused an image"
fi
grep -Fq 'cannot read the digest of php:8.3-cli' "$TEST_DIR/out" ||
    fail "the refused image must be named: $(cat "$TEST_DIR/out")"
cmp -s "$lock" "$TEST_DIR/images.lock.good" || fail "a failed resolution changed the lock"
[ ! -e "${lock}.tmp" ] || fail "a failed resolution left a temporary lock behind"

# An empty answer has a sha256 too, but it is no manifest.
if MOCK_EMPTY=alpine: resolve > "$TEST_DIR/out" 2>&1; then
    fail "the lock was written although the registry sent an empty manifest"
fi
grep -Eq 'alpine:[^ ]+ returned an empty manifest' "$TEST_DIR/out" ||
    fail "the image with an empty manifest must be named: $(cat "$TEST_DIR/out")"
cmp -s "$lock" "$TEST_DIR/images.lock.good" || fail "an empty manifest changed the lock"

# The check stops on it as well, and does not call a good lock stale.
if MOCK_REFUSE=mariadb:12.3. resolve --check > "$TEST_DIR/out" 2>&1; then
    fail "--check passed although the registry refused an image"
fi
grep -Fq 'cannot read the digest of mariadb:12.3.' "$TEST_DIR/out" ||
    fail "--check must name the image the registry refused: $(cat "$TEST_DIR/out")"
if grep -Fq 'stale' "$TEST_DIR/out"; then
    fail "--check called the lock stale when the registry did not answer: $(cat "$TEST_DIR/out")"
fi
echo "PASS: a registry that refuses an answer or sends an empty one stops the write and the check, and the lock stays"

# A tag the registry moved since the lock was written is stale.
if MOCK_DIGEST_SALT=moved resolve --check > "$TEST_DIR/out" 2>&1; then
    fail "--check passed although every digest moved"
fi
grep -Fq 'images.lock is stale' "$TEST_DIR/out" || fail "--check must call a lock with moved digests stale"
echo "PASS: --check reports a digest that moved"

# Writing the lock aligns the base default of every Dockerfile with it: the
# copies still name the digests of the repository lock, which the mock
# registry does not serve.
cp "$TEST_DIR/images.lock.good" "$lock"
copy_files
resolve > "$TEST_DIR/out" 2>&1 || fail "the lock was not written again: $(cat "$TEST_DIR/out")"
for image in php cron nginx init manticore; do
    line=$(grep -m 1 -E '^ARG [A-Z_]+_BASE=' "$docker_dir/$image/Dockerfile")
    ref=${line#*=}
    grep -Fq "$(printf '\t')${ref}" "$lock" ||
        fail "$image/Dockerfile was not aligned with the lock: $line"
done
grep -Fxq 'updated nginx/Dockerfile' "$TEST_DIR/out" || fail "a write must name the Dockerfiles it updated: $(cat "$TEST_DIR/out")"
# The compose files run the Alpine of the lock for phpmyadmin-init, and the
# write changed that line and no other: memcached:alpine stays.
for file in "${compose_files[@]}"; do
    grep -Fxq "updated $file" "$TEST_DIR/out" || fail "a write must name $file: $(cat "$TEST_DIR/out")"
    changed=$(diff "$ROOT_DIR/docker/$file" "$docker_dir/$file" | grep -c '^>' || true)
    if [ "$changed" -ne 1 ] || ! grep -Fxq "    image: $(resolve --get alpine -)" "$docker_dir/$file"; then
        fail "the write must move only the phpmyadmin-init image of $file to the lock: $(diff "$ROOT_DIR/docker/$file" "$docker_dir/$file")"
    fi
done
resolve --check-dockerfiles > "$TEST_DIR/out" 2>&1 || fail "aligned Dockerfiles must pass: $(cat "$TEST_DIR/out")"
[ "$(sed -n 's/^ARG PHP_BASE=//p' "$docker_dir/php/Dockerfile")" = "$(resolve --get php-fpm 8.1)" ] ||
    fail "the php image must default to the PHP 8.1 FPM base of the lock"

# A default the lock does not pin fails both checks, and names the file.
sed -i 's|^ARG NGINX_BASE=\(.*\)@sha256:.*$|ARG NGINX_BASE=\1@sha256:'"$(printf '0%.0s' $(seq 64))"'|' "$docker_dir/nginx/Dockerfile"
if resolve --check-dockerfiles > "$TEST_DIR/out" 2>&1; then
    fail "--check-dockerfiles passed with an nginx base that is not the lock"
fi
grep -Fq 'nginx/Dockerfile: NGINX_BASE=' "$TEST_DIR/out" || fail "the stale Dockerfile must be named: $(cat "$TEST_DIR/out")"
if resolve --check > "$TEST_DIR/out" 2>&1; then
    fail "--check passed with an nginx base that is not the lock"
fi
grep -Fq 'a Dockerfile does not build on the lock' "$TEST_DIR/out" || fail "--check must report the Dockerfile: $(cat "$TEST_DIR/out")"

# A base on another tag than the entry of its name is an error, not a
# silent pass, and the check names what the lock pins instead.
sed -i 's|^ARG NGINX_BASE=.*$|ARG NGINX_BASE=nginx:stable@sha256:'"$(printf '0%.0s' $(seq 64))"'|' "$docker_dir/nginx/Dockerfile"
if resolve --check-dockerfiles > "$TEST_DIR/out" 2>&1; then
    fail "--check-dockerfiles passed with a base tag the lock does not pin"
fi
if ! { grep -Fq "nginx/Dockerfile: NGINX_BASE=nginx:stable@sha256:" "$TEST_DIR/out" &&
    grep -Fq "the lock pins $(resolve --get nginx)" "$TEST_DIR/out"; }; then
    fail "the drifted tag and the pinned reference must be named: $(cat "$TEST_DIR/out")"
fi
# So does an image a compose file pins: both checks name the file, the
# service, its image and the reference of the lock.
copy_files
resolve > "$TEST_DIR/out" 2>&1 || fail "the lock was not written again: $(cat "$TEST_DIR/out")"
sed -i 's|^    image: alpine:.*$|    image: alpine:latest|' "$docker_dir/multi-site/docker-compose.site.yml.template"
if resolve --check-dockerfiles > "$TEST_DIR/out" 2>&1; then
    fail "--check-dockerfiles passed with phpmyadmin-init on alpine:latest"
fi
grep -Fq "multi-site/docker-compose.site.yml.template: the image of phpmyadmin-init is alpine:latest, the lock pins $(resolve --get alpine -)" "$TEST_DIR/out" ||
    fail "the drifted compose image and the pinned reference must be named: $(cat "$TEST_DIR/out")"
if resolve --check > "$TEST_DIR/out" 2>&1; then
    fail "--check passed with phpmyadmin-init on alpine:latest"
fi
grep -Fq 'a compose file does not run the image of the lock' "$TEST_DIR/out" ||
    fail "--check must report the compose file: $(cat "$TEST_DIR/out")"
echo "PASS: a write aligns the Dockerfile defaults and the compose images with the lock, and the checks catch one that drifted"

# The documented way to move a base: bump its tag in the tables of the
# script, run it, commit the lock, the Dockerfiles and the compose files.
# Each Dockerfile, and each image of COMPOSE_IMAGES, follows the entry of its
# name and series, so it moves to the new tag, which the file does not name
# yet. Run offline: a copy of the script with the bumped tables, the mock
# registry, copies of the files.
copy_files
cp "$TEST_DIR/images.lock.good" "$lock"
mkdir -p "$TEST_DIR/bumped/bin"
sed -e "s|\"manticore${tab}-${tab}manticoresearch/manticore:[^\"]*\"|\"manticore${tab}-${tab}manticoresearch/manticore:99.0.0\"|" \
    -e "s|\"nginx${tab}-${tab}nginx:mainline\"|\"nginx${tab}-${tab}nginx:stable\"|" \
    -e "s|\"alpine${tab}-${tab}alpine:[^\"]*\"|\"alpine${tab}-${tab}alpine:3.99.0\"|" \
    "$ROOT_DIR/docker/bin/resolve-bases.sh" > "$TEST_DIR/bumped/bin/resolve-bases.sh"
chmod +x "$TEST_DIR/bumped/bin/resolve-bases.sh"
if ! { grep -Fq 'manticoresearch/manticore:99.0.0"' "$TEST_DIR/bumped/bin/resolve-bases.sh" &&
    grep -Fq 'nginx:stable"' "$TEST_DIR/bumped/bin/resolve-bases.sh" &&
    grep -Fq 'alpine:3.99.0"' "$TEST_DIR/bumped/bin/resolve-bases.sh"; }; then
    fail "the tables of the script could not be bumped for the test"
fi
resolve_bumped() {
    PATH="$TEST_DIR/bin:$PATH" IMAGES_LOCK="$lock" MOCK_LOG="$calls" \
        RESOLVE_BASES_DOCKER_DIR="$docker_dir" "$TEST_DIR/bumped/bin/resolve-bases.sh" "$@"
}
resolve_bumped > "$TEST_DIR/out" 2>&1 ||
    fail "the documented tag bump did not finish: $(cat "$TEST_DIR/out")"
for pair in "manticore MANTICORE_BASE manticoresearch/manticore:99.0.0" "nginx NGINX_BASE nginx:stable"; do
    read -r image arg tag <<< "$pair"
    want="${tag}@sha256:$(manifest "$tag" | sha256sum | cut -d' ' -f1)"
    grep -Fxq "ARG ${arg}=${want}" "$docker_dir/$image/Dockerfile" ||
        fail "$image/Dockerfile must build on the bumped tag ${want}: $(grep "^ARG ${arg}=" "$docker_dir/$image/Dockerfile")"
    grep -Fxq "updated $image/Dockerfile" "$TEST_DIR/out" ||
        fail "the bump must name $image/Dockerfile: $(cat "$TEST_DIR/out")"
done
want="alpine:3.99.0@sha256:$(manifest alpine:3.99.0 | sha256sum | cut -d' ' -f1)"
for file in "${compose_files[@]}"; do
    grep -Fxq "    image: ${want}" "$docker_dir/$file" ||
        fail "$file must run phpmyadmin-init on the bumped Alpine ${want}: $(grep -n 'image: alpine' "$docker_dir/$file")"
    grep -Fxq "updated $file" "$TEST_DIR/out" || fail "the bump must name $file: $(cat "$TEST_DIR/out")"
done
resolve_bumped --check-dockerfiles > "$TEST_DIR/out" 2>&1 ||
    fail "the Dockerfiles and the compose files must be on the bumped lock: $(cat "$TEST_DIR/out")"
resolve_bumped --check > "$TEST_DIR/out" 2>&1 ||
    fail "the bumped lock and Dockerfiles must pass --check: $(cat "$TEST_DIR/out")"
echo "PASS: a tag bumped in the tables moves the Dockerfile defaults and the compose images with the lock"

# A Dockerfile whose entry the lock lacks is named, not skipped.
grep -v "^debian${tab}" "$lock" > "$TEST_DIR/images.lock.nodebian"
if PATH="$TEST_DIR/bin:$PATH" IMAGES_LOCK="$TEST_DIR/images.lock.nodebian" RESOLVE_BASES_DOCKER_DIR="$docker_dir" \
    "$ROOT_DIR/docker/bin/resolve-bases.sh" --check-dockerfiles > "$TEST_DIR/out" 2>&1; then
    fail "--check-dockerfiles passed with no lock entry for the init base"
fi
grep -Fq 'init/Dockerfile builds on the debian - entry' "$TEST_DIR/out" ||
    fail "the missing entry must be named: $(cat "$TEST_DIR/out")"
echo "PASS: a Dockerfile whose lock entry is missing is reported"

# A service of COMPOSE_IMAGES without an image line is named, and the image
# of the service after it is never taken for its own.
copy_files
resolve > "$TEST_DIR/out" 2>&1 || fail "the lock was not written again: $(cat "$TEST_DIR/out")"
cat > "$docker_dir/docker-compose.yml" <<'EOF'
services:
  phpmyadmin-init:
    # No image of its own.
    container_name: kvs-phpmyadmin-init
  memcached:
    image: memcached:alpine
EOF
cp "$docker_dir/docker-compose.yml" "$TEST_DIR/no-image.yml"
for mode in --check-dockerfiles --write; do
    if resolve "$mode" > "$TEST_DIR/out" 2>&1; then
        fail "$mode passed with a phpmyadmin-init that has no image line"
    fi
    grep -Fq 'docker-compose.yml has no image line for the service phpmyadmin-init' "$TEST_DIR/out" ||
        fail "$mode must name the service without an image: $(cat "$TEST_DIR/out")"
    cmp -s "$docker_dir/docker-compose.yml" "$TEST_DIR/no-image.yml" ||
        fail "$mode rewrote the image of another service: $(cat "$docker_dir/docker-compose.yml")"
done
echo "PASS: a compose service without an image line is reported, and no other service is rewritten"

# The lock of the repository holds exactly the entries of the tables, digests
# aside, under the header the script writes (images.lock.good was written
# from the tables through the mock registry): it is edited by hand when a
# series is dropped, and --check against a registry does not run on every
# change.
strip_digests() { grep -v '^# Resolved on ' "$1" | sed 's/@sha256:[0-9a-f]\{64\}$//'; }
diff -u <(strip_digests "$TEST_DIR/images.lock.good") <(strip_digests "$ROOT_DIR/docker/images.lock") > "$TEST_DIR/out" ||
    fail "docker/images.lock is not what the tables of resolve-bases.sh generate: $(cat "$TEST_DIR/out")"
echo "PASS: docker/images.lock holds the entries and the header of the tables"

# PHP 7.4 cannot be built: its php:7.4-* bases are Debian 11, which lacks
# packages the PHP-FPM and cron images install. No base of it is pinned, and
# every PHP series setup.sh offers has a pinned PHP-FPM and CLI base, and no
# other series has one.
if grep -Eq "^php-(fpm|cli)${tab}7\\.4${tab}" "$ROOT_DIR/docker/images.lock"; then
    fail "docker/images.lock pins a PHP 7.4 base, which the images cannot build on"
fi
supported=$(sed -n 's/^readonly SUPPORTED_PHP_VERSIONS="\(.*\)"$/\1/p' "$ROOT_DIR/docker/setup.sh")
[ -n "$supported" ] || fail "SUPPORTED_PHP_VERSIONS was not found in setup.sh"
for name in php-fpm php-cli; do
    pinned=$(awk -F '\t' -v n="$name" '$1 == n { printf "%s ", $2 }' "$ROOT_DIR/docker/images.lock")
    [ "${pinned% }" = "$supported" ] ||
        fail "the $name series of the lock (${pinned% }) are not the ones setup.sh offers ($supported)"
done
echo "PASS: the lock pins a base for each PHP series setup.sh offers, PHP 7.4 not among them"
