#!/bin/bash
# README describes the Docker images as this repository builds them: the CPU
# architectures they build on, the NGINX the lock pins, and how yt-dlp stays
# current. Each drifted once: the NGINX line named a version two minor
# releases behind the pinned image, the architectures went unstated while
# the images could only build on amd64, yt-dlp was said to be the latest
# release while the images pinned one, and a multi-site site added before the
# yt-dlp volume was not told how to get it.
# shellcheck disable=SC2016  # The patterns hold the backquotes of the Markdown.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

readme=$(tr -d '\r' < "$ROOT_DIR/README.md")
tab=$'\t'

# The NGINX of the Docker stack moves with every refresh of the lock, so the
# README says where it comes from rather than a number that goes stale.
nginx=$(grep -E '^- NGINX' <<< "$readme") || fail "README lists no NGINX"
[ "$(grep -c . <<< "$nginx")" = 1 ] || fail "README lists NGINX more than once"
if grep -Eq '[0-9]+\.[0-9]+' <<< "$nginx"; then
    fail "README names an NGINX version, which the next refresh of the lock makes wrong: $nginx"
fi
for claim in 'mainline' '`docker/images.lock`'; do
    grep -Fq "$claim" <<< "$nginx" ||
        fail "README must say that docker/images.lock pins the NGINX mainline image: $nginx"
done
grep -Eq "^nginx${tab}-${tab}nginx:mainline@sha256:[0-9a-f]{64}$" "$ROOT_DIR/docker/images.lock" ||
    fail "docker/images.lock no longer pins NGINX mainline, which README names"
echo "PASS: README names the NGINX the lock pins, without a version that drifts"

architectures=$(awk '/^### CPU architectures$/ { inside = 1; next } inside && /^#/ { exit } inside' <<< "$readme")
[ -n "$architectures" ] || fail "README has no CPU architectures section"
for claim in 'amd64 (x86-64) and arm64 (aarch64)' 'linux/amd64 only' 'kvsctl manages amd64 servers only'; do
    grep -Fq "$claim" <<< "$architectures" || fail "the CPU architectures section of README does not say '$claim'"
done
echo "PASS: README states the architectures the Docker path builds, and that kvsctl releases are amd64 only"

grep -Fxq '#### yt-dlp' <<< "$readme" || fail "README has no yt-dlp section"
yt_dlp=$(awk '/^#### yt-dlp$/ { inside = 1; next } inside && /^#/ { exit } inside' <<< "$readme")
grep -Fq '`YT_DLP_AUTO_UPDATE=no`' <<< "$yt_dlp" || fail "README does not document YT_DLP_AUTO_UPDATE"
grep -Fq '`/var/log/yt-dlp-update.log`' <<< "$yt_dlp" || fail "README does not say where the yt-dlp updates are logged"
if grep -Fq 'Installs the latest version of yt-dlp' <<< "$readme"; then
    fail "README still says the latest yt-dlp is installed, which the Docker images do not do at build time"
fi
# An additional multi-site site has its own .env, and keeps the compose file
# it was given, which mounts no yt-dlp volume if it is older than the volume.
grep -Fq 'or in the `.env` of an additional multi-site site' <<< "$yt_dlp" ||
    fail "the yt-dlp section of README does not say where an additional multi-site site sets YT_DLP_AUTO_UPDATE"
grep -Fq 'copy the template over its `docker-compose.yml` again' <<< "$yt_dlp" ||
    fail "the yt-dlp section of README does not say how a multi-site site added before the yt-dlp volume gets it"
echo "PASS: README says how yt-dlp stays current in the Docker images"
