#!/bin/bash
# .github/scripts/verify-manifest.sh decides what the publish job builds the
# new manifest on: the signed manifest of the latest release, which has to
# list the newest stack release, or nothing for the very first release. A
# 404 is the first release only while no published release of a stable
# version carries an asset of the release workflow; otherwise the latest
# release is not a stack release, or the newest stack release lost its
# manifest, and taking the 404 for a first release would sign a manifest that
# drops every earlier release. Any other answer, an answer cut short, a list
# that is not one, a manifest without its signature or one that does not
# verify stops the release too.
#
# GitHub is a loopback HTTP server here (tests/fixtures/http-stub.py), and
# "go run ./cmd/kvsctl-release verify" a stand-in that accepts a signature
# file reading "signed <sha256 of the manifest> by <key>" for one of the
# --pub keys.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/.github/scripts/verify-manifest.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-verify-manifest.XXXXXX")
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

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the HTTP stub"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# 32 bytes of zeros and of ones, in base64: the shape of an Ed25519 key.
KEY1=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
KEY2=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
REPOSITORY=example/kvs-install
RELEASES="/api/repos/${REPOSITORY}/releases"

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/files"
cat > "$TEST_DIR/bin/go" <<'EOF'
#!/bin/bash
[ "${1:-} ${2:-} ${3:-}" = "run ./cmd/kvsctl-release verify" ] || { echo "unexpected go call: $*" >&2; exit 2; }
[ "$(basename "$PWD")" = cli ] || { echo "go ran in $PWD, not in cli/" >&2; exit 2; }
shift 3
manifest='' signature='' keys=()
while [ $# -gt 0 ]; do
    case "$1" in
        --manifest) manifest=$2 ;;
        --signature) signature=$2 ;;
        --pub) keys+=("$2") ;;
        *) echo "unexpected argument $1" >&2; exit 2 ;;
    esac
    shift 2
done
sum=$(sha256sum < "$manifest" | cut -d' ' -f1)
for key in "${keys[@]}"; do
    if [ "$(cat "$signature")" = "signed $sum by $key" ]; then
        echo "manifest verified"
        exit 0
    fi
done
echo "manifest signature does not match any release key this kvsctl knows" >&2
exit 1
EOF
chmod +x "$TEST_DIR/bin/go"

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
STUB="http://127.0.0.1:$(cat "$TEST_DIR/port")"

# A file served by the stub, from its content.
file() {
    printf '%s' "$2" > "$TEST_DIR/files/$1"
    printf '%s' "$TEST_DIR/files/$1"
}

# route <path> <status> [body file] [Location] [cut]: "cut" stops the
# answer right after its headers.
route() {
    printf '%s\t%s\t%s\t%s%s\n' "$1" "$2" "${3:--}" "${4:--}" "${5:+$'\t'$5}" >> "$TEST_DIR/routes"
}

# A release of the list, as the API describes it, with the assets named.
release_json() {
    local tag=$1 draft=$2 prerelease=$3 asset assets=''
    shift 3
    for asset in "$@"; do
        [ -n "$asset" ] || continue
        assets+="${assets:+,}{\"name\":\"$asset\"}"
    done
    printf '{"tag_name":"%s","draft":%s,"prerelease":%s,"html_url":"https://github.com/%s/releases/tag/%s","assets":[%s]}' \
        "$tag" "$draft" "$prerelease" "$REPOSITORY" "$tag" "$assets"
}

# The list of releases, one page of up to 100.
releases_page() {
    local page=$1 name=$2
    shift 2
    local IFS=,
    route "${RELEASES}?per_page=100&page=${page}" 200 "$(file "$name" "[$*]")"
}

latest() {
    route "${RELEASES}/latest" 200 "$(file "latest-$1.json" "$(release_json "$1" false false "")")"
}

# A full page of the list: 100 candidates, none of them a stack release.
filler=()
for i in $(seq 1 100); do
    filler+=("$(release_json "26.12.0-rc$i" false true manifest.json)")
done

# What a stack release still carries once its manifest.json is deleted.
LOST_ASSETS=(manifest.json.sig kvs-stack-26.11.0.tar.gz kvsctl-linux-amd64 kvsctl-release-linux-amd64 SHA256SUMS)

# The manifest of the latest release listing these versions, and its
# signature by a key.
manifest() {
    local key=$1 versions='' version sum
    shift
    for version in "$@"; do
        versions+="${versions:+,}{\"version\":\"$version\"}"
    done
    file manifest.json "{\"releases\":[$versions]}" > /dev/null
    sum=$(sha256sum < "$TEST_DIR/files/manifest.json" | cut -d' ' -f1)
    file manifest.json.sig "signed $sum by $key" > /dev/null
}

# A run that never ends fails here instead of hanging the suite.
run() {
    : > "$TEST_DIR/requests.log"
    rm -f "$TEST_DIR/previous.json"
    timeout 30 env -u GITHUB_TOKEN GITHUB_REPOSITORY="$REPOSITORY" GH_TOKEN=test-token \
        GITHUB_API_URL="$STUB/api" KVSCTL_RELEASE_PUBKEY="${PUBKEY:-$KEY1}" \
        NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 PATH="$TEST_DIR/bin:$PATH" \
        "$SCRIPT" "${BASE_URL:-$STUB/download}" "$TEST_DIR/previous.json"
}

accepted() {
    local name=$1
    run > "$TEST_DIR/out.log" 2>&1 || fail "$name was refused: $(cat "$TEST_DIR/out.log")"
}

refused() {
    local name=$1 want=$2 status=0
    run > "$TEST_DIR/out.log" 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail "$name was accepted: $(cat "$TEST_DIR/out.log")"
    grep -Fq -- "$want" "$TEST_DIR/out.log" ||
        fail "$name: the message does not say '$want': $(cat "$TEST_DIR/out.log")"
    [ ! -e "$TEST_DIR/previous.json" ] || fail "$name left a previous manifest behind"
}

# The first release: nothing at the latest download, and no release of a
# stable version carrying an asset of the release workflow, though a
# candidate and a draft do, and older releases of a stable version carry
# none or another one.
: > "$TEST_DIR/routes"
releases_page 1 first.json \
    "$(release_json 26.10.0-rc1 false true manifest.json)" \
    "$(release_json 26.10.0 true false manifest.json)" \
    "$(release_json 26.9.0 false false "")" \
    "$(release_json 26.8.0 false false notes.txt)"
accepted "the first release"
grep -Fq 'this is the first one, nothing to verify' "$TEST_DIR/out.log" ||
    fail "the first release is not said: $(cat "$TEST_DIR/out.log")"
[ ! -e "$TEST_DIR/previous.json" ] || fail "the first release wrote a previous manifest"
grep -Fqx "/api/repos/${REPOSITORY}/releases?per_page=100&page=1"$'\t'"Bearer test-token" "$TEST_DIR/requests.log" ||
    fail "the releases were not listed with the token: $(cat "$TEST_DIR/requests.log")"
echo "PASS: the first release builds on nothing, whatever candidates, drafts and releases without a manifest exist"

# The latest release carries a manifest, reached through the redirect
# GitHub answers releases/latest/download with.
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.0 26.11.0
route /download/manifest.json 302 - /assets/manifest.json
route /assets/manifest.json 200 "$TEST_DIR/files/manifest.json"
route /download/manifest.json.sig 200 "$TEST_DIR/files/manifest.json.sig"
releases_page 1 stack.json \
    "$(release_json 26.11.0 false false manifest.json)" \
    "$(release_json 26.11.1-rc1 false true manifest.json)" \
    "$(release_json 26.10.0 false false manifest.json)"
latest 26.11.0
accepted "the manifest of the latest release"
cmp -s "$TEST_DIR/previous.json" "$TEST_DIR/files/manifest.json" ||
    fail "the verified manifest was not saved as it was downloaded"
PUBKEY="$KEY2,$KEY1" accepted "a manifest signed by the second key kvsctl trusts"
echo "PASS: a signed manifest of the newest stack release is verified and kept"

# A 404 while stack releases exist: the latest release is another one.
: > "$TEST_DIR/routes"
releases_page 1 handmade.json \
    "$(release_json installer-notes false false "")" \
    "$(release_json 26.11.0 false false manifest.json)" \
    "$(release_json 26.10.0 false false manifest.json)"
latest installer-notes
refused "a hand-made latest release" "GitHub marks installer-notes (https://github.com/${REPOSITORY}/releases/tag/installer-notes) as the latest one"
grep -Fq 'Mark 26.11.0 as the latest release again' "$TEST_DIR/out.log" ||
    fail "the newest stack release is not named: $(cat "$TEST_DIR/out.log")"
: > "$TEST_DIR/routes"
releases_page 1 nolatest.json "$(release_json 26.10.0 false false manifest.json)"
refused "no latest release at all" "GitHub marks no release as the latest one"

# The stack release can sit on any page of the list.
: > "$TEST_DIR/routes"
releases_page 1 page1.json "${filler[@]}"
releases_page 2 page2.json "$(release_json 26.10.0 false false manifest.json)"
latest installer-notes
refused "a stack release on the second page" "but 26.10.0 is a stack release"

# Without the list, a 404 proves nothing.
: > "$TEST_DIR/routes"
route "${RELEASES}?per_page=100&page=1" 500
refused "a list GitHub did not send" "returned HTTP 500"
# Nor with a list cut short, or that is not one JSON array: read as a short
# page, it would end the list early, and a page that never arrived must not
# leave the page before it to be read again and again.
: > "$TEST_DIR/routes"
route "${RELEASES}?per_page=100&page=1" 200 "$(file cut1.json "[$(release_json 26.10.0 false false manifest.json)]")" - cut
refused "a list cut short" "listing the releases of ${REPOSITORY} returned HTTP 200, incomplete: curl exit"
: > "$TEST_DIR/routes"
releases_page 1 page1.json "${filler[@]}"
route "${RELEASES}?per_page=100&page=2" 200 "$(file cut2.json "[$(release_json 26.10.0 false false manifest.json)]")" - cut
refused "a second page cut short" "listing the releases of ${REPOSITORY} returned HTTP 200, incomplete: curl exit"
[ "$(grep -cF "${RELEASES}?per_page=100&page=" "$TEST_DIR/requests.log")" -eq 2 ] ||
    fail "the list was read past the page cut short: $(cut -f1 "$TEST_DIR/requests.log" | sort | uniq -c | head -n 3)"
: > "$TEST_DIR/routes"
route "${RELEASES}?per_page=100&page=1" 200 "$TEST_DIR/files/odd.json"
for body in '' '{}' 'null' '[] []' '[' '{"message":"Not a list"}'; do
    file odd.json "$body" > /dev/null
    refused "a list reading '$body'" "page 1 of the releases of ${REPOSITORY} is not a list of releases"
done
: > "$TEST_DIR/routes"
releases_page 1 strings.json '"installer-notes"'
refused "a list of something else than releases" "the list of the releases of ${REPOSITORY} is not what GitHub sends"
: > "$TEST_DIR/routes"
releases_page 1 page1.json "${filler[@]}"
route "${RELEASES}?per_page=100&page=2" 200 "$(file object.json '{}')"
refused "a second page that is an object" "page 2 of the releases of ${REPOSITORY} is not a list of releases"
: > "$TEST_DIR/routes"
releases_page 1 empty.json
status=0
env -u GH_TOKEN -u GITHUB_TOKEN GITHUB_REPOSITORY="$REPOSITORY" GITHUB_API_URL="$STUB/api" \
    NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 PATH="$TEST_DIR/bin:$PATH" \
    "$SCRIPT" "$STUB/download" "$TEST_DIR/previous.json" > "$TEST_DIR/out.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "a run without a token took the 404 for a first release"
grep -Fq 'GH_TOKEN' "$TEST_DIR/out.log" || fail "the missing token is not named: $(cat "$TEST_DIR/out.log")"
echo "PASS: a 404 is the first release only when GitHub lists no stack release"

# The latest release is an older stack release: its manifest is signed but
# lacks the newer ones.
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.0
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json"
route /download/manifest.json.sig 200 "$TEST_DIR/files/manifest.json.sig"
releases_page 1 older.json \
    "$(release_json 26.11.0 false false manifest.json)" \
    "$(release_json 26.10.0 false false manifest.json)"
latest 26.10.0
refused "an older stack release marked latest" "does not list 26.11.0, the newest stack release"
grep -Fq 'GitHub marks 26.10.0 (' "$TEST_DIR/out.log" ||
    fail "the release marked latest is not named: $(cat "$TEST_DIR/out.log")"
# A stable release flipped to pre-release by hand still counts by its tag.
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.0
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json"
route /download/manifest.json.sig 200 "$TEST_DIR/files/manifest.json.sig"
releases_page 1 flipped.json \
    "$(release_json 26.11.0 false true manifest.json)" \
    "$(release_json 26.10.0 false false manifest.json)"
latest 26.10.0
refused "a stack release flipped to pre-release" "does not list 26.11.0, the newest stack release"
grep -Fq '26.11.0 is flagged as a pre-release, which GitHub never marks as the latest one: clear that flag, mark 26.11.0 as the latest release again' "$TEST_DIR/out.log" ||
    fail "the pre-release flag to clear first is not named: $(cat "$TEST_DIR/out.log")"
# Newest as a version: 26.10.0 comes after 26.9.0, though not as text.
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.9.0
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json"
route /download/manifest.json.sig 200 "$TEST_DIR/files/manifest.json.sig"
releases_page 1 numbers.json \
    "$(release_json 26.10.0 false false manifest.json)" \
    "$(release_json 26.9.0 false false manifest.json)"
latest 26.9.0
refused "26.9.0 marked latest after 26.10.0" "does not list 26.10.0, the newest stack release"
# And down to the patch: 26.10.10 comes after 26.10.9.
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.9
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json"
route /download/manifest.json.sig 200 "$TEST_DIR/files/manifest.json.sig"
releases_page 1 patches.json \
    "$(release_json 26.10.10 false false manifest.json)" \
    "$(release_json 26.10.9 false false manifest.json)"
latest 26.10.9
refused "26.10.9 marked latest after 26.10.10" "does not list 26.10.10, the newest stack release"
# A manifest at the latest download while no release of a stable version
# carries one: the latest release is not a stack release, whatever it holds.
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.0
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json"
route /download/manifest.json.sig 200 "$TEST_DIR/files/manifest.json.sig"
releases_page 1 copied.json "$(release_json v26.10.0 false false manifest.json)"
latest v26.10.0
refused "a manifest on a release of no stable version" "no stable release carries a manifest.json"
grep -Fq 'GitHub marks v26.10.0 (' "$TEST_DIR/out.log" ||
    fail "the release marked latest is not named: $(cat "$TEST_DIR/out.log")"
echo "PASS: a manifest that misses the newest stack release is refused"

# The newest stack release lost its manifest.json, deleted by hand: it is
# still a stack release by its other assets. Neither the 404 it now answers,
# nor the manifest of the release before it once that one is marked latest,
# nor a 404 when it was the only stack release, may be built on.
: > "$TEST_DIR/routes"
releases_page 1 lost.json \
    "$(release_json 26.11.0 false false "${LOST_ASSETS[@]}")" \
    "$(release_json 26.10.0 false false manifest.json manifest.json.sig kvs-stack-26.10.0.tar.gz)"
latest 26.11.0
refused "a newest stack release without its manifest" "26.11.0, the newest stack release, carries no manifest.json any more"
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.0
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json"
route /download/manifest.json.sig 200 "$TEST_DIR/files/manifest.json.sig"
releases_page 1 lost.json \
    "$(release_json 26.11.0 false false "${LOST_ASSETS[@]}")" \
    "$(release_json 26.10.0 false false manifest.json manifest.json.sig kvs-stack-26.10.0.tar.gz)"
latest 26.10.0
refused "the release before it marked latest" "26.11.0, the newest stack release, carries no manifest.json any more"
: > "$TEST_DIR/routes"
route "${RELEASES}?per_page=100&page=1" 200 "$TEST_DIR/files/onlylost.json"
latest 26.10.0
for asset in manifest.json.sig kvs-stack-26.10.0.tar.gz kvsctl-linux-amd64; do
    file onlylost.json "[$(release_json 26.10.0 false false "$asset")]" > /dev/null
    refused "the only stack release, left with $asset" "26.10.0, the newest stack release, carries no manifest.json any more"
done
echo "PASS: a stack release that lost its manifest stops the release"

# The download itself.
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.0
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json"
route /download/manifest.json.sig 200 "$(file bad.sig "signed 0000 by $KEY1")"
releases_page 1 one.json "$(release_json 26.10.0 false false manifest.json)"
refused "a signature that does not match" "the previous manifest does not verify"
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.0
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json"
route /download/manifest.json.sig 200 "$TEST_DIR/files/manifest.json.sig"
releases_page 1 one.json "$(release_json 26.10.0 false false manifest.json)"
PUBKEY=$KEY2 refused "a manifest signed by a key kvsctl does not trust" "the previous manifest does not verify"
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.0
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json" - cut
route /download/manifest.json.sig 200 "$TEST_DIR/files/manifest.json.sig"
releases_page 1 one.json "$(release_json 26.10.0 false false manifest.json)"
refused "a manifest cut short" "downloading $STUB/download/manifest.json returned HTTP 200, incomplete: curl exit"
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.0
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json"
route /download/manifest.json.sig 200 "$TEST_DIR/files/manifest.json.sig" - cut
releases_page 1 one.json "$(release_json 26.10.0 false false manifest.json)"
refused "a signature cut short" "has a manifest but no signature (HTTP 200, incomplete: curl exit"
: > "$TEST_DIR/routes"
manifest "$KEY1" 26.10.0
route /download/manifest.json 200 "$TEST_DIR/files/manifest.json"
releases_page 1 one.json "$(release_json 26.10.0 false false manifest.json)"
refused "a manifest without its signature" "has a manifest but no signature (HTTP 404)"
for code in 403 500 502; do
    : > "$TEST_DIR/routes"
    route /download/manifest.json "$code"
    releases_page 1 empty.json
    refused "a download answered $code" "returned HTTP ${code}"
done
: > "$TEST_DIR/routes"
releases_page 1 empty.json
BASE_URL=http://127.0.0.1:1/download refused "a download that got no answer" "returned HTTP 000"
if grep -Fq '000000' "$TEST_DIR/out.log"; then
    fail "the status of a download without an answer is doubled: $(cat "$TEST_DIR/out.log")"
fi
echo "PASS: a download that fails, or a manifest that does not verify, stops the release"
