#!/bin/sh
# Weekly yt-dlp update, run by /etc/cron.d/yt-dlp-update as root.
#
# The image ships a pinned yt-dlp whose sha256 the Dockerfile checks. This
# job moves that binary forward, because a stale yt-dlp stops downloading
# within weeks, so it verifies the new one the same way: the sha256 must be
# the one the release publishes in SHA2-256SUMS, and the replacement is a
# rename inside the target directory, never a partially written file.
#
# The entrypoint removes this job when YT_DLP_AUTO_UPDATE is no, which is how
# a published release keeps exactly the binary its manifest describes.

set -eu

RELEASE_URL=${YT_DLP_RELEASE_URL:-https://github.com/yt-dlp/yt-dlp/releases/latest/download}
# The self-contained build, the same asset the Dockerfile installs.
ASSET=${YT_DLP_ASSET:-yt-dlp_linux}
TARGET=${YT_DLP_TARGET:-/usr/local/bin/yt-dlp}

TARGET_DIR=$(dirname "$TARGET")
NEW_FILE="${TARGET_DIR}/.yt-dlp.new.$$"
SUMS_FILE="${TARGET_DIR}/.yt-dlp.sums.$$"

cleanup() {
    rm -f -- "$NEW_FILE" "$SUMS_FILE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "yt-dlp-update: $*" >&2
    exit 1
}

curl -fsSL "${RELEASE_URL}/${ASSET}" -o "$NEW_FILE" ||
    fail "could not download ${ASSET}"
curl -fsSL "${RELEASE_URL}/SHA2-256SUMS" -o "$SUMS_FILE" ||
    fail "could not download the release checksums"

expected=$(awk -v asset="$ASSET" '$2 == asset { print $1; exit }' "$SUMS_FILE")
[ -n "$expected" ] || fail "SHA2-256SUMS has no entry for ${ASSET}"

actual=$(sha256sum "$NEW_FILE" | awk '{ print $1 }')
[ "$expected" = "$actual" ] ||
    fail "checksum mismatch for ${ASSET}: expected ${expected}, got ${actual}"

chmod 0755 "$NEW_FILE"
mv -f -- "$NEW_FILE" "$TARGET"
echo "yt-dlp-update: installed ${ASSET} ${actual} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
