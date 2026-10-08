#!/bin/bash
# .github/scripts/release-public-keys.sh reads the keys kvsctl is compiled
# with, the ReleasePublicKey string of cli/cmd/kvsctl/main.go, for the two
# checks of the release workflow: the previous manifest before it is
# extended, and the new one before it is published. A declaration it cannot
# read, or an entry that is not a key, is an error: dropping it would check a
# manifest against fewer keys than the binary holds.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/.github/scripts/release-public-keys.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-release-keys.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# 32 bytes of zeros and of ones, in base64: the shape of an Ed25519 key.
KEY1=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
KEY2=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=

source_file() {
    printf 'package main\n\n// ReleasePublicKey lists the keys.\n%s\n' "$2" > "$TEST_DIR/$1.go"
    printf '%s' "$TEST_DIR/$1.go"
}

prints() {
    local name=$1 file=$2 want=$3 got
    got=$("$SCRIPT" "$file" 2>&1) || fail "$name was refused: $got"
    [ "$got" = "$want" ] || fail "$name printed '$got', expected '$want'"
}

refused() {
    local name=$1 file=$2 want=$3 status=0
    "$SCRIPT" "$file" > "$TEST_DIR/out.log" 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail "$name was accepted"
    grep -Fq "$want" "$TEST_DIR/out.log" ||
        fail "$name: the message does not say '$want': $(cat "$TEST_DIR/out.log")"
}

prints "one key" "$(source_file one "var ReleasePublicKey = \"$KEY1\" // pragma: allowlist secret")" "$KEY1"
prints "keys with their ids" "$(source_file ids "var ReleasePublicKey = \"r1=$KEY1,r2=$KEY2\"")" "$KEY1,$KEY2"
prints "a typed declaration in a var block" \
    "$(source_file block "var (
	ReleasePublicKey string = \"$KEY1, 72cd6e84=$KEY2\"
)")" "$KEY1,$KEY2"
prints "a constant" "$(source_file constant "const ReleasePublicKey = \"$KEY2\"")" "$KEY2"

keys=$("$SCRIPT") || fail "the keys of cli/cmd/kvsctl/main.go could not be read"
[[ "$keys" =~ ^[A-Za-z0-9+/]{43}=(,[A-Za-z0-9+/]{43}=)*$ ]] ||
    fail "the keys of cli/cmd/kvsctl/main.go read as '$keys'"
echo "PASS: the release public keys are read from the kvsctl source"

refused "two declarations" "$(source_file twice "var ReleasePublicKey = \"$KEY1\"
var ReleasePublicKey = \"$KEY2\"")" "found 2"
refused "no declaration" "$(source_file none "var Other = \"$KEY1\"")" "found 0"
refused "a value that is no string literal" "$(source_file call "var ReleasePublicKey = strings.Join(keys, \",\")")" "found 0"
refused "an entry that is no key" "$(source_file broken "var ReleasePublicKey = \"$KEY1,notakey\"")" "'notakey'"
refused "a key cut short" "$(source_file short "var ReleasePublicKey = \"${KEY1#A}\"")" "is not an Ed25519 public key"
refused "an empty list" "$(source_file empty "var ReleasePublicKey = \"\"")" "lists no key"
refused "a missing file" "$TEST_DIR/missing.go" "does not exist"
echo "PASS: a declaration that cannot be read stops the release instead of dropping keys"
