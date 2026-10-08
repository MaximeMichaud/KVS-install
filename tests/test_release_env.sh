#!/bin/bash
# .github/scripts/release-env.sh checks .github/release.env in the prepare job
# of the release workflow, before the images job pushes anything: a release
# without its line of notes, or a value of the file kvsctl-release would
# refuse when it signs the manifest, whatever manifest it extends, stops the
# run there with a message naming the knob. MIN_FROM against the manifest of
# the latest release is test_release_previous.sh, ANNOUNCE_KEY against the
# signing keys test_release_signing_keys.sh.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/.github/scripts/release-env.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-release-env.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# 32 zero bytes stand for a public key; 66687aad is the first eight
# hexadecimal characters of their sha256, the id kvsctl gives that key.
KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
KEY_ID=66687aad

cat > "$TEST_DIR/base.env" <<'EOF'
NOTES="Manticore replaces the internal search"
MIN_FROM=
DATABASE=none
ONE_WAY=false
KVS_MIN=7.0.0
COMPOSE_MIN=2.19.0
ANNOUNCE_KEY=
EOF

# The base file with lines appended: a later assignment wins when the file
# is read, as it would in the publish job.
variant() {
    local name=$1
    shift
    { cat "$TEST_DIR/base.env"; printf '%s\n' "$@"; } > "$TEST_DIR/$name.env"
    printf '%s' "$TEST_DIR/$name.env"
}

accepted() {
    local name=$1 version=$2 file=$3
    "$SCRIPT" "$version" "$file" > "$TEST_DIR/out.log" 2>&1 ||
        fail "$name was refused: $(cat "$TEST_DIR/out.log")"
}

refused() {
    local name=$1 version=$2 file=$3 want=$4 status=0
    "$SCRIPT" "$version" "$file" > "$TEST_DIR/out.log" 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail "$name was accepted"
    grep -Fq "$want" "$TEST_DIR/out.log" ||
        fail "$name: the message does not say '$want': $(cat "$TEST_DIR/out.log")"
}

accepted "a complete file" 26.11.0 "$TEST_DIR/base.env"
grep -Fqx 'notes:        Manticore replaces the internal search' "$TEST_DIR/out.log" ||
    fail "the log does not show the notes: $(cat "$TEST_DIR/out.log")"
accepted "a required stop" 26.11.0 "$(variant stop MIN_FROM=26.10.3)"
accepted "a required stop before a candidate" 26.11.0-rc1 "$(variant stop-rc MIN_FROM=26.10.3)"
accepted "a release that migrates one way" 26.11.0 "$(variant one-way DATABASE=migrates ONE_WAY=true)"
accepted "an announced key" 26.11.0 "$(variant announce "ANNOUNCE_KEY=${KEY_ID}=${KEY}")"
accepted "an announced key with its day" 26.11.0 "$(variant announce-day "ANNOUNCE_KEY=${KEY_ID}=${KEY}@2026-12-01")"
accepted "an announced key from a leap day" 26.11.0 "$(variant announce-leap "ANNOUNCE_KEY=${KEY_ID}=${KEY}@2028-02-29")"
accepted "no minimum" 26.11.0 "$(variant no-minimum KVS_MIN= COMPOSE_MIN=)"
accepted "zeros and two digit numbers" 26.11.0 "$(variant zeros KVS_MIN=0.0.10 COMPOSE_MIN=2.40.0 MIN_FROM=26.10.10)"
# 18 digits, which kvsctl always holds, as release-version.sh allows them.
accepted "the largest number kvsctl holds" 26.11.0 "$(variant largest KVS_MIN=999999999999999999.0.0)"
accepted "highlights" 26.11.0 "$(variant highlights 'HIGHLIGHT_1="Manticore is the default search"' 'HIGHLIGHT_3="PHP 8.4 images"')"
for line in 'highlight:    Manticore is the default search' 'highlight:    PHP 8.4 images'; do
    grep -Fqx "$line" "$TEST_DIR/out.log" || fail "the log does not show '$line': $(cat "$TEST_DIR/out.log")"
done
accepted "an older kvsctl minimum" 26.11.0 "$(variant kvsctl-older KVSCTL_MIN=26.10.2)"
accepted "the kvsctl of the release" 26.11.0 "$(variant kvsctl-same KVSCTL_MIN=26.11.0)"
grep -Fqx 'kvsctl min:   26.11.0' "$TEST_DIR/out.log" || fail "the log does not show the kvsctl minimum: $(cat "$TEST_DIR/out.log")"
accepted "the release a candidate leads to" 26.11.0-rc1 "$(variant kvsctl-candidate KVSCTL_MIN=26.11.0)"
# The file the repository ships, once its NOTES line is written.
{ cat "$ROOT_DIR/.github/release.env"; printf 'NOTES="A line of notes"\n'; } > "$TEST_DIR/shipped.env"
accepted "the shipped release.env" 26.11.0 "$TEST_DIR/shipped.env"
echo "PASS: a complete release.env is accepted"

refused "empty notes" 26.11.0 "$(variant no-notes 'NOTES=""')" "NOTES is empty"
refused "notes over two lines" 26.11.0 "$(variant two-lines 'NOTES="one' 'two"')" "more than one line"
refused "an unknown database value" 26.11.0 "$(variant database DATABASE=migrate)" "none or migrates"
refused "no database value" 26.11.0 "$(variant no-database DATABASE=)" "none or migrates"
refused "a one-way flag that is no boolean" 26.11.0 "$(variant one-way-word ONE_WAY=yes)" "true or false"
refused "a KVS minimum that is no version" 26.11.0 "$(variant kvs-min KVS_MIN=7.0)" "KVS_MIN"
refused "a Compose minimum that is no version" 26.11.0 "$(variant compose-min COMPOSE_MIN=v2.24.0)" "COMPOSE_MIN"
refused "a kvsctl minimum that is no version" 26.11.0 "$(variant kvsctl-short KVSCTL_MIN=26.11)" "KVSCTL_MIN in"
refused "a kvsctl minimum after the release" 26.11.0 "$(variant kvsctl-newer KVSCTL_MIN=26.11.1)" "newer than the release 26.11.0"
refused "a kvsctl minimum after what a candidate leads to" 26.11.0-rc1 "$(variant kvsctl-newer-rc KVSCTL_MIN=26.12.0)" "newer than the release 26.11.0-rc1"
refused "a highlight over two lines" 26.11.0 "$(variant highlight-lines 'HIGHLIGHT_2="one' 'two"')" "HIGHLIGHT_2 in"
# A carriage return sends the terminal back to the start of the line, and
# what follows it overwrites the highlight; a release.env saved with CRLF
# line ends puts one at the end of every value.
refused "a highlight with a carriage return" 26.11.0 "$(variant highlight-cr "HIGHLIGHT_2=\"one$(printf '\r')two\"")" "HIGHLIGHT_2 in"
refused "a highlight saved with a CRLF line end" 26.11.0 "$(variant highlight-crlf "HIGHLIGHT_1=\"one\"$(printf '\r')")" "HIGHLIGHT_1 in"
refused "a blank highlight" 26.11.0 "$(variant highlight-blank 'HIGHLIGHT_1="   "')" "HIGHLIGHT_1 in"
# kvsctl-release trims a highlight the way Go does, so a line of Unicode
# white space, such as a no-break, figure or ideographic space, is as blank
# as a line of spaces, whatever the locale the check runs in. A no-break
# space between two words is text.
unicode_blanks=$(printf '\xc2\xa0\xe2\x80\x87\xe3\x80\x80\xc2\x85')
refused "a highlight of Unicode white space" 26.11.0 "$(variant highlight-unicode "HIGHLIGHT_3=\"${unicode_blanks} \"")" "HIGHLIGHT_3 in"
accepted "a highlight with a no-break space" 26.11.0 "$(variant highlight-nbsp "HIGHLIGHT_1=\"PHP$(printf '\xc2\xa0')8.4 images\"")"
refused "a stop that is no version" 26.11.0 "$(variant stop-short MIN_FROM=26.10)" "not a release version"
refused "a stop that is the release" 26.11.0 "$(variant stop-same MIN_FROM=26.11.0)" "not older than the release 26.11.0"
refused "a stop after the candidate" 26.11.0-rc1 "$(variant stop-rc-same MIN_FROM=26.11.0)" "not older"
refused "a stop after the release" 26.11.0 "$(variant stop-newer MIN_FROM=26.12.0)" "not older"
refused "an announced key named freely" 26.11.0 "$(variant announce-name "ANNOUNCE_KEY=r2=${KEY}")" "not ID=BASE64"
refused "an announced key under another id" 26.11.0 "$(variant announce-id "ANNOUNCE_KEY=00000000=${KEY}")" "the id of that key is ${KEY_ID}"
refused "an announced key with a bad day" 26.11.0 "$(variant announce-bad-day "ANNOUNCE_KEY=${KEY_ID}=${KEY}@tomorrow")" "not ID=BASE64"
refused "a missing file" 26.11.0 "$TEST_DIR/missing.env" "does not exist"

# kvsctl-release reads every version with its own parser, which refuses a
# leading zero in any number, and the day of an announced key as a date of
# the calendar. Each value below passed the shape checks once, and only the
# publish job refused it, after the images were pushed.
refused "a KVS minimum with a leading zero" 26.11.0 "$(variant kvs-min-zero KVS_MIN=7.00.0)" "KVS_MIN in"
refused "a KVS minimum with a leading zero first" 26.11.0 "$(variant kvs-min-zero-first KVS_MIN=07.0.0)" "KVS_MIN in"
refused "a Compose minimum with a leading zero" 26.11.0 "$(variant compose-min-zero COMPOSE_MIN=2.024.0)" "COMPOSE_MIN in"
refused "a Compose minimum with a leading zero last" 26.11.0 "$(variant compose-min-zero-last COMPOSE_MIN=2.24.00)" "COMPOSE_MIN in"
refused "a stop with a leading zero" 26.11.0 "$(variant stop-zero MIN_FROM=26.09.0)" "MIN_FROM in"
refused "a stop with a leading zero first" 26.11.0 "$(variant stop-zero-first MIN_FROM=026.10.0)" "MIN_FROM in"
refused "a number kvsctl cannot hold" 26.11.0 "$(variant kvs-min-huge KVS_MIN=99999999999999999999.0.0)" "KVS_MIN in"
refused "a number of 19 digits" 26.11.0 "$(variant kvs-min-19 KVS_MIN=1000000000000000000.0.0)" "KVS_MIN in"
refused "a kvsctl minimum with a leading zero" 26.11.0 "$(variant kvsctl-zero KVSCTL_MIN=26.011.0)" "KVSCTL_MIN in"
refused "an announced key from the thirteenth month" 26.11.0 "$(variant announce-month "ANNOUNCE_KEY=${KEY_ID}=${KEY}@2026-13-45")" "not a day of the calendar"
refused "an announced key from the thirtieth of February" 26.11.0 "$(variant announce-feb "ANNOUNCE_KEY=${KEY_ID}=${KEY}@2026-02-30")" "not a day of the calendar"
refused "an announced key from the thirty-first of November" 26.11.0 "$(variant announce-nov "ANNOUNCE_KEY=${KEY_ID}=${KEY}@2026-11-31")" "not a day of the calendar"
refused "an announced key from a leap day of a common year" 26.11.0 "$(variant announce-common "ANNOUNCE_KEY=${KEY_ID}=${KEY}@2027-02-29")" "not a day of the calendar"
refused "an announced key from day zero" 26.11.0 "$(variant announce-zero "ANNOUNCE_KEY=${KEY_ID}=${KEY}@2026-12-00")" "not a day of the calendar"
echo "PASS: a release.env kvsctl-release would refuse stops the release before the images are pushed"

# COMPOSE_MIN is what kvsctl asks of a stack before it installs the release,
# and docker/setup.sh asks the same of an installation kvsctl manages: the
# release override needs it either way.
setup_minimum=$(sed -n '/if \[ -e docker-compose.release.yml \]; then/{n;s/^ *compose_minimum=\([0-9.]*\)$/\1/p;}' \
    "$ROOT_DIR/docker/setup.sh")
shipped_minimum=$(sed -n 's/^COMPOSE_MIN=\([0-9.]*\)$/\1/p' "$ROOT_DIR/.github/release.env")
[ -n "$setup_minimum" ] || fail "the Compose minimum docker/setup.sh asks of an installation kvsctl manages could not be read"
[ "$shipped_minimum" = "$setup_minimum" ] ||
    fail "COMPOSE_MIN of .github/release.env is '$shipped_minimum', and docker/setup.sh asks Compose $setup_minimum of an installation kvsctl manages"
echo "PASS: release.env and setup.sh ask the same Docker Compose of the release override"
