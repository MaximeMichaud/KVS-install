#!/usr/bin/env bash
#
# Check the manifest a release extends against .github/release.env, before
# anything is built or pushed.
#
#   release-previous.sh <previous-manifest> [release.env]
#
# <previous-manifest> is the file verify-manifest.sh writes: the manifest of
# the latest release, its signature checked. It does not exist for the first
# release, when no release carries one yet. The publish job extends that same
# manifest, and kvsctl-release refuses to sign
#
#   - on a manifest of another channel than stable: a release extends the
#     stable list, and the list of a candidate would carry the candidate into
#     it;
#   - with a MIN_FROM the manifest does not list: every older installation
#     would have to go through a release no manifest offers.
#
# Either would only show up there, after the images job has pushed every
# image under the version tag. The prepare job runs this script first.

set -euo pipefail

die() {
    printf 'release-previous: %s\n' "$*" >&2
    exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: release-previous.sh <previous-manifest> [release.env]"

previous=$1
repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
file=${2:-${repo_root}/.github/release.env}
[ -f "$file" ] || die "$file does not exist"
# The messages name the release.env of the checkout as the repository does,
# and a file given as an argument as it was given.
shown=${2:-.github/release.env}

MIN_FROM=''
# shellcheck source=/dev/null
. "$file"

if [ ! -e "$previous" ]; then
    [ -z "$MIN_FROM" ] ||
        die "MIN_FROM in $shown is $MIN_FROM, and no release carries a manifest yet: the first release cannot name a stop"
    echo "previous manifest: none, this is the first release"
    exit 0
fi

command -v jq >/dev/null 2>&1 || die "jq is required"
jq -e '(.channel | type == "string") and (.releases | type == "array")' "$previous" >/dev/null 2>&1 ||
    die "$previous is not a manifest"

channel=$(jq -r '.channel' "$previous")
[ "$channel" = stable ] ||
    die "the manifest of the latest release is of channel '${channel}', not stable: a release extends the stable list, which only a stable release carries, so a candidate is marked as the latest release. Mark the newest stable release as the latest one again (docs/releasing.md, Only stack releases)"

if [ -n "$MIN_FROM" ] &&
    ! jq -e --arg version "$MIN_FROM" 'any(.releases[]; .version == $version)' "$previous" >/dev/null; then
    die "MIN_FROM in $shown is ${MIN_FROM}, which the manifest of the latest release does not list, so no installation could go through it; its newest releases are $(jq -r '[.releases[:10][].version] | join(", ")' "$previous") (docs/releasing.md, A required stop)"
fi

printf 'previous manifest: channel %s, %s releases, latest %s\n' "$channel" \
    "$(jq '.releases | length' "$previous")" "$(jq -r '.releases[0].version // "none"' "$previous")"
printf 'min from:          %s\n' "${MIN_FROM:-any version}"
