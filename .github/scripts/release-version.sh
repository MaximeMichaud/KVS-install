#!/usr/bin/env bash
#
# Validate a release tag and describe it to the workflow.
#
#   release-version.sh <tag>
#
# Prints key=value lines meant for $GITHUB_OUTPUT:
#
#   version=26.10.0
#   prerelease=false
#   tag=26.10.0
#
# The stack version is calendar versioning, YY.M.PATCH: 26.10.0 is the first
# release of October 2026, 26.10.1 the next patch that month, 26.1.0 a
# January release. No leading zero in the month, because the manifest prints
# the number and 26.01.0 would round trip to 26.1.0 and stop matching the tag.
# A pre-release carries a suffix (26.11.0-rc1); it is published with the
# GitHub pre-release flag, so releases/latest/download keeps pointing at the
# newest stable release.
#
# When GITHUB_REPOSITORY and a token are in the environment, a tag that
# already has a GitHub release is refused: a re-tag would move the assets
# under the feet of everyone who already fetched the manifest.

set -euo pipefail

die() {
    printf 'release-version: %s\n' "$*" >&2
    exit 1
}

[ $# -eq 1 ] || die "usage: release-version.sh <tag>"

tag=$1
version=${tag#v}

if [[ ! "$version" =~ ^([0-9]{2})\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z][0-9A-Za-z.-]*))?$ ]]; then
    die "tag '$tag' is not YY.M.PATCH, optionally followed by -<pre-release>"
fi

month=${BASH_REMATCH[2]}
patch=${BASH_REMATCH[3]}
pre=${BASH_REMATCH[5]:-}

case "$month" in
    0?*) die "the month must not carry a leading zero: $version" ;;
esac
case "$patch" in
    0?*) die "the patch must not carry a leading zero: $version" ;;
esac
if [ "$month" -lt 1 ] || [ "$month" -gt 12 ]; then
    die "the month must be 1 to 12: $version"
fi

prerelease=false
[ -n "$pre" ] && prerelease=true

token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "$token" ]; then
    api="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/releases/tags/${tag}"
    status=$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github+json" \
        "$api" || echo 000)
    case "$status" in
        404) ;;
        200) die "release $tag already exists; cut a new patch instead of re-tagging" ;;
        *) printf 'release-version: could not check for an existing release (HTTP %s)\n' "$status" >&2 ;;
    esac
fi

printf 'version=%s\n' "$version"
printf 'prerelease=%s\n' "$prerelease"
printf 'tag=%s\n' "$tag"
