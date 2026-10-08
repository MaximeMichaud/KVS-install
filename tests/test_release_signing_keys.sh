#!/bin/bash
# .github/scripts/release-signing-keys.sh runs in the keys job of the release
# workflow, in the release environment, before the images job pushes
# anything. Each signing secret has to be a key kvsctl-release signs with,
# read from the bytes the publish job writes, its public half a key of
# ReleasePublicKey, and an announced key one of the signing keys: otherwise
# the publish job refuses the manifest once every image is pushed, and the
# version is spent. ReleasePublicKey may not list the key kvsctl was
# developed with at all. The keys never reach the output.
#
# "go run ./cmd/kvsctl-release pubkey" is a stand-in here that knows the
# keys of the test by the sha256 of their exact bytes, and refuses anything
# else as kvsctl-release refuses a file that is not PEM. How kvsctl-release
# reads a key is TestPubkeyReadsAKeyAsTheManifestCommandDoes.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/.github/scripts/release-signing-keys.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-release-signing-keys.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || fail "openssl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

# The key kvsctl was developed with, and its id.
DEV_KEY=KZYznVR68TMpw0wm0G3ASwQkJ6xyj0pQAO7oR4RStjs= # pragma: allowlist secret
DEV_ID=c23d8b96

export KEYS_TABLE="$TEST_DIR/keys.table"
: > "$KEYS_TABLE"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/go" <<'EOF'
#!/bin/bash
[ $# -eq 5 ] && [ "$1 $2 $3 $4" = "run ./cmd/kvsctl-release pubkey --key" ] || { echo "unexpected go call: $*" >&2; exit 2; }
[ "$(basename "$PWD")" = cli ] || { echo "go ran in $PWD, not in cli/" >&2; exit 2; }
cp -- "$5" "$(dirname "$KEYS_TABLE")/received"
sum=$(sha256sum < "$5" | cut -d' ' -f1)
answer=$(sed -n "s/^${sum} //p" "$KEYS_TABLE")
case "$answer" in
    '' | refused:*)
        reason=${answer#refused:}
        echo "kvsctl-release: $5: ${reason:-release key is not PEM}" >&2
        echo "exit status 1" >&2
        exit 1
        ;;
esac
printf '%s\n' "$answer"
EOF
chmod +x "$TEST_DIR/bin/go"
export PATH="$TEST_DIR/bin:$PATH"

# known <name> <answer>: the stand-in answers this for the key file <name>,
# as a secret holds it: without its last line feed, which $(...) drops.
known() {
    printf '%s %s\n' "$(printf '%s' "$(pem "$1")" | sha256sum | cut -d' ' -f1)" "$2" >> "$KEYS_TABLE"
}

# newkey <name>: an Ed25519 key as kvsctl-release keygen writes it, PKCS8
# PEM, with its public half in base64 and its id. Both are read from the
# text form of the key, not the way the script reads them.
newkey() {
    local hex
    openssl genpkey -algorithm ed25519 -out "$TEST_DIR/$1.pem" 2>/dev/null
    hex=$(openssl pkey -in "$TEST_DIR/$1.pem" -text -noout | sed -n '/^pub:/,$p' | tail -n +2 | tr -d ' :\n')
    python3 -c '
import base64, hashlib, sys
raw = bytes.fromhex(sys.argv[1])
assert len(raw) == 32
print(base64.b64encode(raw).decode(), hashlib.sha256(raw).hexdigest()[:8])
' "$hex" > "$TEST_DIR/$1.pub"
    known "$1" "$(pub "$1")"
}
pub() { cut -d' ' -f1 "$TEST_DIR/$1.pub"; }
id() { cut -d' ' -f2 "$TEST_DIR/$1.pub"; }
pem() { cat "$TEST_DIR/$1.pem"; }

for key in current next other; do
    newkey "$key"
done

# trusts <name> <ReleasePublicKey value>: a main.go declaring those keys.
trusts() {
    printf 'package main\n\nvar ReleasePublicKey = "%s" // pragma: allowlist secret\n' "$2" > "$TEST_DIR/$1.go"
    printf '%s' "$TEST_DIR/$1.go"
}

# env_file <name> [ANNOUNCE_KEY value]
env_file() {
    printf 'NOTES="A line"\nANNOUNCE_KEY=%s\n' "${2:-}" > "$TEST_DIR/$1.env"
    printf '%s' "$TEST_DIR/$1.env"
}

# run <key> <next key> <release.env> <main.go>, the keys given by name, or
# empty for a secret that is not set.
run() {
    local key=$1 next=$2
    local -a secrets=()
    shift 2
    [ -z "$key" ] || secrets+=("KVSCTL_RELEASE_KEY=$(pem "$key")")
    [ -z "$next" ] || secrets+=("KVSCTL_RELEASE_KEY_NEXT=$(pem "$next")")
    env -u KVSCTL_RELEASE_KEY -u KVSCTL_RELEASE_KEY_NEXT "${secrets[@]}" "$SCRIPT" "$@" > "$TEST_DIR/out.log" 2>&1
}

accepted() {
    local name=$1
    shift
    run "$@" || fail "$name was refused: $(cat "$TEST_DIR/out.log")"
    if grep -Fq -e 'PRIVATE KEY' -e "$(sed -n 2p "$TEST_DIR/current.pem")" -e "$(sed -n 2p "$TEST_DIR/next.pem")" "$TEST_DIR/out.log"; then
        fail "$name: the output shows a private key: $(cat "$TEST_DIR/out.log")"
    fi
}

refused() {
    local name=$1 want=$2 status=0
    shift 2
    run "$@" || status=$?
    [ "$status" -ne 0 ] || fail "$name was accepted: $(cat "$TEST_DIR/out.log")"
    grep -Fq -- "$want" "$TEST_DIR/out.log" ||
        fail "$name: the message does not say '$want': $(cat "$TEST_DIR/out.log")"
}

shows() {
    grep -Fqx -- "$1" "$TEST_DIR/out.log" || fail "the output does not say '$1': $(cat "$TEST_DIR/out.log")"
}

one=$(trusts one "$(pub current)")
accepted "the key kvsctl trusts" current "" "$(env_file plain)" "$one"
shows "KVSCTL_RELEASE_KEY:      $(id current), trusted by the kvsctl of this commit"
both=$(trusts both "$(pub current), $(id next)=$(pub next)")
accepted "a rotation" current next "$(env_file announce "$(id next)=$(pub next)@2026-12-01")" "$both"
shows "KVSCTL_RELEASE_KEY_NEXT: $(id next), trusted by the kvsctl of this commit"
shows "announced key:           $(id next), signs this release"
accepted "the switch" next "" "$(env_file switch)" "$(trusts switch "$(id next)=$(pub next)")"
echo "PASS: signing keys kvsctl trusts are accepted, without showing them"

# kvsctl-release gets the secret as the publish job writes it, byte for
# byte: a CRLF key that lost its last line feed ends in a carriage return,
# which kvsctl-release refuses there, and so has to refuse here.
awk '{ printf "%s\r\n", $0 }' "$TEST_DIR/current.pem" > "$TEST_DIR/crlf.pem"
known crlf "refused:release key is not PEM"
refused "a CRLF key without its last line feed" \
    "KVSCTL_RELEASE_KEY is not a key kvsctl-release can sign with (release key is not PEM)" crlf "" "$(env_file crlf)" "$one"
printf '%s' "$(pem crlf)" | cmp -s - "$TEST_DIR/received" ||
    fail "kvsctl-release must read the secret byte for byte, as the publish job writes it"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TEST_DIR/ec.pem" 2>/dev/null
known ec "refused:release key is not Ed25519"
refused "a key of another algorithm" \
    "KVSCTL_RELEASE_KEY is not a key kvsctl-release can sign with (release key is not Ed25519)" ec "" "$(env_file ec)" "$one"
printf 'not a key\n' > "$TEST_DIR/garbage.pem"
refused "a secret that is no key" "KVSCTL_RELEASE_KEY is not a key kvsctl-release can sign with (release key is not PEM)" \
    garbage "" "$(env_file garbage)" "$one"
refused "a next key kvsctl-release cannot read" "KVSCTL_RELEASE_KEY_NEXT is not a key kvsctl-release can sign with" \
    current garbage "$(env_file next-garbage)" "$one"
if grep -Fq -e 'key.pem' -e 'exit status' "$TEST_DIR/out.log"; then
    fail "the refusal must give the reason of kvsctl-release alone: $(cat "$TEST_DIR/out.log")"
fi

refused "no signing secret" "has no KVSCTL_RELEASE_KEY secret" "" "" "$(env_file none)" "$one"
refused "a key kvsctl does not trust" "KVSCTL_RELEASE_KEY is the key $(id other), which ReleasePublicKey in $one does not list" \
    other "" "$(env_file untrusted)" "$one"
grep -Fq "(it lists $(id current))" "$TEST_DIR/out.log" || fail "the refusal must name the keys kvsctl trusts: $(cat "$TEST_DIR/out.log")"
refused "a next key kvsctl does not trust" "KVSCTL_RELEASE_KEY_NEXT is the key $(id next), which ReleasePublicKey" \
    current next "$(env_file next-untrusted)" "$one"
refused "an announced key no secret holds" "announces the key $(id next), and no signing secret is that key" \
    current "" "$(env_file announce-alone "$(id next)=$(pub next)")" "$both"
refused "the same key twice" "which KVSCTL_RELEASE_KEY already is" current current "$(env_file twice)" "$one"
refused "a missing release.env" "does not exist" current "" "$TEST_DIR/missing.env" "$one"
refused "a ReleasePublicKey that lists no key" "lists no key" \
    current "" "$(env_file unreadable)" "$(trusts unreadable "")"
echo "PASS: a signing key kvsctl would refuse stops the release before the images are pushed"

# The key kvsctl was developed with stops every release while
# ReleasePublicKey lists it, next to the release key or not, whatever the
# secrets hold, and before they are read.
refused "the development key" "ReleasePublicKey in $TEST_DIR/dev.go lists ${DEV_ID}, the key kvsctl was developed with" \
    current "" "$(env_file dev)" "$(trusts dev "$DEV_KEY")"
refused "the development key next to the release key" "lists ${DEV_ID}, the key kvsctl was developed with" \
    current "" "$(env_file dev-next)" "$(trusts dev-next "$(pub current),r0=$DEV_KEY")"
refused "the development key and no secret" "lists ${DEV_ID}, the key kvsctl was developed with" \
    "" "" "$(env_file dev-none)" "$(trusts dev-none "$DEV_KEY")"

# Run as the workflow runs it, the script names the files of its checkout
# as the repository does, the way docs/releasing.md quotes it.
checkout="$TEST_DIR/checkout"
mkdir -p "$checkout/.github/scripts" "$checkout/cli/cmd/kvsctl"
cp "$SCRIPT" "$ROOT_DIR/.github/scripts/release-public-keys.sh" "$checkout/.github/scripts/"
cp "$TEST_DIR/dev.go" "$checkout/cli/cmd/kvsctl/main.go"
printf 'NOTES="A line"\nANNOUNCE_KEY=\n' > "$checkout/.github/release.env"
status=0
env -u KVSCTL_RELEASE_KEY -u KVSCTL_RELEASE_KEY_NEXT "$checkout/.github/scripts/release-signing-keys.sh" > "$TEST_DIR/out.log" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "the development key was accepted from the main.go of the checkout"
grep -Fq "ReleasePublicKey in cli/cmd/kvsctl/main.go lists ${DEV_ID}, the key kvsctl was developed with" "$TEST_DIR/out.log" ||
    fail "the refusal must name cli/cmd/kvsctl/main.go as the repository does: $(cat "$TEST_DIR/out.log")"
echo "PASS: no release goes out while kvsctl trusts the key it was developed with"
