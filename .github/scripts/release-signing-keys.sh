#!/usr/bin/env bash
#
# Check the signing keys of the release environment against the keys the
# kvsctl of the tagged commit trusts, before anything is built or pushed.
#
#   release-signing-keys.sh [release.env [main.go]]
#
# The keys come from KVSCTL_RELEASE_KEY, required, and
# KVSCTL_RELEASE_KEY_NEXT, set during a key rotation only: the private keys
# in PEM the publish job of .github/workflows/release.yml signs the manifest
# with. kvsctl-release reads each one here from the bytes the publish job
# writes, with the code the manifest command signs with, so a secret it
# could not sign with stops here. The public half of each has to be a key of
# ReleasePublicKey in cli/cmd/kvsctl/main.go, read by
# release-public-keys.sh, or every kvsctl built from this commit would
# refuse the manifest. The publish job checks the signed manifest against
# those keys too, but only once the images job has pushed every image under
# the version tag, and the version is then spent. An ANNOUNCE_KEY in
# release.env has to be one of the signing keys as well, which
# kvsctl-release refuses otherwise (docs/releasing.md, Rotating the signing
# key). And ReleasePublicKey may not list the key kvsctl was developed with,
# whatever the secrets hold.
#
# The keys themselves never reach the output: each is named by its id, the
# first eight hexadecimal characters of the sha256 of its public half, as
# kvsctl-release keygen prints it.

set -euo pipefail

die() {
    printf 'release-signing-keys: %s\n' "$*" >&2
    exit 1
}

[ $# -le 2 ] || die "usage: release-signing-keys.sh [release.env [main.go]]"

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
file=${1:-${repo_root}/.github/release.env}
source_file=${2:-${repo_root}/cli/cmd/kvsctl/main.go}
# The messages name the files of the checkout as the repository does, and a
# file given as an argument as it was given.
shown_file=${1:-.github/release.env}
shown_source=${2:-cli/cmd/kvsctl/main.go}
[ -f "$file" ] || die "$file does not exist"
command -v openssl >/dev/null 2>&1 || die "openssl is required to name the keys"

ANNOUNCE_KEY=''
# shellcheck source=/dev/null
. "$file"

trusted=$("${repo_root}/.github/scripts/release-public-keys.sh" "$source_file")

key_id() {
    printf '%s' "$1" | openssl base64 -d -A | sha256sum | cut -c1-8
}

trusted_ids() {
    local key ids=()
    local -a keys
    IFS=',' read -r -a keys <<<"$trusted"
    for key in "${keys[@]}"; do
        ids+=("$(key_id "$key")")
    done
    (
        IFS=,
        printf '%s' "${ids[*]}"
    )
}

# The key kvsctl was developed and tested with, before the project had a
# release key. Its private half is kept on test machines, not the way a
# release key is, so a kvsctl that trusted it would take a manifest from
# anyone holding a copy. It is refused before the secrets are read: no
# secret makes such a release safe.
development_key=KZYznVR68TMpw0wm0G3ASwQkJ6xyj0pQAO7oR4RStjs= # pragma: allowlist secret
case ",${trusted}," in
    *",${development_key},"*)
        die "ReleasePublicKey in ${shown_source} lists $(key_id "$development_key"), the key kvsctl was developed with, and no release may trust it: put the public half of the release key there in its place, in a commit before the tag (docs/releasing.md, one-time setup)" ;;
esac

[ -n "${KVSCTL_RELEASE_KEY:-}" ] ||
    die "the release environment has no KVSCTL_RELEASE_KEY secret (docs/releasing.md, one-time setup)"
command -v go >/dev/null 2>&1 || die "go is required: kvsctl-release reads the keys"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

# public_half <secret name>: the base64 public half of the private key the
# secret holds, as kvsctl-release pubkey prints it. The secret is written
# the way the publish job writes it for the manifest command, byte for byte,
# and read with the code of that command.
public_half() {
    local name=$1 key reason

    (umask 077 && printf '%s' "${!name}" > "${tmp_dir}/key.pem")
    if ! key=$(cd "${repo_root}/cli" && go run ./cmd/kvsctl-release pubkey --key "${tmp_dir}/key.pem" 2> "${tmp_dir}/pubkey.err"); then
        rm -f -- "${tmp_dir}/key.pem"
        reason=$(grep -m 1 '^kvsctl-release: ' "${tmp_dir}/pubkey.err" || cat "${tmp_dir}/pubkey.err")
        reason=${reason#"kvsctl-release: ${tmp_dir}/key.pem: "}
        die "$name is not a key kvsctl-release can sign with (${reason}): put the whole content of release.key there, its BEGIN and END lines included (docs/releasing.md, one-time setup)"
    fi
    rm -f -- "${tmp_dir}/key.pem"
    [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "kvsctl-release pubkey printed no public key for $name"
    printf '%s' "$key"
}

signing=()
for name in KVSCTL_RELEASE_KEY KVSCTL_RELEASE_KEY_NEXT; do
    [ -n "${!name:-}" ] || continue
    pub=$(public_half "$name")
    id=$(key_id "$pub")
    case ",${trusted}," in
        *",${pub},"*) ;;
        *) die "$name is the key ${id}, which ReleasePublicKey in ${shown_source} does not list (it lists $(trusted_ids)): the kvsctl of this commit would refuse every manifest it signs. Put the right key in the secret, or add the public half of this one to ReleasePublicKey in a new commit (docs/releasing.md)" ;;
    esac
    for other in "${signing[@]}"; do
        [ "$other" != "$pub" ] || die "KVSCTL_RELEASE_KEY_NEXT is the key ${id}, which KVSCTL_RELEASE_KEY already is: during a rotation it holds the new key"
    done
    signing+=("$pub")
    printf '%-24s %s, trusted by the kvsctl of this commit\n' "${name}:" "$id"
done

# ID=BASE64[@YYYY-MM-DD], whose form release-env.sh checks.
if [ -n "$ANNOUNCE_KEY" ]; then
    announced=${ANNOUNCE_KEY#*=}
    announced=${announced%%@*}
    signs=false
    for pub in "${signing[@]}"; do
        [ "$pub" != "$announced" ] || signs=true
    done
    [ "$signs" = true ] ||
        die "ANNOUNCE_KEY in $shown_file announces the key $(key_id "$announced"), and no signing secret is that key: the release that switches to it checks this manifest with that key alone, so kvsctl-release refuses to sign the announcement without it. Add it to the release environment as KVSCTL_RELEASE_KEY_NEXT (docs/releasing.md, Rotating the signing key)"
    printf '%-24s %s, signs this release\n' "announced key:" "$(key_id "$announced")"
fi
