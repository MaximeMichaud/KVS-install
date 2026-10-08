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
# The new manifest is the previous one with this release added, so the
# previous one has to be the manifest of the newest stack release. One built
# on an older manifest, or on none, would drop every release in between, and
# with them their min_from stops and the database flags kvsctl carries over a
# jump. The script therefore asks the GitHub API for the stack releases: the
# published releases of a stable version (YY.M.PATCH) that carry what the
# release workflow uploads, the manifest, its signature, the bundle or the
# kvsctl binaries.
#
#   - none: this is the first release. The download 404s, the script says so
#     and exits 0 without writing the output file, and the caller passes no
#     --previous. A candidate (26.11.0-rc1) or a draft carrying a manifest
#     does not count: neither ever was the latest release.
#   - some: the newest of them has to carry its manifest.json, and the
#     downloaded manifest has to list it. A 404 instead means the release
#     GitHub marks as the latest one is not a stack release (one made by
#     hand, which GitHub marks latest by default), and the script stops and
#     names it.
#
# A release counts by its tag and its assets, not by its pre-release flag or
# by the manifest it still has. The workflow sets the flag from the tag, and
# a stable release flipped to pre-release by hand afterwards is still in the
# chain, as is one whose manifest.json was deleted: building on an older
# manifest would drop it.
#
# Any other answer, an answer cut short or none at all, is fatal. A manifest
# that does not verify means the key, the signature or the release assets are
# not what this repository believes they are, and the release must stop
# rather than sign a list built on top of something unverified.
#
# The API needs GITHUB_REPOSITORY and GH_TOKEN (or GITHUB_TOKEN), and reads
# GITHUB_API_URL when it is set, as GitHub Actions sets them. The public keys
# come from KVSCTL_RELEASE_PUBKEY (comma separated base64) or, by default,
# from ReleasePublicKey in cli/cmd/kvsctl/main.go, read by
# release-public-keys.sh: the keys the kvsctl built from this checkout
# trusts, which the release workflow also checks the new manifest against.

set -euo pipefail

die() {
    printf 'verify-manifest: %s\n' "$*" >&2
    exit 1
}

[ $# -eq 2 ] || die "usage: verify-manifest.sh <base-url> <output-file>"

base_url=$1
output=$2
repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

repository=${GITHUB_REPOSITORY:-}
token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
api=${GITHUB_API_URL:-https://api.github.com}
[ -n "$repository" ] && [ -n "$token" ] ||
    die "GITHUB_REPOSITORY and GH_TOKEN (or GITHUB_TOKEN) are needed to ask GitHub which releases carry a manifest"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

# fetch <url> <file> [curl argument...]: prints the HTTP status, 000 when no
# answer came. curl reads the status before the body, so when it fails after
# that, the body was cut short: the status then carries curl's exit status,
# and no caller can take it for a 200 or a 404.
fetch() {
    local url=$1 destination=$2 status code=0
    shift 2

    status=$(curl -sSL -o "$destination" -w '%{http_code}' "$@" "$url") || code=$?
    status=${status:-000}
    if [ "$code" -ne 0 ] && [ "$status" != 000 ]; then
        status="${status}, incomplete: curl exit ${code}"
    fi
    printf '%s' "$status"
}

api_get() {
    fetch "${api}$1" "$2" \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github+json"
}

# The published releases that carry an asset of the release workflow, from
# every page of the list, one per line: the tag, the pre-release flag and
# whether manifest.json is still there, separated by tabs.
stack_releases() {
    local page=1 status file

    while :; do
        # A file of its own, so a page that never arrived cannot leave the
        # previous one to be read again.
        file="${tmp_dir}/releases-${page}.json"
        status=$(api_get "/repos/${repository}/releases?per_page=100&page=${page}" "$file")
        [ "$status" = 200 ] ||
            die "listing the releases of ${repository} returned HTTP ${status}"
        # Exactly one JSON array. An empty body or an object would read as a
        # short page, the last one, and end the list early.
        jq -e -s 'length == 1 and (.[0] | type == "array")' "$file" >/dev/null 2>&1 ||
            die "page ${page} of the releases of ${repository} is not a list of releases"
        jq -r '.[]
            | select(.draft == false)
            | select(any(.assets[]?.name | strings;
                . == "manifest.json" or . == "manifest.json.sig"
                or startswith("kvs-stack-") or startswith("kvsctl-")))
            | "\(.tag_name)\t\(.prerelease)\t\(any(.assets[]?.name; . == "manifest.json"))"' "$file" ||
            die "the list of the releases of ${repository} is not what GitHub sends"
        [ "$(jq 'length' "$file")" -ge 100 ] || return 0
        page=$((page + 1))
    done
}

# The release GitHub marks as the latest one, as the reader should hear it.
latest_release() {
    local status

    status=$(api_get "/repos/${repository}/releases/latest" "${tmp_dir}/latest.json")
    if [ "$status" = 200 ] &&
        jq -er 'select(.tag_name | type == "string") | "\(.tag_name) (\(.html_url))"' \
            "${tmp_dir}/latest.json" 2>/dev/null; then
        return 0
    fi
    case "$status" in
        404) printf 'no release' ;;
        *) printf 'a release the API did not name (HTTP %s)' "$status" ;;
    esac
}

manifest_status=$(fetch "${base_url}/manifest.json" "${tmp_dir}/manifest.json")
case "$manifest_status" in
    200 | 404) ;;
    *) die "downloading ${base_url}/manifest.json returned HTTP ${manifest_status}" ;;
esac

stack_releases > "${tmp_dir}/stack-releases"
# The newest stable version among them, compared as numbers.
newest=$(cut -f1 "${tmp_dir}/stack-releases" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true)

if [ -z "$newest" ]; then
    if [ "$manifest_status" = 404 ]; then
        echo "no stable release carries a manifest yet: this is the first one, nothing to verify"
        exit 0
    fi
    die "${base_url}/manifest.json exists, but no stable release carries a manifest.json: GitHub marks $(latest_release) as the latest one, which is not a stack release"
fi

newest_flags=$(awk -F'\t' -v tag="$newest" '$1 == tag { print $2, $3; exit }' "${tmp_dir}/stack-releases")
read -r newest_prerelease newest_manifest <<<"$newest_flags"

# A stack release whose manifest.json was deleted cannot be built on, and a
# manifest built on an older one would drop it.
[ "$newest_manifest" = true ] ||
    die "${newest}, the newest stack release, carries no manifest.json any more, and a manifest built on an older one would drop it: upload its manifest.json again (docs/releasing.md) and run the job again"

# What makes the newest stack release the latest one again. GitHub never
# marks a pre-release as the latest one, so a flag set by hand goes first.
if [ "$newest_prerelease" = true ]; then
    mark_newest="${newest} is flagged as a pre-release, which GitHub never marks as the latest one: clear that flag, mark ${newest} as the latest release again (docs/releasing.md) and run the job again"
else
    mark_newest="Mark ${newest} as the latest release again (docs/releasing.md) and run the job again"
fi

[ "$manifest_status" != 404 ] ||
    die "${base_url}/manifest.json answered 404, but ${newest} is a stack release: GitHub marks $(latest_release) as the latest one. ${mark_newest}"

signature_status=$(fetch "${base_url}/manifest.json.sig" "${tmp_dir}/manifest.json.sig")
[ "$signature_status" = "200" ] ||
    die "the previous release has a manifest but no signature (HTTP ${signature_status})"

keys=${KVSCTL_RELEASE_PUBKEY:-}
if [ -z "$keys" ]; then
    # The keys kvsctl trusts are the ones compiled into it, so reading them
    # from the source proves the previous manifest verifies with exactly what
    # the binaries built from this checkout hold.
    keys=$("${repo_root}/.github/scripts/release-public-keys.sh")
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

# The manifest is signed, but it comes from whichever release GitHub marks as
# the latest one, and an edit can mark an older stack release: building on
# its manifest would drop the newer ones.
jq -e --arg version "$newest" 'any(.releases[]?; .version == $version)' \
    "${tmp_dir}/manifest.json" >/dev/null ||
    die "the manifest of the latest release does not list ${newest}, the newest stack release: GitHub marks $(latest_release) as the latest one. ${mark_newest}"

cp -- "${tmp_dir}/manifest.json" "$output"
echo "previous manifest verified and saved as ${output}"
