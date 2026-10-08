#!/usr/bin/env bash
#
# Check .github/release.env before anything is built or pushed.
#
#   release-env.sh <version> [release.env]
#
# The publish job of .github/workflows/release.yml reads the file as shell
# assignments and writes it into the signed manifest. A value kvsctl-release
# would refuse, or a release without its line of notes, would only show up
# there, after the images job has pushed every image under the version tag.
# The prepare job runs this script first, so such a run stops before anything
# leaves the runner. kvsctl-release checks the same values again when it
# signs. What depends on more than this file is checked before the images
# job too: MIN_FROM against the manifest of the latest release by
# release-previous.sh in the prepare job, ANNOUNCE_KEY against the signing
# keys by release-signing-keys.sh in the keys job.

set -euo pipefail

die() {
    printf 'release-env: %s\n' "$*" >&2
    exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: release-env.sh <version> [release.env]"

release_version=$1
repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
file=${2:-${repo_root}/.github/release.env}
[ -f "$file" ] || die "$file does not exist"

# Every knob starts empty, so a line missing from the file reads as empty
# here, as it does in the publish job. The highlights are read through
# ${!knob} only.
# shellcheck disable=SC2034
NOTES='' HIGHLIGHT_1='' HIGHLIGHT_2='' HIGHLIGHT_3='' MIN_FROM='' DATABASE='' ONE_WAY=''
KVS_MIN='' KVSCTL_MIN='' COMPOSE_MIN='' ANNOUNCE_KEY=''
# shellcheck source=/dev/null
. "$file"

# A version kvsctl-release accepts: three plain numbers. A leading zero is
# refused, since kvsctl prints the numbers back and 2.024.0 would no longer
# name what was written, and so is a number too large for it to hold.
number='(0|[1-9][0-9]{0,17})'
stable="^${number}\\.${number}\\.${number}\$"

[[ "$release_version" =~ ^${number}\.${number}\.${number}(-.+)?$ ]] ||
    die "'$release_version' is not a release version"

# compare <a> <b>: -1, 0 or 1 as the numbers of version a come before, are,
# or come after those of version b, a pre-release suffix aside. Both carry
# 18 digits at most, which a shell integer holds.
compare() {
    local i
    local -a a b
    IFS=. read -r -a a <<<"${1%%-*}"
    IFS=. read -r -a b <<<"${2%%-*}"
    for i in 0 1 2; do
        if [ "${a[$i]}" -lt "${b[$i]}" ]; then
            echo -1
            return
        fi
        if [ "${a[$i]}" -gt "${b[$i]}" ]; then
            echo 1
            return
        fi
    done
    echo 0
}

[ -n "$NOTES" ] ||
    die "NOTES is empty in $file: write the one line kvsctl shows beside the version, in the commit the tag points at"
case "$NOTES" in
    *$'\n'* | *$'\r'*) die "NOTES in $file holds more than one line: kvsctl shows it beside the version" ;;
esac

# blank <value>: whether the value holds nothing but white space as
# kvsctl-release sees it, which trims with Go's strings.TrimSpace: the ASCII
# blanks and the Unicode White_Space characters, the no-break space among
# them. Each is removed as the bytes of its UTF-8 form, so the answer does
# not depend on the locale the script runs in, as a [:space:] class would.
blank() {
    local rest=$1 white
    for white in ' ' $'\t' $'\n' $'\v' $'\f' $'\r' \
        $'\xc2\x85' $'\xc2\xa0' $'\xe1\x9a\x80' \
        $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' $'\xe2\x80\x83' \
        $'\xe2\x80\x84' $'\xe2\x80\x85' $'\xe2\x80\x86' $'\xe2\x80\x87' \
        $'\xe2\x80\x88' $'\xe2\x80\x89' $'\xe2\x80\x8a' \
        $'\xe2\x80\xa8' $'\xe2\x80\xa9' $'\xe2\x80\xaf' $'\xe2\x81\x9f' \
        $'\xe3\x80\x80'; do
        rest=${rest//"$white"/}
    done
    [ -z "$rest" ]
}

# Each highlight is one line of the confirmation screen; an empty one is
# left out, a blank one would print an empty line.
for knob in HIGHLIGHT_1 HIGHLIGHT_2 HIGHLIGHT_3; do
    value=${!knob}
    [ -n "$value" ] || continue
    case "$value" in
        *$'\n'* | *$'\r'*) die "$knob in $file holds more than one line: kvsctl shows each highlight as one line" ;;
    esac
    if blank "$value"; then
        die "$knob in $file holds only blanks: leave it empty, or write the line kvsctl shows"
    fi
done

case "$DATABASE" in
    none | migrates) ;;
    *) die "DATABASE in $file is '$DATABASE': none or migrates" ;;
esac

case "$ONE_WAY" in
    true | false) ;;
    *) die "ONE_WAY in $file is '$ONE_WAY': true or false" ;;
esac

for knob in KVS_MIN KVSCTL_MIN COMPOSE_MIN; do
    value=${!knob}
    [ -z "$value" ] || [[ "$value" =~ $stable ]] ||
        die "$knob in $file is '$value', which is not a version (MAJOR.MINOR.PATCH, plain numbers without a leading zero)"
done

# update-cli installs the kvsctl a release ships, so KVSCTL_MIN is at most
# the release; the candidates of that release ask for their own kvsctl
# (kvsctl-release writes the version of the candidate).
if [ -n "$KVSCTL_MIN" ] && [ "$(compare "$KVSCTL_MIN" "$release_version")" = 1 ]; then
    die "KVSCTL_MIN in $file is $KVSCTL_MIN, which is newer than the release $release_version: update-cli installs the kvsctl a release ships, so no installation could install it"
fi

# MIN_FROM names a stable release older than this one, or no installation
# could ever upgrade straight to it.
if [ -n "$MIN_FROM" ]; then
    [[ "$MIN_FROM" =~ $stable ]] ||
        die "MIN_FROM in $file is '$MIN_FROM', which is not a release version (YY.M.PATCH, plain numbers without a leading zero)"
    [ "$(compare "$MIN_FROM" "$release_version")" = -1 ] ||
        die "MIN_FROM in $file is $MIN_FROM, which is not older than the release $release_version"
fi

# ID=BASE64 or ID=BASE64@YYYY-MM-DD. kvsctl recognizes a key it already
# trusts by its id, the first eight hexadecimal characters of the sha256 of
# the raw public key, so the id has to be that one. The day has to exist:
# date reads it back unchanged only when it does (2026-02-30 is refused, as
# kvsctl-release refuses it).
if [ -n "$ANNOUNCE_KEY" ]; then
    [[ "$ANNOUNCE_KEY" =~ ^([0-9a-f]{8})=([A-Za-z0-9+/]{43}=)(@([0-9]{4}-[0-9]{2}-[0-9]{2}))?$ ]] ||
        die "ANNOUNCE_KEY in $file is not ID=BASE64 or ID=BASE64@YYYY-MM-DD"
    announced_id=${BASH_REMATCH[1]}
    announced_key=${BASH_REMATCH[2]}
    takes_over=${BASH_REMATCH[4]}
    derived_id=$(printf '%s' "$announced_key" | base64 -d | sha256sum | cut -c1-8)
    [ "$announced_id" = "$derived_id" ] ||
        die "ANNOUNCE_KEY in $file names the key $announced_id, but the id of that key is $derived_id (kvsctl-release keygen prints it)"
    if [ -n "$takes_over" ] &&
        [ "$(date -u -d "$takes_over" +%Y-%m-%d 2>/dev/null || true)" != "$takes_over" ]; then
        die "ANNOUNCE_KEY in $file takes over on $takes_over, which is not a day of the calendar"
    fi
fi

printf 'notes:        %s\n' "$NOTES"
for knob in HIGHLIGHT_1 HIGHLIGHT_2 HIGHLIGHT_3; do
    [ -z "${!knob}" ] || printf 'highlight:    %s\n' "${!knob}"
done
printf 'min from:     %s\n' "${MIN_FROM:-any version}"
printf 'database:     %s\n' "$DATABASE"
printf 'one way:      %s\n' "$ONE_WAY"
printf 'kvs min:      %s\n' "${KVS_MIN:-none}"
printf 'kvsctl min:   %s\n' "${KVSCTL_MIN:-none}"
printf 'compose min:  %s\n' "${COMPOSE_MIN:-none}"
printf 'announce key: %s\n' "${ANNOUNCE_KEY:-none}"
