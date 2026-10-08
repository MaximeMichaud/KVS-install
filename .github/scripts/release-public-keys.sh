#!/usr/bin/env bash
#
# Print the release public keys compiled into kvsctl, comma separated, in the
# base64 form kvsctl-release verify takes with --pub.
#
#   release-public-keys.sh [main.go]
#
# The keys come from the ReleasePublicKey string of cli/cmd/kvsctl/main.go,
# which is what every kvsctl built from this checkout verifies a manifest
# with. The string lists keys as "id=base64" or as the base64 alone, comma
# separated; the ids are dropped, since a key id is derived from the key.
#
# A declaration this script cannot read, or an entry that is not an Ed25519
# public key, is an error rather than something to skip: skipping it would
# check a manifest against fewer keys than the binary holds, or none.

set -euo pipefail

die() {
    printf 'release-public-keys: %s\n' "$*" >&2
    exit 1
}

[ $# -le 1 ] || die "usage: release-public-keys.sh [main.go]"

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source_file=${1:-${repo_root}/cli/cmd/kvsctl/main.go}
[ -f "$source_file" ] || die "$source_file does not exist"

# One string literal on one line: var ReleasePublicKey = "...", with an
# optional type, inside a var block or not.
declaration='^[[:space:]]*((var|const)[[:space:]]+)?ReleasePublicKey([[:space:]]+string)?[[:space:]]*=[[:space:]]*"([^"]*)"'
matches=$(grep -cE "$declaration" "$source_file" || true)
[ "$matches" = 1 ] ||
    die "expected one ReleasePublicKey string declaration in $source_file, found ${matches}"
value=$(sed -n -E "s/${declaration}.*/\\4/p" "$source_file")

keys=()
IFS=',' read -r -a entries <<<"$value"
for entry in "${entries[@]}"; do
    entry=${entry//[[:space:]]/}
    [ -n "$entry" ] || continue
    key=$entry
    if [[ "$entry" =~ ^[^=]+=([A-Za-z0-9+/]{43}=)$ ]]; then
        key=${BASH_REMATCH[1]}
    fi
    [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        die "'$entry' in ReleasePublicKey is not an Ed25519 public key in base64, alone or as id=base64"
    keys+=("$key")
done
[ ${#keys[@]} -gt 0 ] || die "ReleasePublicKey in $source_file lists no key"

(
    IFS=,
    printf '%s\n' "${keys[*]}"
)
