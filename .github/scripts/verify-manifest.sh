#!/usr/bin/env bash
#
# Download the manifest of the previous release and prove it verifies with
# the key the published kvsctl binaries trust, before extending it.
#
#   verify-manifest.sh <base-url> <output-file>
#
# <base-url> is usually
# https://github.com/<owner>/<repo>/releases/latest/download
#
# A first release has no previous manifest: the download 404s, the script
# says so and exits 0 without writing the output file, and the caller passes
# no --previous. Anything else is fatal. A manifest that does not verify
# means the key, the signature or the release assets are not what this
# repository believes they are, and the release must stop rather than sign a
# list built on top of something unverified.
#
# The public keys come from KVSCTL_RELEASE_PUBKEY (comma separated base64)
# or, by default, from the constants compiled into kvsctl, which is what
# every installed binary actually checks against.

set -euo pipefail

die() {
    printf 'verify-manifest: %s\n' "$*" >&2
    exit 1
}

[ $# -eq 2 ] || die "usage: verify-manifest.sh <base-url> <output-file>"

base_url=$1
output=$2
repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

fetch() {
    local url=$1 destination=$2 status

    status=$(curl -sSL -o "$destination" -w '%{http_code}' "$url" || echo 000)
    printf '%s' "$status"
}

manifest_status=$(fetch "${base_url}/manifest.json" "${tmp_dir}/manifest.json")
case "$manifest_status" in
    200) ;;
    404)
        echo "no previous release: nothing to verify"
        exit 0
        ;;
    *) die "downloading ${base_url}/manifest.json returned HTTP ${manifest_status}" ;;
esac

signature_status=$(fetch "${base_url}/manifest.json.sig" "${tmp_dir}/manifest.json.sig")
[ "$signature_status" = "200" ] ||
    die "the previous release has a manifest but no signature (HTTP ${signature_status})"

keys=${KVSCTL_RELEASE_PUBKEY:-}
if [ -z "$keys" ]; then
    # The keys kvsctl trusts are the ones compiled into it, so reading them
    # from the source proves the previous manifest verifies with exactly what
    # the installed binaries hold.
    # ReleasePublicKey is one quoted string: keys as "id=base64" or the key
    # alone, comma separated. The ids are dropped, the tool derives them.
    keys=$(grep -oE 'ReleasePublicKey = "[^"]+"' "${repo_root}/cli/cmd/kvsctl/main.go" |
        sed -E 's/.*"([^"]+)"/\1/' | tr ',' '\n' | sed -E 's/^[^=]*=([A-Za-z0-9+\/]{43}=)$/\1/' |
        grep -E '^[A-Za-z0-9+/]{43}=$' | paste -sd, -)
fi
[ -n "$keys" ] || die "no release public key found"

pub_args=()
IFS=',' read -r -a key_list <<<"$keys"
for key in "${key_list[@]}"; do
    [ -n "$key" ] || continue
    pub_args+=(--pub "$key")
done
[ ${#pub_args[@]} -gt 0 ] || die "no release public key found"

(
    cd "${repo_root}/cli"
    go run ./cmd/kvsctl-release verify \
        --manifest "${tmp_dir}/manifest.json" \
        --signature "${tmp_dir}/manifest.json.sig" \
        "${pub_args[@]}"
) || die "the previous manifest does not verify; refusing to build on it"

cp -- "${tmp_dir}/manifest.json" "$output"
echo "previous manifest verified and saved as ${output}"
