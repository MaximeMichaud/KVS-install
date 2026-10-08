#!/bin/sh
# yt-dlp update, run as root in the cron container: every Sunday by
# /etc/cron.d/yt-dlp-update, and once in the background when the container
# starts, so a new or recreated container does not wait for Sunday. The
# entrypoint does neither when YT_DLP_AUTO_UPDATE is no, or when no yt-dlp
# volume is mounted: both containers then run the yt-dlp of their image, the
# release the Dockerfiles pin.
#
# Sites change what yt-dlp parses, and an old release stops downloading from
# them. Each image carries the release its Dockerfile pins and checks; this
# job keeps the latest release in the yt-dlp volume, which the PHP-FPM
# container mounts too, and the yt-dlp command of both containers
# (yt-dlp.sh) runs the newer of the two. A release is installed only when it
# is newer than both, once the sha256 of its asset is the one the release
# publishes in SHA2-256SUMS and the command it unpacks, run as www-data,
# prints its version. It is unpacked in a directory of its own and "current"
# moves to it in one rename, so no run sees a partial copy; the release it
# replaces stays until the next update, for the runs that started with it.

set -eu

RELEASES=${YT_DLP_RELEASES:-https://github.com/yt-dlp/yt-dlp/releases}
# The volume, and the copy of the image with the name of its build.
DIR=${YT_DLP_DIR:-/var/lib/yt-dlp}
IMAGE_DIR=${YT_DLP_IMAGE_DIR:-/usr/local/lib/yt-dlp}

log() {
    echo "yt-dlp-update $(date -u +%Y-%m-%dT%H:%M:%SZ): $*"
}

fail() {
    log "$*" >&2
    exit 1
}

# An HTTP error is a failure, and the time limits keep a stalled connection
# from holding the lock until the container stops.
fetch() {
    curl -fsSL --connect-timeout 30 --max-time 900 "$@"
}

# Runs a command as www-data, as PHP-FPM and the KVS task run yt-dlp, when
# this script runs as root. A release runs that way from its first run, the
# check of its version: its sha256 comes from the same release page, which
# proves the download is the file that page lists, not what the file does.
# The working directory is /, which www-data can enter: cron starts the job
# in the home directory of root.
as_www_data() {
    if [ "$(id -u)" -ne 0 ]; then
        "$@"
        return
    fi
    (cd / && exec setpriv --reuid=www-data --regid=www-data --clear-groups --no-new-privs -- "$@")
}

# Succeeds when the version $1 is newer than the version $2. A version is
# numbers separated by dots, the way yt-dlp tags its releases (2026.08.19).
# Anything else in $1 is never newer, and anything else in $2 is older than
# every version.
newer() {
    case $1 in '' | *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
    case $2 in '' | *[!0-9.]* | .* | *. | *..*) return 0 ;; esac
    set -- "$1." "$2."
    while [ -n "$1" ] || [ -n "$2" ]; do
        newer_left=${1%%.*}
        newer_right=${2%%.*}
        if [ "${newer_left:-0}" -gt "${newer_right:-0}" ]; then
            return 0
        fi
        if [ "${newer_left:-0}" -lt "${newer_right:-0}" ]; then
            return 1
        fi
        set -- "${1#*.}" "${2#*.}"
    done
    return 1
}

[ -d "$DIR" ] || fail "${DIR} does not exist"
# One update at a time: the weekly job can meet the one of a start.
exec 9> "$DIR/.lock"
if ! flock -n 9; then
    log "another update is running"
    exit 0
fi

asset=$(cat "$IMAGE_DIR/asset") || fail "the image does not name the yt-dlp build it runs"
pinned=$(readlink "$IMAGE_DIR/current") || fail "the image has no yt-dlp"
# A copy the yt-dlp command would not run counts as none, and is replaced.
installed=$(readlink "$DIR/current" 2> /dev/null) || installed=
if [ -n "$installed" ] && [ ! -x "$DIR/$installed/yt-dlp" ]; then
    installed=
fi

# github.com redirects the latest release to the page of its tag.
latest=$(fetch -I -o /dev/null -w '%{url_effective}' "${RELEASES}/latest") ||
    fail "could not reach ${RELEASES}/latest"
tag=${latest##*/}
case "$latest" in
    */tag/*) ;;
    *) fail "${RELEASES}/latest led to ${latest}, not to a release" ;;
esac
case "$tag" in
    '' | *[!0-9.]* | .* | *. | *..*) fail "the latest release has a tag that is not a version: ${tag}" ;;
esac
if ! newer "$tag" "$pinned" || { [ -n "$installed" ] && ! newer "$tag" "$installed"; }; then
    log "nothing to do: the latest release is ${tag}, the image has ${pinned} and the volume ${installed:-none}"
    exit 0
fi

work=$(mktemp -d "$DIR/.new.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
# mktemp opens it to root alone; www-data runs the release through it.
chmod 0711 "$work"
trap 'exit 130' INT
trap 'exit 143' TERM

fetch -o "$work/SHA2-256SUMS" "${RELEASES}/download/${tag}/SHA2-256SUMS" ||
    fail "could not download the checksums of ${tag}"
fetch -o "$work/$asset" "${RELEASES}/download/${tag}/${asset}" ||
    fail "could not download ${asset} of ${tag}"
expected=$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$work/SHA2-256SUMS")
[ -n "$expected" ] || fail "the SHA2-256SUMS of ${tag} has no entry for ${asset}"
actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
[ "$expected" = "$actual" ] ||
    fail "checksum mismatch for ${asset} of ${tag}: expected ${expected}, got ${actual}"

unzip -q "$work/$asset" -d "$work/tree" || fail "could not unpack ${asset} of ${tag}"
mv -- "$work/tree/${asset%.zip}" "$work/tree/yt-dlp" ||
    fail "${asset} of ${tag} holds no ${asset%.zip}"
chmod 0755 "$work/tree"
version=$(as_www_data "$work/tree/yt-dlp" --version) || fail "the yt-dlp of ${tag} does not run here"
[ "$version" = "$tag" ] || fail "the yt-dlp of ${tag} says it is ${version}"
# On disk before "current" names it: after a crash, current must not lead to
# files that were never written.
find "$work/tree" -exec sync -- {} +

# A directory of this release can only be one an interrupted run left: the
# volume runs an older release.
rm -rf -- "${DIR:?}/${tag}"
mv -- "$work/tree" "$DIR/$tag"
ln -s "$tag" "$work/current"
mv -fT -- "$work/current" "$DIR/current"

# Keep the release just replaced, for the runs that started with it, and
# drop what interrupted runs left.
for entry in "$DIR"/* "$DIR"/.new.*; do
    case "${entry##*/}" in
        current | "$tag" | "$installed" | '*' | '.new.*') ;;
        *) rm -rf -- "$entry" ;;
    esac
done
log "installed yt-dlp ${tag} (${asset}, sha256 ${actual}); the image has ${pinned}"
