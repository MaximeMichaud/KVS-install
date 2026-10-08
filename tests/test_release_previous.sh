#!/bin/bash
# .github/scripts/release-previous.sh checks, in the prepare job of the
# release workflow, the manifest the release extends against
# .github/release.env: it has to be the stable list, and MIN_FROM one of its
# releases. kvsctl-release refuses both mistakes too, but only in the publish
# job, once every image is pushed under the version tag.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/.github/scripts/release-previous.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-release-previous.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required"

# manifest <name> <channel> <version>...: a manifest listing the versions in
# the order given, newest first as kvsctl-release writes them.
manifest() {
    local name=$1 channel=$2
    shift 2
    printf '%s\n' "$@" | jq -R . | jq -s --arg channel "$channel" \
        '{schema: 2, channel: $channel, updated: "2026-10-15T12:00:00Z", releases: map({version: .})}' \
        > "$TEST_DIR/$name.json"
    printf '%s' "$TEST_DIR/$name.json"
}

env_file() {
    printf 'NOTES="A line"\nMIN_FROM=%s\n' "${2:-}" > "$TEST_DIR/$1.env"
    printf '%s' "$TEST_DIR/$1.env"
}

accepted() {
    local name=$1 previous=$2 file=$3
    "$SCRIPT" "$previous" "$file" > "$TEST_DIR/out.log" 2>&1 ||
        fail "$name was refused: $(cat "$TEST_DIR/out.log")"
}

refused() {
    local name=$1 previous=$2 file=$3 want=$4 status=0
    "$SCRIPT" "$previous" "$file" > "$TEST_DIR/out.log" 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail "$name was accepted: $(cat "$TEST_DIR/out.log")"
    grep -Fq -- "$want" "$TEST_DIR/out.log" ||
        fail "$name: the message does not say '$want': $(cat "$TEST_DIR/out.log")"
}

stable=$(manifest stable stable 26.10.1 26.10.0)
accepted "the stable list" "$stable" "$(env_file any)"
grep -Fqx 'previous manifest: channel stable, 2 releases, latest 26.10.1' "$TEST_DIR/out.log" ||
    fail "the log does not describe the previous manifest: $(cat "$TEST_DIR/out.log")"
accepted "a stop the list holds" "$stable" "$(env_file stop 26.10.0)"
grep -Fqx 'min from:          26.10.0' "$TEST_DIR/out.log" || fail "the log does not show the stop: $(cat "$TEST_DIR/out.log")"
accepted "the first release" "$TEST_DIR/none.json" "$(env_file first)"
grep -Fqx 'previous manifest: none, this is the first release' "$TEST_DIR/out.log" ||
    fail "the log does not say this is the first release: $(cat "$TEST_DIR/out.log")"
echo "PASS: a release extends the stable list, through a stop it holds"

refused "a stop that was never out" "$stable" "$(env_file never 26.10.9)" \
    "MIN_FROM in $TEST_DIR/never.env is 26.10.9, which the manifest of the latest release does not list"
grep -Fq 'its newest releases are 26.10.1, 26.10.0' "$TEST_DIR/out.log" ||
    fail "the refusal must name the releases there are: $(cat "$TEST_DIR/out.log")"
long=$(manifest long stable 26.12.2 26.12.1 26.12.0 26.11.3 26.11.2 26.11.1 26.11.0 26.10.3 26.10.2 26.10.1 26.10.0)
refused "a stop missing from a long list" "$long" "$(env_file long 26.9.0)" \
    "its newest releases are 26.12.2, 26.12.1, 26.12.0, 26.11.3, 26.11.2, 26.11.1, 26.11.0, 26.10.3, 26.10.2, 26.10.1 ("
refused "a stop before the first release" "$TEST_DIR/none.json" "$(env_file first-stop 26.10.0)" \
    "the first release cannot name a stop"
refused "the list of a candidate" "$(manifest candidate candidate 26.11.0-rc1 26.10.1 26.10.0)" "$(env_file candidate)" \
    "the manifest of the latest release is of channel 'candidate', not stable"
refused "a file that is no manifest" "$(printf '<html></html>\n' > "$TEST_DIR/page.json"; printf '%s' "$TEST_DIR/page.json")" \
    "$(env_file page)" "is not a manifest"
refused "a missing release.env" "$stable" "$TEST_DIR/missing.env" "does not exist"

# In the workflow the script reads the release.env of its checkout, which
# the refusal names as the repository does, the way docs/releasing.md
# quotes it.
mkdir -p "$TEST_DIR/checkout/.github/scripts"
cp "$SCRIPT" "$TEST_DIR/checkout/.github/scripts/"
printf 'NOTES="A line"\nMIN_FROM=26.10.9\n' > "$TEST_DIR/checkout/.github/release.env"
status=0
"$TEST_DIR/checkout/.github/scripts/release-previous.sh" "$stable" > "$TEST_DIR/out.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "a stop the list lacks was accepted from the release.env of the checkout"
grep -Fq 'MIN_FROM in .github/release.env is 26.10.9, which the manifest of the latest release does not list' "$TEST_DIR/out.log" ||
    fail "the refusal must name .github/release.env as the repository does: $(cat "$TEST_DIR/out.log")"
# A file given as an argument is named as it was given, wherever it lies,
# under the checkout or under a TMPDIR that happens to be there.
printf 'NOTES="A line"\nMIN_FROM=26.10.9\n' > "$TEST_DIR/checkout/.github/other.env"
status=0
"$TEST_DIR/checkout/.github/scripts/release-previous.sh" "$stable" "$TEST_DIR/checkout/.github/other.env" > "$TEST_DIR/out.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "a stop the list lacks was accepted from a file given as an argument"
grep -Fq "MIN_FROM in $TEST_DIR/checkout/.github/other.env is 26.10.9," "$TEST_DIR/out.log" ||
    fail "the refusal must name a file given as an argument as it was given: $(cat "$TEST_DIR/out.log")"
echo "PASS: a manifest kvsctl-release would not extend stops the release before the images are pushed"
