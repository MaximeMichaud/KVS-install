#!/bin/bash
# .github/scripts/release-version.sh validates the tag in the prepare job of
# the release workflow. It accepts exactly the versions kvsctl orders,
# YY.M.PATCH with an optional pre-release of lower case letters and a number,
# so a tag kvsctl-release would refuse stops the run before any image is
# pushed under it. It then asks GitHub whether the version already has a
# release: only a 404 lets the run go on, since a run started again for a
# published version would push new images under it.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/.github/scripts/release-version.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-release-version.XXXXXX")
STUB_PID=
cleanup() {
    if [ -n "$STUB_PID" ]; then
        kill "$STUB_PID" 2>/dev/null || true
        wait "$STUB_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Outside GitHub Actions, without GITHUB_REPOSITORY and a token, the script
# never asks GitHub whether the release exists.
run() {
    env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY -u GH_TOKEN -u GITHUB_TOKEN "$SCRIPT" "$@"
}

accepted() {
    local tag=$1 prerelease=$2 out
    out=$(run "$tag" 2>&1) || fail "$tag was refused: $out"
    [ "$out" = "$(printf 'version=%s\nprerelease=%s\ntag=%s' "$tag" "$prerelease" "$tag")" ] ||
        fail "$tag is described as: $out"
}

refused() {
    local tag=$1 want=$2 out status=0
    out=$(run "$tag" 2>&1) || status=$?
    [ "$status" -ne 0 ] || fail "$tag was accepted"
    printf '%s\n' "$out" | grep -Fq "$want" || fail "$tag: the message does not say '$want': $out"
}

accepted 26.10.0 false
accepted 26.1.0 false
accepted 26.12.3 false
accepted 26.11.0-rc1 true
accepted 26.11.0-rc10 true
accepted 26.11.0-beta true
accepted 26.11.0-beta2 true
# 18 digits, which a 64-bit integer always holds.
accepted 26.10.999999999999999999 false
accepted 26.11.0-rc999999999999999999 true
echo "PASS: release and candidate tags are described for the workflow"

refused v26.10.0 "starts with v"
refused 26.01.0 "leading zero"
refused 26.10.00 "leading zero"
refused 06.10.0 "the year must not carry a leading zero"
refused 26.13.0 "1 to 12"
refused 26.0.0 "1 to 12"
refused 26.99999999999999999999.0 "1 to 12"
refused 26.10.9999999999999999999 "the number 9999999999999999999 has more than 18 digits"
refused 26.11.0-rc9999999999999999999 "the number 9999999999999999999 has more than 18 digits"
refused 2026.10.0 "is not YY.M.PATCH"
refused 26.10 "is not YY.M.PATCH"
refused 26.11.0-rc.1 "is not YY.M.PATCH"
refused 26.11.0-RC1 "is not YY.M.PATCH"
refused 26.11.0-rc01 "is not YY.M.PATCH"
refused 26.11.0-1 "is not YY.M.PATCH"
refused 26.11.0- "is not YY.M.PATCH"
refused main "is not YY.M.PATCH"
echo "PASS: a tag kvsctl would not order the same way is refused"

# The check against GitHub, with a loopback server standing in for the API
# (tests/fixtures/http-stub.py).
command -v python3 >/dev/null 2>&1 || fail "python3 is required for the HTTP stub"
: > "$TEST_DIR/routes"
python3 "$ROOT_DIR/tests/fixtures/http-stub.py" \
    "$TEST_DIR/routes" "$TEST_DIR/port" "$TEST_DIR/requests.log" &
STUB_PID=$!
for _ in $(seq 1 100); do
    [ -s "$TEST_DIR/port" ] && break
    kill -0 "$STUB_PID" 2>/dev/null || fail "the HTTP stub did not start"
    sleep 0.1
done
[ -s "$TEST_DIR/port" ] || fail "the HTTP stub did not start"
API="http://127.0.0.1:$(cat "$TEST_DIR/port")"
RELEASE=/repos/example/kvs-install/releases/tags/26.11.0
printf '{"tag_name":"26.11.0"}' > "$TEST_DIR/release.json"

# answer <status>: what the API says about the release of 26.11.0.
answer() {
    if [ "$1" = 404 ]; then
        : > "$TEST_DIR/routes"
    else
        printf '%s\t%s\t%s\t-\n' "$RELEASE" "$1" "$TEST_DIR/release.json" > "$TEST_DIR/routes"
    fi
}

asked() {
    env -u GITHUB_TOKEN GITHUB_ACTIONS=true GITHUB_REPOSITORY=example/kvs-install \
        GH_TOKEN=test-token GITHUB_API_URL="${1}" NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
        "$SCRIPT" 26.11.0
}

answer 404
: > "$TEST_DIR/requests.log"
out=$(asked "$API" 2>&1) || fail "a version without a release was refused: $out"
[ "$out" = "$(printf 'version=26.11.0\nprerelease=false\ntag=26.11.0')" ] ||
    fail "a version without a release is described as: $out"
grep -Fqx "${RELEASE}"$'\t'"Bearer test-token" "$TEST_DIR/requests.log" ||
    fail "GitHub was not asked about the release with the token: $(cat "$TEST_DIR/requests.log")"
echo "PASS: a version GitHub has no release for goes on"

refused_by_api() {
    local name=$1 api=$2 want=$3 out status=0
    out=$(asked "$api" 2>&1) || status=$?
    [ "$status" -ne 0 ] || fail "$name: the run went on: $out"
    printf '%s\n' "$out" | grep -Fq -- "$want" || fail "$name: the message does not say '$want': $out"
    if printf '%s\n' "$out" | grep -q '^version='; then
        fail "$name: the version was described although the run stops: $out"
    fi
}

answer 200
refused_by_api "a version that has a release" "$API" "release 26.11.0 already exists; cut a new patch instead of re-tagging"
for code in 403 500 502; do
    answer "$code"
    refused_by_api "an API answering $code" "$API" "could not check whether release 26.11.0 already exists (HTTP ${code})"
done
refused_by_api "an API that does not answer" http://127.0.0.1:1 "(HTTP 000)"
status=0
out=$(env -u GH_TOKEN -u GITHUB_TOKEN GITHUB_ACTIONS=true GITHUB_REPOSITORY=example/kvs-install \
    "$SCRIPT" 26.11.0 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "a run in GitHub Actions without a token skipped the check: $out"
printf '%s\n' "$out" | grep -Fq 'GH_TOKEN are needed' || fail "the missing token is not named: $out"
echo "PASS: a release that exists, or an answer that is not a 404, stops the run"
