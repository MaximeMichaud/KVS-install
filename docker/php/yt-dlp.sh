#!/bin/sh
# The yt-dlp command of the PHP-FPM and cron images, the same file in both.
#
# yt-dlp can be there twice, each copy a directory per release named after
# its version, with a "current" link to the one in use: the release the image
# was built with, in /usr/local/lib/yt-dlp, and the newer one the cron
# container keeps in the yt-dlp volume (yt-dlp-update), which both
# containers mount and updates/ links to while the updates are on.
# This runs the newer of the two, so an update reaches both containers and
# outlives a recreated container, and a newer image is never shadowed by an
# older release an earlier image left in the volume. A copy that is missing,
# or not executable, is never run.

image=/usr/local/lib/yt-dlp

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

dir=$image
version=$(readlink "$image/current")
if update=$(readlink "$image/updates/current" 2> /dev/null) &&
    newer "$update" "$version" &&
    [ -x "$image/updates/$update/yt-dlp" ]; then
    dir=$image/updates
    version=$update
fi
exec "$dir/$version/yt-dlp" "$@"
