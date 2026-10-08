#!/bin/bash
# .github/scripts/release-notes-range.sh gives git-cliff the commits the
# notes of a tag list: everything since the previous stable release, for a
# candidate (26.11.0-rc1) and for the release it leads to (26.11.0) alike, and
# the whole history for the first stable release. A tag pushed later never
# changes the range of an earlier one, so a run started again later writes
# the same notes.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/.github/scripts/release-notes-range.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-release-range.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

repo() {
    git -C "$TEST_DIR/repo" -c user.name=test -c user.email=test@example.com \
        -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

# An annotated tag on a new commit, as a maintainer cuts a release.
release() {
    repo commit -q --allow-empty -m "feat: before $1"
    repo tag -a -m "$1" "$1"
}

range_of() {
    (cd "$TEST_DIR/repo" && "$SCRIPT" "$1")
}

expect() {
    local tag=$1 want=$2 got
    got=$(range_of "$tag" 2>&1) || fail "the range of $tag could not be read: $got"
    [ "$got" = "value=$want" ] || fail "the range of $tag is '$got', expected 'value=$want'"
}

git init -q "$TEST_DIR/repo"
repo commit -q --allow-empty -m "feat: the first commit"
release 26.10.0-rc1
expect 26.10.0-rc1 ""
release 26.10.0
expect 26.10.0 ""
echo "PASS: before the first stable release the notes cover the whole history"

release 26.11.0-rc1
release 26.11.0-rc2
# The release is tagged on the commit of its last candidate.
repo tag -a -m 26.11.0 26.11.0 "26.11.0-rc2^{commit}"
expect 26.11.0-rc1 "26.10.0..26.11.0-rc1"
expect 26.11.0-rc2 "26.10.0..26.11.0-rc2"
expect 26.11.0 "26.10.0..26.11.0"
release 26.11.1
expect 26.11.1 "26.11.0..26.11.1"
echo "PASS: a candidate and its release both start at the previous stable release"

release 26.12.0
release 27.1.0-rc1
expect 26.11.0 "26.10.0..26.11.0"
expect 26.11.0-rc1 "26.10.0..26.11.0-rc1"
expect 27.1.0-rc1 "26.12.0..27.1.0-rc1"
echo "PASS: a tag pushed later does not change the range of an earlier one"

refused() {
    local tag=$1 want=$2 status=0
    range_of "$tag" > "$TEST_DIR/out.log" 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail "the range of $tag was given: $(cat "$TEST_DIR/out.log")"
    grep -Fq "$want" "$TEST_DIR/out.log" ||
        fail "the range of $tag: the message does not say '$want': $(cat "$TEST_DIR/out.log")"
}

refused 26.99.0 "is not a tag of this repository"
repo tag -a -m other build-42
refused build-42 "is not a release version"
echo "PASS: an unknown tag or one that is no release is refused"

# Tags that are not stable releases never start the range, and a stable
# release on another line of history is not in it.
release 27.1.x0
release v27.0.9
repo checkout -q -b maintenance 26.12.0
release 26.12.1
repo checkout -q -
release 27.1.0
expect 27.1.0 "26.12.0..27.1.0"
echo "PASS: only an earlier stable release of the history starts the range"

# Versions compare as numbers: 27.10.0 comes after 27.9.0, and 27.11.10
# after 27.11.9, although they sort before them as text.
release 27.9.0
release 27.10.0
release 27.11.0-rc1
expect 27.11.0-rc1 "27.10.0..27.11.0-rc1"
release 27.11.0
release 27.11.9
release 27.11.10
release 27.11.11
expect 27.11.11 "27.11.10..27.11.11"
echo "PASS: the previous stable release is the highest version, not the last one as text"
