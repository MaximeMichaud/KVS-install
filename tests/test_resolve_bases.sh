#!/bin/bash
# shellcheck disable=SC2016  # The Dockerfile edits below are literal text.
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

# The default the lock pins is the base only if the Dockerfile really builds
# on it: a second ARG line with the same name replaces the first default for
# the global FROM, and a FROM, a COPY --from or a RUN --mount from= that names
# an image directly never reads the argument at all. Each of these edits of a
# copy of the repository's Dockerfiles must fail --check-dockerfiles (offline,
# against the repository lock) and name the file and the line.
edit_dockerfile() {
    local label=$1 image=$2 script=$3

    copy_files
    "$ROOT_DIR/docker/bin/resolve-bases.sh" --check-dockerfiles > /dev/null 2>&1 ||
        fail "the repository Dockerfiles must pass before the $label edit"
    python3 -c '
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
new = eval(sys.argv[2], {"re": re, "text": text})
assert new != text, "the edit changed nothing"
path.write_text(new, encoding="utf-8")
' "$docker_dir/$image/Dockerfile" "$script" || fail "the $label edit could not be applied"
}
check_edited() {
    IMAGES_LOCK="$ROOT_DIR/docker/images.lock" RESOLVE_BASES_DOCKER_DIR="$docker_dir" \
        "$ROOT_DIR/docker/bin/resolve-bases.sh" --check-dockerfiles > "$TEST_DIR/out" 2>&1
}
structure_case() {
    local label=$1 image=$2 script=$3 want=$4

    edit_dockerfile "$label" "$image" "$script"
    if check_edited; then
        fail "--check-dockerfiles passed with $label: $(cat "$TEST_DIR/out")"
    fi
    if ! grep -Fq "$image/Dockerfile" "$TEST_DIR/out" || ! grep -Fq -- "$want" "$TEST_DIR/out"; then
        fail "$label must be reported with '$want' and the file: $(cat "$TEST_DIR/out")"
    fi
}
structure_case "a second ARG NGINX_BASE line" nginx \
    'text.replace("FROM ${NGINX_BASE}", "ARG NGINX_BASE=nginx:latest\nFROM ${NGINX_BASE}")' \
    'declares ARG NGINX_BASE= 2 times'
structure_case "FROM debian:latest" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM debian:latest")' \
    'FROM debian:latest does not build on ${DEBIAN_BASE}'
structure_case "a lowercase from with a platform" init \
    'text.replace("FROM ${DEBIAN_BASE}", "from --platform=$BUILDPLATFORM debian:latest")' \
    'FROM debian:latest does not build on ${DEBIAN_BASE}'
structure_case "a PHP_FROM that no longer derives from PHP_BASE" php \
    're.sub(r"^ARG PHP_FROM=.*$", "ARG PHP_FROM=php:8.1-fpm", text, count=1, flags=re.M)' \
    'FROM ${PHP_FROM} does not build on ${PHP_BASE}'
structure_case "a second ARG PHP_FROM line" cron \
    'text.replace("FROM ${PHP_FROM} AS ffmpeg-build", "ARG PHP_FROM=php:8.1-cli\nFROM ${PHP_FROM} AS ffmpeg-build")' \
    'declares ARG PHP_FROM= 2 times'
structure_case "a COPY --from an image" cron \
    'text.replace("COPY --from=ffmpeg-build ", "COPY --from=alpine:latest ")' \
    'COPY --from=alpine:latest is not an earlier stage'
structure_case "a RUN --mount from an image" php \
    'text.replace("--mount=type=bind,from=ffmpeg-build,", "--mount=type=bind,from=busybox:latest,")' \
    'RUN --mount from=busybox:latest is not an earlier stage'
structure_case "a FROM of a stage defined later" php \
    'text.replace("FROM ${PHP_FROM} AS ffmpeg-build", "FROM ffmpeg-build AS early\nFROM ${PHP_FROM} AS ffmpeg-build")' \
    'FROM ffmpeg-build does not build on ${PHP_BASE}'
# The lines are read the way the parser of Docker reads them: a comment or a
# blank line neither continues nor ends an instruction, and a continuation
# open at the end of the file is an instruction.
structure_case "a comment that ends with a backslash" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM ${DEBIAN_BASE}\n# a comment \\\nFROM debian:latest")' \
    'line 10: FROM debian:latest does not build on ${DEBIAN_BASE}'
structure_case "a comment inside a continuation" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM ${DEBIAN_BASE}\nRUN true \\\n# a comment\nFROM ${DEBIAN_BASE} AS debian\nCOPY --from=debian / /debian")' \
    'line 12: COPY --from=debian is not an earlier stage'
structure_case "a blank line inside a continuation" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM ${DEBIAN_BASE}\nRUN true \\\n\nFROM ${DEBIAN_BASE} AS debian\nCOPY --from=debian / /debian")' \
    'line 12: COPY --from=debian is not an earlier stage'
structure_case "a continuation open at the end of the file" init \
    'text + "FROM debian:latest \\\n"' \
    'FROM debian:latest does not build on ${DEBIAN_BASE}'
structure_case "a flag continued on the next line" cron \
    'text.replace("COPY --from=ffmpeg-build ", "COPY --from=ffmpeg-build\\\nx ")' \
    'COPY --from=ffmpeg-buildx is not an earlier stage'
# What it does not read is refused: a heredoc, whose body would be read as
# instructions, and a parser directive, which changes how the file is read.
structure_case "a heredoc" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM ${DEBIAN_BASE}\nCOPY <<NOTES /notes\nFROM ${DEBIAN_BASE} AS notes\nNOTES\nCOPY --from=notes / /notes")' \
    'line 9: COPY has a heredoc (<<NOTES)'
structure_case "a heredoc on a descriptor, with a dash and quotes" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM ${DEBIAN_BASE}\nRUN cat 0<<-\"NOTES\" > /notes\nFROM ${DEBIAN_BASE} AS notes\nNOTES\nCOPY --from=notes / /notes")' \
    'line 9: RUN has a heredoc (0<<-"NOTES")'
# Docker also takes << followed by another word for a heredoc, after a space
# or a tab, on a descriptor, quoted or not, in COPY as in RUN, and so in an
# unquoted $((1 << 3)), whose heredoc ends at a line "3))".
structure_case "a heredoc after a spaced <<" nginx \
    'text.replace("FROM ${NGINX_BASE}", "FROM ${NGINX_BASE}\nRUN cat << x > /dev/null\nFROM ${NGINX_BASE} AS alpine\nx\nFROM alpine", 1)' \
    'line 8: RUN has a heredoc (<< x)'
structure_case "a COPY heredoc on a descriptor after a spaced <<" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM ${DEBIAN_BASE}\nCOPY 0<< NOTES /notes\nFROM ${DEBIAN_BASE} AS notes\nNOTES\nCOPY --from=notes / /notes")' \
    'line 9: COPY has a heredoc (0<< NOTES)'
structure_case "a quoted heredoc name after a tab" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM ${DEBIAN_BASE}\nRUN cat <<\t\"NOTES\" > /notes\nFROM ${DEBIAN_BASE} AS notes\nNOTES\nCOPY --from=notes / /notes")' \
    'line 9: RUN has a heredoc (<< "NOTES")'
structure_case "a << between spaces in an unquoted arithmetic expansion" nginx \
    'text.replace("FROM ${NGINX_BASE}", "FROM ${NGINX_BASE}\nRUN echo $((1 << 3))\nFROM ${NGINX_BASE} AS alpine\n3))\nFROM alpine", 1)' \
    'line 8: RUN has a heredoc (<< 3)))'
structure_case "an escape parser directive" nginx \
    '"# escape=`\n" + text.replace("FROM ${NGINX_BASE}", "FROM ${NGINX_BASE}\nRUN echo \\\nFROM nginx:latest")' \
    'line 1: the parser directive # escape=`'
structure_case "a syntax parser directive after a byte order mark" nginx \
    '"\ufeff# syntax=docker/dockerfile:1\n" + text' \
    'line 1: the parser directive # syntax=docker/dockerfile:1'
# Words are split on spaces and tabs only: a vertical tab, a form feed, a
# carriage return inside a line, or a byte outside printable ASCII outside a
# comment (a no-break space is a space to Docker) is refused. Carriage
# returns at the end of a line are dropped, as Docker drops them.
structure_case "a vertical tab between two ARG defaults" nginx \
    'text.replace("FROM ${NGINX_BASE}", "ARG FOO=1\vNGINX_BASE=nginx:latest\nFROM ${NGINX_BASE}")' \
    'line 7: holds a vertical tab, a form feed or a carriage return'
structure_case "a no-break space between two ARG defaults" nginx \
    'text.replace("FROM ${NGINX_BASE}", "ARG FOO=1\u00a0NGINX_BASE=nginx:latest\nFROM ${NGINX_BASE}")' \
    'line 7: holds a byte outside printable ASCII'
structure_case "a form feed before a FROM" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM ${DEBIAN_BASE}\n\fFROM debian:latest")' \
    'line 9: holds a vertical tab, a form feed or a carriage return'
structure_case "a vertical tab after a FROM" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM ${DEBIAN_BASE}\nFROM\vdebian:latest")' \
    'line 9: holds a vertical tab, a form feed or a carriage return'
structure_case "a no-break space before a FROM" init \
    'text.replace("FROM ${DEBIAN_BASE}", "FROM ${DEBIAN_BASE}\n\u00a0FROM debian:latest")' \
    'line 9: holds a byte outside printable ASCII'
structure_case "a vertical tab after a COPY" cron \
    'text.replace("COPY --from=ffmpeg-build ", "COPY\v--from=busybox:latest ")' \
    'holds a vertical tab, a form feed or a carriage return'
structure_case "two carriage returns after a backslash" nginx \
    'text.replace("FROM ${NGINX_BASE}", "ARG FOO=1 \\\r\r\nNGINX_BASE=nginx:latest\nFROM ${NGINX_BASE}")' \
    'declares ARG NGINX_BASE= 2 times'
structure_case "a comment after a form feed inside a continuation" nginx \
    'text.replace("FROM ${NGINX_BASE}", "ARG FOO=1 \\\n\f# a note\nNGINX_BASE=nginx:latest\nFROM ${NGINX_BASE}")' \
    'line 8: holds a vertical tab, a form feed or a carriage return'
structure_case "an escape directive after a form feed" nginx \
    '"#\fescape=`\n" + text.replace("FROM ${NGINX_BASE}", "FROM ${NGINX_BASE}\nRUN echo \\\nFROM nginx:latest")' \
    'line 1: holds a vertical tab, a form feed or a carriage return'
# Docker reads a no-break or an ideographic space after the # as a space, so
# these are escape directives: a byte outside printable ASCII is refused in
# a comment as well.
structure_case "an escape directive after a no-break space" nginx \
    '"#\u00a0escape=`\n" + text.replace("FROM ${NGINX_BASE}", "FROM ${NGINX_BASE}\nRUN echo \\\nFROM nginx:latest")' \
    'line 1: holds a byte outside printable ASCII'
structure_case "an escape directive after an ideographic space" nginx \
    '"#\u3000escape=`\n" + text.replace("FROM ${NGINX_BASE}", "FROM ${NGINX_BASE}\nRUN echo \\\nFROM nginx:latest")' \
    'line 1: holds a byte outside printable ASCII'
structure_case "a no-break space in a comment" nginx \
    'text.replace("# DL3008 stays muted", "#\u00a0DL3008 stays muted", 1)' \
    'holds a byte outside printable ASCII'
# BusyBox awk ends a line at a NUL byte, where Docker reads on: the file is
# refused before awk reads it, whatever awk runs the check. The check runs
# again with an awk that ends each line of its file at the first NUL byte
# the way BusyBox awk does, and with BusyBox awk where it is installed: each
# must pass the repository Dockerfiles and report the NUL byte.
nul_edit='text.replace("FROM ${NGINX_BASE}", "ARG FOO=1\0 NGINX_BASE=nginx:latest\nFROM ${NGINX_BASE}", 1)'
structure_case "a NUL byte between two ARG defaults" nginx "$nul_edit" 'line 7: holds a NUL byte'
nul_byte_with_awk() {
    local bin=$1 label=$2

    copy_files
    PATH="$bin:$PATH" check_edited ||
        fail "the repository Dockerfiles must pass with $label: $(cat "$TEST_DIR/out")"
    edit_dockerfile "a NUL byte with $label" nginx "$nul_edit"
    if PATH="$bin:$PATH" check_edited; then
        fail "--check-dockerfiles passed a NUL byte with $label: $(cat "$TEST_DIR/out")"
    fi
    grep -Fq 'nginx/Dockerfile line 7: holds a NUL byte' "$TEST_DIR/out" ||
        fail "the NUL byte must be reported with $label: $(cat "$TEST_DIR/out")"
}
mkdir -p "$TEST_DIR/nul-awk"
cat > "$TEST_DIR/nul-awk/awk" <<'AWK'
#!/bin/bash
if [ $# -gt 0 ] && [ -f "${!#}" ]; then
    python3 -c 'import sys
data = open(sys.argv[1], "rb").read()
sys.stdout.buffer.write(b"\n".join(line.split(b"\0")[0] for line in data.split(b"\n")))' "${!#}" > "$NUL_AWK_INPUT"
    set -- "${@:1:$#-1}" "$NUL_AWK_INPUT"
fi
exec "$NUL_AWK" "$@"
AWK
chmod +x "$TEST_DIR/nul-awk/awk"
NUL_AWK=$(command -v awk) NUL_AWK_INPUT="$TEST_DIR/nul-awk-input"
export NUL_AWK NUL_AWK_INPUT
nul_byte_with_awk "$TEST_DIR/nul-awk" "an awk that ends a line at a NUL byte"
# A NUL byte on the first line of a file whose od dump fills the pipe many
# times over is reported as such, and an od that fails fails the check
# rather than skip the search.
structure_case "a NUL byte at the top of a long file" php \
    '"ARG FOO=1\0\n" + text + "# " + "x" * 200000 + "\n"' \
    'line 1: holds a NUL byte'
mkdir -p "$TEST_DIR/no-od"
printf '#!/bin/sh\nexit 1\n' > "$TEST_DIR/no-od/od"
chmod +x "$TEST_DIR/no-od/od"
copy_files
if PATH="$TEST_DIR/no-od:$PATH" check_edited; then
    fail "--check-dockerfiles passed when od failed: $(cat "$TEST_DIR/out")"
fi
grep -Fq 'php/Dockerfile cannot be read with od' "$TEST_DIR/out" ||
    fail "a failing od must be reported: $(cat "$TEST_DIR/out")"
if command -v busybox > /dev/null 2>&1 && busybox awk 'BEGIN { exit 0 }' 2> /dev/null; then
    mkdir -p "$TEST_DIR/busybox-awk"
    printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$TEST_DIR/busybox-awk/awk"
    chmod +x "$TEST_DIR/busybox-awk/awk"
    nul_byte_with_awk "$TEST_DIR/busybox-awk" "BusyBox awk"
fi
# An argument derived from the base is ${PHP_BASE}, or ${PHP_BASE:-...} as a
# whole. A FROM names a stage by name only; COPY --from also takes the number
# of a stage defined so far.
structure_case "a PHP_FROM that takes PHP_BASE only to replace it" php \
    're.sub(r"^ARG PHP_FROM=.*$", "ARG PHP_FROM=${PHP_BASE:+php:8.1-fpm}", text, count=1, flags=re.M)' \
    'FROM ${PHP_FROM} does not build on ${PHP_BASE}'
structure_case "a PHP_FROM with more after the expansion" php \
    're.sub(r"^ARG PHP_FROM=.*$", "ARG PHP_FROM=${PHP_BASE:-php:${PHP_VERSION}-fpm}${PHP_SUFFIX}", text, count=1, flags=re.M)' \
    'FROM ${PHP_FROM} does not build on ${PHP_BASE}'
structure_case "an argument derived inside a stage" php \
    'text.replace("FROM ${PHP_FROM} AS ffmpeg-build", "FROM ${PHP_FROM} AS ffmpeg-build\nARG LATER=${PHP_BASE}\nFROM ${LATER} AS later")' \
    'FROM ${LATER} does not build on ${PHP_BASE}'
# Docker expands the default of a global argument with the arguments declared
# before it only: PHP_FROM ahead of PHP_BASE, or PHP_BASE inside a stage,
# leaves PHP_FROM on the php:<version> tag, whatever PHP_BASE is given.
structure_case "PHP_FROM declared before PHP_BASE" cron \
    're.sub(r"^(ARG PHP_BASE=.*\n)(ARG PHP_FROM=.*\n)", r"\2\1", text, count=1, flags=re.M)' \
    'line 16: FROM ${PHP_FROM} does not build on ${PHP_BASE}'
structure_case "PHP_BASE declared inside the first stage" php \
    're.sub(r"^(ARG PHP_BASE=.*\n)((?:.*\n)*?FROM \$\{PHP_FROM\} AS ffmpeg-build\n)", r"\2\1", text, count=1, flags=re.M)' \
    'declares ARG PHP_BASE= after the first FROM, where no FROM reads it'
structure_case "NGINX_BASE declared after the FROM that reads it" nginx \
    're.sub(r"^(ARG NGINX_BASE=.*\n)(FROM \$\{NGINX_BASE\}\n)", r"\2\1", text, count=1, flags=re.M)' \
    'declares ARG NGINX_BASE= after the first FROM, where no FROM reads it'
structure_case "a FROM of a stage number" php \
    're.sub(r"^FROM \$\{PHP_FROM\}$", "FROM 0", text, count=1, flags=re.M)' \
    'FROM 0 does not build on ${PHP_BASE}'
structure_case "a COPY --from of a stage number no stage has" cron \
    'text.replace("COPY --from=ffmpeg-build ", "COPY --from=7 ")' \
    'COPY --from=7 is not an earlier stage'
# A mount is a CSV field list: every from key, in any case, with its quotes
# and backslashes removed the way Docker removes them from a flag, names a
# stage, by name.
structure_case "a mount FROM key in capitals" php \
    'text.replace("--mount=type=bind,from=ffmpeg-build,", "--mount=type=bind,FROM=busybox:latest,")' \
    'RUN --mount from=busybox:latest is not an earlier stage'
structure_case "a quoted mount field" php \
    'text.replace("--mount=type=bind,from=ffmpeg-build,", "--mount=type=bind,\"from=busybox:latest\",")' \
    'RUN --mount from=busybox:latest is not an earlier stage'
structure_case "a CSV quoted mount field" php \
    'text.replace("--mount=type=bind,from=ffmpeg-build,", "--mount=type=bind,\\\"from=busybox:latest\\\",")' \
    'RUN --mount from=busybox:latest is not an earlier stage'
structure_case "a mount key with a backslash" cron \
    'text.replace("--mount=type=bind,from=ffmpeg-build,", "--mount=type=bind,fr\\om=busybox:latest,")' \
    'RUN --mount from=busybox:latest is not an earlier stage'
structure_case "a second from key of a mount" cron \
    'text.replace("from=ffmpeg-build,", "from=ffmpeg-build,from=busybox:latest,")' \
    'RUN --mount from=busybox:latest is not an earlier stage'
structure_case "a mount from a stage number" php \
    'text.replace("--mount=type=bind,from=ffmpeg-build,", "--mount=type=bind,from=0,")' \
    'RUN --mount from=0 is not an earlier stage'
# The flags of FROM are read like those of COPY, RUN and ADD: Docker keeps the
# spaces inside quotes and after a backslash, so the word after them is part
# of the flag, and a FROM that seems to name ${NGINX_BASE} in its --platform
# builds on nginx:latest. Such a flag is refused, and so is a mount whose
# escaped space hides a from= key. A lone -- ends the flags.
structure_case "a double-quoted FROM flag holding the base" nginx \
    'text.replace("FROM ${NGINX_BASE}", "FROM --platform=\"linux/amd64${UNSET:+ ${NGINX_BASE} }\" nginx:latest", 1)' \
    'line 7: FROM --platform="linux/amd64${UNSET:+ has a quote or a backslash'
structure_case "a single-quoted FROM flag holding the base" nginx \
    'text.replace("FROM ${NGINX_BASE}", "FROM --platform=\x27linux/amd64${UNSET:+ ${NGINX_BASE} }\x27 nginx:latest", 1)' \
    "line 7: FROM --platform='linux/amd64\${UNSET:+ has a quote or a backslash"
structure_case "an escaped space in a FROM flag" nginx \
    'text.replace("FROM ${NGINX_BASE}", "FROM --platform=linux/amd64${UNSET:+\\ ${NGINX_BASE}\\ } nginx:latest", 1)' \
    'line 7: FROM --platform=linux/amd64${UNSET:+\ has a quote or a backslash'
structure_case "an escaped space before a from key of a mount" cron \
    'text.replace("--mount=type=bind,from=ffmpeg-build,source=/packages,target=/packages", "--mount=type=bind,source=/packages,target=/packages\\ ,from=busybox:latest")' \
    'line 132: RUN --mount=type=bind,source=/packages,target=/packages\ has a quote or a backslash'
structure_case "a FROM flag after a lone --" nginx \
    'text.replace("FROM ${NGINX_BASE}", "FROM -- --platform=linux/amd64 ${NGINX_BASE}", 1)' \
    'line 7: FROM --platform=linux/amd64 does not build on ${NGINX_BASE}'
# A Dockerfile under docker/ that DOCKERFILES does not list is checked by
# nothing.
copy_files
mkdir -p "$docker_dir/extra"
printf 'FROM debian:latest\n' > "$docker_dir/extra/Dockerfile"
if check_edited; then
    fail "--check-dockerfiles passed with a Dockerfile DOCKERFILES does not list: $(cat "$TEST_DIR/out")"
fi
grep -Fq 'extra/Dockerfile is not in DOCKERFILES' "$TEST_DIR/out" ||
    fail "the Dockerfile DOCKERFILES does not list must be named: $(cat "$TEST_DIR/out")"
rm -r "$docker_dir/extra"
# The ignore file of a Dockerfile is not one.
: > "$docker_dir/php/Dockerfile.dockerignore"
check_edited || fail "--check-dockerfiles took php/Dockerfile.dockerignore for a Dockerfile: $(cat "$TEST_DIR/out")"
rm "$docker_dir/php/Dockerfile.dockerignore"
# Docker reads these the same way, and so does the check.
for edit in \
    'text.replace("COPY --from=ffmpeg-build ", "COPY --from=0 ")' \
    'text.replace("--mount=type=bind,from=ffmpeg-build,", "--mount=type=bind,FROM=\"FFmpeg-Build\",")' \
    '"\ufeff" + text.replace("--no-install-recommends \\\n", "--no-install-recommends \\\n    # a comment\n\n")' \
    'text.replace("FROM ${PHP_FROM}\n", "FROM ${PHP_FROM}\r\r\n", 1)' \
    'text + "RUN [ \"$((1<<3))\" = 8 ] && cat <<<\"no heredoc\"\n"' \
    'text.replace("FROM ${NGINX_BASE}", "FROM --platform=\"$BUILDPLATFORM\" -- ${NGINX_BASE}", 1)'; do
    case "$edit" in *NGINX_BASE*) image=nginx ;; *install-recommends*|*PHP_FROM*|*heredoc*) image=php ;; *) image=cron ;; esac
    edit_dockerfile "a Docker reads as before" "$image" "$edit"
    check_edited || fail "--check-dockerfiles refused $edit: $(cat "$TEST_DIR/out")"
done
# The write refuses them too, rather than align a default nothing reads, and
# before it resolves or writes anything: the lock stays as it was.
copy_files
cp "$TEST_DIR/images.lock.good" "$lock"
sed -i 's|^FROM ${DEBIAN_BASE}$|FROM debian:latest|' "$docker_dir/init/Dockerfile"
: > "$calls"
before=$(sha256sum < "$lock")
if MOCK_DIGEST_SALT=moved resolve > "$TEST_DIR/out" 2>&1; then
    fail "the write passed with init/Dockerfile on debian:latest"
fi
grep -Fq 'init/Dockerfile' "$TEST_DIR/out" || fail "the write must name init/Dockerfile: $(cat "$TEST_DIR/out")"
[ "$(sha256sum < "$lock")" = "$before" ] && [ ! -s "$calls" ] ||
    fail "the write refused a Dockerfile only after it resolved or wrote the lock: $(cat "$calls")"
echo "PASS: a Dockerfile that does not build on the argument the lock pins, or that the check cannot read, fails the check and the write, which then writes nothing"
