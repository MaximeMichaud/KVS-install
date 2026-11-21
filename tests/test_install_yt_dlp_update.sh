#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2329
set -eo pipefail
source "$(dirname "$0")/../kvs-install.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export YT_DLP_BIN_DIR="$work/bin's 100% dir" FIXTURE="$work" RESPONSE=good
mkdir -p "$YT_DLP_BIN_DIR" "$work/tools"
export PATH="$work/tools:$PATH"
cat > "$work/tools/curl" <<'STUB'
#!/bin/bash
set -eu
output=/dev/stdout fail_http=false asset=
while (($#)); do
    case $1 in
        -o) output=$2; shift ;;
        -*f*) fail_http=true ;;
        */latest/download/*) asset=${1##*/} ;;
    esac
    shift
done
case $asset in
    SHA2-256SUMS)
        if [[ ${CHECK_MIGRATION:-} == yes && -x "$YT_DLP_BIN_DIR/kvs-update-yt-dlp" ]] &&
            ! grep -Fq 'curl -L' "$FIXTURE/root"; then
            touch "$FIXTURE/migrated-before-download"
        fi
        printf '%s  yt-dlp\n' "$(sha256sum < "$FIXTURE/expected" | cut -d' ' -f1)" > "$output"
        [[ $RESPONSE != no_manifest ]] || exit 18 ;;
    yt-dlp)
        case $RESPONSE in
            http) "$fail_http" && exit 22; cp "$FIXTURE/download" "$output" ;;
            truncated) echo partial > "$output"; exit 18 ;;
            partial) cp "$FIXTURE/download" "$output"; exit 18 ;;
            *) cp "$FIXTURE/download" "$output" ;;
        esac ;;
    *) exit 64 ;;
esac
STUB
# CI can run as root with a private temporary directory. Validate the
# privilege-drop arguments, then run the local fixture in that directory.
cat > "$work/tools/setpriv" <<'STUB'
#!/bin/bash
[[ ${1:-} == --reuid=www-data && ${2:-} == --regid=www-data &&
   ${3:-} == --clear-groups && ${4:-} == --no-new-privs && ${5:-} == -- ]] || exit 64
touch "$FIXTURE/privileges-checked"
shift 5
exec "$@"
STUB
chmod +x "$work/tools/"{curl,setpriv}
cat > "$work/good" <<'STUB'
#!/bin/sh
[ "$1" = --version ] || exit 2
echo 2026.01.02
STUB
cp "$work/good" "$work/expected"
cp "$work/good" "$work/download"
sed 's/2026.01.02/2025.12.01/' "$work/good" > "$work/original"
binary="$YT_DLP_BIN_DIR/yt-dlp"
cp "$work/original" "$binary"
chmod 755 "$binary"
reject() {
    if "$@"; then fail "$RESPONSE returned success"; fi
    cmp "$work/original" "$binary" || fail "$RESPONSE replaced the installed binary"
    if compgen -G "$YT_DLP_BIN_DIR/.yt-dlp.*" >/dev/null; then fail "left a staging file"; fi
}
# Keep both crontabs in the fixture. The old installer wrote the update
# inside this marked block. No PHP job should start during this migration.
crontab() {
    local user=root
    if [[ $1 == -u ]]; then user=$2; shift 2; fi
    case $1 in -l) cat "$work/$user" ;; -) cat > "$work/$user" ;; *) return 2 ;; esac
}
touch "$work/www-data"
cat > "$work/root" <<'CRON'
15 1 * * * /usr/local/bin/other-job
# BEGIN KVS YT-DLP UPDATE
0 0 * * * /bin/bash -c 'curl -L https://example.test/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp' > /dev/null 2>&1
# END KVS YT-DLP UPDATE
CRON

cp "$work/root" "$work/legacy-cron"
RESPONSE=no_manifest
for invalid in 'exit 1' 'echo 2025.12.01; exit 1' 'echo invalid' 'exit 0'; do
    printf '#!/bin/sh\n%s\n' "$invalid" > "$binary"
    if install_yt-dlp > "$work/log" 2>&1; then fail "accepted an unusable fallback ($invalid)"; fi
    [[ ! -e "$YT_DLP_BIN_DIR/youtube-dl" ]] || fail "published link to unusable fallback"
done
# Restore an existing installation with a working binary and its legacy job.
cp "$work/original" "$binary"
cp "$work/legacy-cron" "$work/root"
rm -f "$work/privileges-checked"
CHECK_MIGRATION=yes install_yt-dlp > "$work/log" 2>&1 || fail "a failed update stopped the migration"
if ((EUID == 0)); then
    [[ -f "$work/privileges-checked" ]] || fail "root ran the fallback directly"
fi
[[ -f "$work/migrated-before-download" ]] || fail "legacy migration depended on today's download"
cmp "$work/original" "$binary"
grep -Fiq 'keeping the installed yt-dlp' "$work/log" || fail "failed update was silent"
[[ -x "$YT_DLP_BIN_DIR/kvs-update-yt-dlp" ]] || fail "helper missing after migration"
[[ ! -s "$work/www-data" ]] || fail "site jobs installed before KVS"
grep -Fxq '15 1 * * * /usr/local/bin/other-job' "$work/root" || fail "lost unrelated job"
if grep -Fq 'curl -L' "$work/root"; then fail "legacy updater survived"; fi
nightly() {
    local job
    job=$(sed -n 's/^0 0 \* \* \* //p' "$work/root")
    [[ -n "$job" && "$job" != *$'\n'* ]] || fail "expected one nightly command"
    sh -c "$job"
}
RESPONSE=good
nightly || fail "migrated job did not execute"
cmp "$binary" "$work/good"

rm "$binary" "$YT_DLP_BIN_DIR/youtube-dl"
RESPONSE=http
if install_yt-dlp; then fail "fresh install accepted a failed download"; fi
[[ ! -e "$binary" ]] || fail "published a failed download"
RESPONSE=good
install_yt-dlp || fail "valid installation failed"
install_yt-dlp || fail "repeat installation failed"
cmp "$binary" "$work/good"
[[ -x "$binary" && "$binary" -ef "$YT_DLP_BIN_DIR/youtube-dl" ]] || fail "legacy link is unusable"

DOMAIN=example.test PHP=8.3 insert_cronjob
cp "$work/original" "$binary"
for RESPONSE in http partial truncated no_manifest; do reject nightly; done
RESPONSE=mismatch
# shellcheck disable=SC2016 # Expanded only if the downloaded fixture executes.
printf '#!/bin/sh\ntouch "$FIXTURE/executed"\necho 2026.01.02\n' > "$work/download"
reject nightly
[[ ! -e "$work/executed" ]] || fail "ran an unverified download"
RESPONSE=unusable
printf '#!/bin/sh\nexit 2\n' > "$work/download"
cp "$work/download" "$work/expected"
reject nightly
printf '#!/bin/sh\necho invalid\n' > "$work/download"
cp "$work/download" "$work/expected"
reject nightly
RESPONSE=good
cp "$work/good" "$work/download"
cp "$work/good" "$work/expected"
nightly || fail "valid nightly update failed"
cmp "$binary" "$work/good"
[[ $("$YT_DLP_BIN_DIR/youtube-dl" --version) == 2026.01.02 ]]
if ((EUID == 0)); then
    [[ -e "$work/privileges-checked" ]] || fail "root ran the version check directly"
fi
# Both callers must reject the input and resolved path before publishing
# into the distinct directory whose name lacks the trailing newline.
mkdir "$work/custom" "$work/custom"$'\n'
ln -s "$work/custom"$'\n' "$work/alias"
ln -s "$work/custom" "$work/alias"$'\n'
for path in "$work/custom"$'\n' "$work/alias" "$work/alias"$'\n'; do
    if YT_DLP_BIN_DIR="$path" install_yt-dlp; then fail "accepted a newline during setup"; fi
    if YT_DLP_BIN_DIR="$path" with_yt_dlp_cronjob ""; then fail "accepted a newline for cron"; fi
done
[[ -z $(find "$work/custom" "$work/custom"$'\n' -mindepth 1 -print -quit) ]] || fail "wrote into a rejected path"
echo 'ok - install and cron publish verified yt-dlp releases'
