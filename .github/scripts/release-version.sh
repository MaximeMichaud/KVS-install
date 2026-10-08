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
# January release. No leading zero in any number, because the manifest prints
# the numbers and 26.01.0 would round trip to 26.1.0 and stop matching the
# tag, and no number kvsctl cannot hold: it reads each one, the number of a
# pre-release included, into a 64-bit integer, which 18 digits always fit.
# A pre-release carries a suffix (26.11.0-rc1); it is published with the
# GitHub pre-release flag, so releases/latest/download keeps pointing at the
# newest stable release. The suffix is lower case letters and an optional
# number, the form kvsctl orders (rc1 before rc2, beta before rc); anything
# else would only be refused by kvsctl-release in the publish job, after the
# images were pushed. The tag carries no "v": it is the version itself, the
# string the manifest and the image tags carry.
#
# When GITHUB_REPOSITORY and a token are in the environment, a tag that
# already has a GitHub release is refused: a re-tag would move the assets
# under the feet of everyone who already fetched the manifest, and a run
# started again would push new images under a published version. Only a
# 404 from the API lets the run go on; any other answer, or none, stops it,
# since starting the run again costs less than a version published twice.
# Inside GitHub Actions the check is not optional: without the repository
# or a token the script stops instead of skipping it.

set -euo pipefail

die() {
    printf 'release-version: %s\n' "$*" >&2
    exit 1
}

[ $# -eq 1 ] || die "usage: release-version.sh <tag>"

tag=$1
version=$tag

case "$tag" in
    v[0-9]*) die "tag '$tag' starts with v: the tag is the version itself, ${tag#v}" ;;
esac
if [[ ! "$version" =~ ^([0-9]{2})\.([0-9]+)\.([0-9]+)(-([a-z]+(0|[1-9][0-9]*)?))?$ ]]; then
    die "tag '$tag' is not YY.M.PATCH, optionally followed by a pre-release such as -rc1"
fi

year=${BASH_REMATCH[1]}
month=${BASH_REMATCH[2]}
patch=${BASH_REMATCH[3]}
pre=${BASH_REMATCH[5]:-}
pre_number=${BASH_REMATCH[6]:-}

case "$year" in
    0?) die "the year must not carry a leading zero: $version" ;;
esac
case "$month" in
    0?*) die "the month must not carry a leading zero: $version" ;;
esac
case "$patch" in
    0?*) die "the patch must not carry a leading zero: $version" ;;
esac
# Matched as text: test cannot read a month of twenty digits as a number.
case "$month" in
    [1-9] | 1[0-2]) ;;
    *) die "the month must be 1 to 12: $version" ;;
esac
for number in "$patch" "$pre_number"; do
    [ "${#number}" -le 18 ] ||
        die "the number $number has more than 18 digits, too many for kvsctl: $version"
done

prerelease=false
[ -n "$pre" ] && prerelease=true

token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "$token" ]; then
    api="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/releases/tags/${tag}"
    # curl writes 000 itself when no answer came, so its exit status adds
    # nothing here.
    status=$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github+json" \
        "$api" || true)
    case "${status:-000}" in
        404) ;;
        200) die "release $tag already exists; cut a new patch instead of re-tagging" ;;
        *) die "could not check whether release $tag already exists (HTTP ${status:-000}); run the job again" ;;
    esac
elif [ "${GITHUB_ACTIONS:-}" = true ]; then
    die "GITHUB_REPOSITORY and GH_TOKEN are needed to check that release $tag does not exist yet"
fi

printf 'version=%s\n' "$version"
printf 'prerelease=%s\n' "$prerelease"
printf 'tag=%s\n' "$tag"
