#!/bin/bash
# select_geoip of docker/setup.sh downloaded the GeoLite2 database with
# curl -o straight to geoip/GeoLite2-Country.mmdb. A transfer cut short (curl
# exit 18) left the first part of the file there, and the next run saw the
# file, reported "GeoIP database already configured" and never downloaded it
# again, while KVS could not read it. The download now goes to a temporary
# file that is moved into place only when it holds the MaxMind metadata
# marker, and a re-run does not count an incomplete Country database as
# configured.
set -uo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kvs-geoip-download.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# The GeoIP step as the script defines it, without the call that follows it.
awk '
    $0 == "geoip_readable_by_php() {" { capture = 1 }
    capture && $0 == "select_geoip" { exit }
    capture { print }
' "$ROOT_DIR/docker/setup.sh" > "$WORK/geoip.sh"
grep -q '^select_geoip() {' "$WORK/geoip.sh" || fail "select_geoip is not defined after geoip_readable_by_php in docker/setup.sh"

# A database as the readers see it: data, then the metadata marker and the
# metadata. Its first half has no marker, only the name the data mentions;
# the marker followed by more than 128 KiB is out of the readers' reach.
marker=$'\xab\xcd\xefMaxMind.com'
{ printf 'MaxMind.com GeoLite2\n'; seq 1 1500; printf '%s' "$marker"; printf 'metadata'; } > "$WORK/complete.mmdb"
head -c "$(( $(stat -c %s "$WORK/complete.mmdb") / 2 ))" "$WORK/complete.mmdb" > "$WORK/half.mmdb"
{ printf '%s' "$marker"; head -c 140000 /dev/zero; } > "$WORK/far-marker.mmdb"

# curl writes STUB_BODY to its -o path, then exits with STUB_STATUS, as a
# transfer cut short does (exit 18 after part of the body). With STUB_KILL,
# it kills the shell that runs it instead, as a Ctrl-C or a lost session
# does in the middle of the transfer.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/curl" <<'STUB'
#!/bin/bash
out=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift ;;
    esac
    shift
done
printf '%s\n' "$out" >> "$CURL_LOG"
[ -z "${STUB_BODY:-}" ] || cat "$STUB_BODY" > "$out"
[ -z "${STUB_KILL:-}" ] || kill -KILL "$PPID"
exit "${STUB_STATUS:-0}"
STUB
chmod 755 "$WORK/stub/curl"

# run_geoip <case>: select_geoip in the case's directory, headless choice 1
# (download), no domain so that no Cloudflare lookup is made.
run_geoip() {
    local name=$1
    mkdir -p "$WORK/$name"
    touch "$WORK/$name/curl.log"
    # shellcheck disable=SC2016
    (cd "$WORK/$name" && PATH="$WORK/stub:$PATH" CURL_LOG="$WORK/$name/curl.log" \
        GEOIP_CHOICE=1 DOMAIN='' bash -c 'source "$1"; select_geoip; echo "rc=$?"' _ "$WORK/geoip.sh") 2>&1
}

curl_calls() { wc -l < "$WORK/$1/curl.log"; }

only_files() {
    local name=$1 expected=$2 found
    found=$(cd "$WORK/$name/geoip" 2>/dev/null && find . -mindepth 1 -maxdepth 1 -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')
    [ "$found" = "$expected" ] || fail "$name: geoip/ must hold '$expected', found '$found'"
}

# An interrupted transfer leaves nothing, and the next run downloads again.
out=$(STUB_BODY="$WORK/half.mmdb" STUB_STATUS=18 run_geoip retry)
grep -qx 'rc=0' <<< "$out" || fail "a failed download must not stop the setup: $out"
grep -q 'Download failed' <<< "$out" || fail "an interrupted download must be reported: $out"
! grep -qi 'no such file' <<< "$out" || fail "a fresh run must not print errors about the missing database: $out"
only_files retry ''
[ "$(curl_calls retry)" -eq 1 ] || fail "the first run must download once"
if ! grep -q '^geoip/.' "$WORK/retry/curl.log" || grep -qx 'geoip/GeoLite2-Country.mmdb' "$WORK/retry/curl.log"; then
    fail "curl must write a temporary file next to the database, got: $(cat "$WORK/retry/curl.log")"
fi
out=$(STUB_BODY="$WORK/complete.mmdb" run_geoip retry)
[ "$(curl_calls retry)" -eq 2 ] || fail "the run after an interrupted download must download again: $out"
grep -q 'GeoIP database downloaded' <<< "$out" || fail "the second download must succeed: $out"
cmp -s "$WORK/complete.mmdb" "$WORK/retry/geoip/GeoLite2-Country.mmdb" || fail "the complete database must be in place"
[ "$(stat -c %a "$WORK/retry/geoip/GeoLite2-Country.mmdb")" = 644 ] || fail "the database must be readable by www-data"
only_files retry 'GeoLite2-Country.mmdb '
out=$(run_geoip retry)
grep -q 'GeoIP database already configured' <<< "$out" || fail "a complete database must be kept: $out"
[ "$(curl_calls retry)" -eq 2 ] || fail "a complete database must not be downloaded again"
cmp -s "$WORK/complete.mmdb" "$WORK/retry/geoip/GeoLite2-Country.mmdb" || fail "a complete database must be left untouched"
pass "an interrupted download leaves no database and the next run downloads it"

# A run killed during the transfer cannot remove its temporary file. It is
# left in geoip/ under a name the checkout ignores, so that git status stays
# clean, and the next run downloads the database all the same.
out=$(STUB_BODY="$WORK/half.mmdb" STUB_KILL=1 run_geoip killed)
! grep -q '^rc=' <<< "$out" || fail "the run must be killed during the download: $out"
leftover=$(cd "$WORK/killed/geoip" && find . -mindepth 1 -maxdepth 1 -printf '%P\n')
[[ $leftover == .GeoLite2-Country.download.* ]] || fail "a killed run must leave its temporary file alone in geoip/, found '$leftover'"
cp "$ROOT_DIR/docker/geoip/.gitignore" "$WORK/killed/geoip/.gitignore"
git init -q "$WORK/killed"
shown=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$WORK/killed" -c core.excludesFile=/dev/null \
    status --porcelain --untracked-files=all -- geoip)
[ "$shown" = '?? geoip/.gitignore' ] || fail "git must ignore what a killed download leaves in geoip/, it shows: $shown"
out=$(STUB_BODY="$WORK/complete.mmdb" run_geoip killed)
cmp -s "$WORK/complete.mmdb" "$WORK/killed/geoip/GeoLite2-Country.mmdb" || fail "the run after a killed download must download again: $out"
pass "a download killed halfway leaves only a file git ignores"

# curl may succeed with a body that is not a whole database (a proxy page, a
# file the mirror truncated): it is refused like a failed transfer.
for body in half far-marker; do
    out=$(STUB_BODY="$WORK/$body.mmdb" STUB_STATUS=0 run_geoip "ok-$body")
    grep -q 'Download failed' <<< "$out" || fail "$body: a body without the MaxMind metadata must be refused: $out"
    only_files "ok-$body" ''
done
pass "a download without the MaxMind metadata at its end is refused"

# A partial database an older release left behind is reported and replaced.
mkdir -p "$WORK/older/geoip"
cp "$WORK/half.mmdb" "$WORK/older/geoip/GeoLite2-Country.mmdb"
out=$(STUB_BODY="$WORK/half.mmdb" STUB_STATUS=18 run_geoip older)
grep -q 'GeoLite2-Country.mmdb is incomplete' <<< "$out" || fail "an incomplete database must be reported: $out"
grep -q 'already configured' <<< "$out" && fail "an incomplete database must not be called configured: $out"
[ "$(curl_calls older)" -eq 1 ] || fail "an incomplete database must be downloaded again"
cmp -s "$WORK/half.mmdb" "$WORK/older/geoip/GeoLite2-Country.mmdb" || fail "a failed download must leave the existing file as it was"
only_files older 'GeoLite2-Country.mmdb '
out=$(STUB_BODY="$WORK/complete.mmdb" run_geoip older)
cmp -s "$WORK/complete.mmdb" "$WORK/older/geoip/GeoLite2-Country.mmdb" || fail "a complete download must replace the incomplete database: $out"
only_files older 'GeoLite2-Country.mmdb '
pass "an incomplete database from an earlier run is reported and replaced"

# A City database is placed by hand and is kept as it is.
mkdir -p "$WORK/city/geoip"
printf 'operator file\n' > "$WORK/city/geoip/GeoLite2-City.mmdb"
out=$(run_geoip city)
grep -q 'GeoIP database already configured' <<< "$out" || fail "a City database must count as configured: $out"
[ "$(curl_calls city)" -eq 0 ] || fail "nothing must be downloaded next to a City database"
grep -qx 'operator file' "$WORK/city/geoip/GeoLite2-City.mmdb" || fail "the City database must be left untouched"
pass "a City database placed by hand is kept"

# A directory where the database goes stays a directory: no file is moved into it.
mkdir -p "$WORK/directory/geoip/GeoLite2-Country.mmdb"
out=$(STUB_BODY="$WORK/complete.mmdb" run_geoip directory)
grep -q 'Download failed' <<< "$out" || fail "a directory in place of the database must fail the step: $out"
[ -z "$(ls -A "$WORK/directory/geoip/GeoLite2-Country.mmdb")" ] || fail "nothing must be moved into the directory"
only_files directory 'GeoLite2-Country.mmdb '
pass "a directory in place of the database is left alone"
