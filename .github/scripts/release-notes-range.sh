#!/usr/bin/env bash
#
# Print the git range the release notes of a tag cover, for git-cliff.
#
#   release-notes-range.sh <tag>
#
# Prints "value=<previous stable tag>..<tag>" for $GITHUB_OUTPUT, or
# "value=" when no stable release came before <tag>, in which case the notes
# cover the whole history.
#
# The notes of a release list everything since the previous stable release,
# and so do the notes of its candidates: 26.11.0-rc1, 26.11.0-rc2 and 26.11.0
# all start at the last 26.10 release. The previous stable release is the
# highest YY.M.PATCH tag older than the version of <tag> among the tags of
# its history, so neither a candidate on the way nor the release tagged
# later on the same commit as a candidate moves the start. An explicit range
# also keeps tags pushed later out of the notes: git-cliff's --latest and
# --unreleased look at every tag of the repository, so they describe the
# wrong commits once a newer tag exists, for instance when an old run is
# started again.

set -euo pipefail

die() {
    printf 'release-notes-range: %s\n' "$*" >&2
    exit 1
}

[ $# -eq 1 ] || die "usage: release-notes-range.sh <tag>"

tag=$1
git rev-parse --verify --quiet "${tag}^{commit}" >/dev/null ||
    die "$tag is not a tag of this repository"
[[ "$tag" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-.*)?$ ]] ||
    die "$tag is not a release version"
version=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")

# older a b c: whether a.b.c comes before the version of the tag.
older() {
    local i parts=("$@")
    for i in 0 1 2; do
        if [ "${parts[$i]}" -lt "${version[$i]}" ]; then
            return 0
        fi
        if [ "${parts[$i]}" -gt "${version[$i]}" ]; then
            return 1
        fi
    done
    return 1
}

previous=$(
    git tag --merged "$tag" --list '[0-9]*' | while IFS= read -r candidate; do
        [[ "$candidate" =~ ^([0-9]{2})\.([0-9]+)\.([0-9]+)$ ]] || continue
        if older "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; then
            printf '%s\n' "$candidate"
        fi
    done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
)

if [ -z "$previous" ]; then
    echo "value="
else
    echo "value=${previous}..${tag}"
fi
