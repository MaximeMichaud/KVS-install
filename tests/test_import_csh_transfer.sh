#!/bin/bash
# Run the rsync protocol locally with a non-POSIX login shell on the source.
# shellcheck disable=SC2034,SC2016
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
tmp=$(mktemp -d)
sampler=''
cleanup() {
    if [ -n "$sampler" ]; then kill "$sampler" 2>/dev/null || true; wait "$sampler" || true; fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir "$tmp/bin" "$tmp/site" "$tmp/logs" "$tmp/remote"
export TMPDIR="$tmp" REMOTE_TMP="$tmp/remote" CALLS="$tmp/calls" REAL_RSYNC
REAL_RSYNC=$(command -v rsync)
cat > "$tmp/bin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS.ssh"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O) exit 0 ;;
        -o|-p|-i|-S|-l) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
shift
export TMPDIR="$REMOTE_TMP"
if command -v tcsh >/dev/null; then exec tcsh -f -c "$*"; fi
# On systems without tcsh, reject the Bourne constructs a login csh
# cannot parse; execute the command that was actually sent otherwise.
case "$*" in
    "sh -c '"*|'sh -s') ;;
    *'>&2'*|*'${'*|*'for d in '*) exit 2 ;;
esac
exec sh -c "$*"
STUB
cat > "$tmp/bin/rsync" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS.rsync"
exec "$REAL_RSYNC" "$@"
STUB
cat > "$tmp/bin/sudo" <<'STUB'
#!/bin/sh
[ "$1" = -n ] || exit 2
shift
exec "$@"
STUB
cat > "$tmp/bin/df" <<'STUB'
#!/bin/sh
if [ "$1" = -Pk ]; then
    [ "$2" = "$REMOTE_TMP" ] || exit 1
    printf 'Filesystem kB Used Available Capacity Mount\nfake 9999999 0 5000000 0%% /\n'
else
    exec /bin/df "$@"
fi
STUB
chmod +x "$tmp/bin/"*
PATH="$tmp/bin:$PATH"
IMPORT_SSH_CONTROL_DIR="$tmp/ctl" import_ssh_setup old.test 22 deploy '' yes
IMPORT_TRANSFER_JOBS=2 IMPORT_TRANSFER_CHUNK=1 IMPORT_TRANSFER_RETRIES=0 IMPORT_TRANSFER_LOG_DIR="$tmp/logs"
for name in a 'two words' c d; do printf '%s\n' "$name" > "$tmp/site/$name"; done
for IMPORT_REMOTE_SUDO in no yes; do
    dest="$tmp/dest-$IMPORT_REMOTE_SUDO"
    import_remote_files "$tmp/site" "$dest" yes > "$tmp/out" 2>&1 || fail "$(cat "$tmp/out")"
    diff -r "$tmp/site" "$dest"
    grep -Fxq KVS_IMPORT_SSH_READY "$tmp/logs/1.err" || fail 'worker 1 did not signal readiness on stderr'
    grep -Fxq KVS_IMPORT_SSH_READY "$tmp/logs/2.err" || fail 'worker 2 did not signal readiness on stderr'
    grep -q "Chunk lists copied to $REMOTE_TMP/" "$tmp/out" || fail 'the source did not store the chunk lists'
    [ -z "$(ls -A "$REMOTE_TMP")" ] || fail 'chunk lists stayed on the source'
done
for parent in "space dir" "quote's-dir" relative; do
    mkdir "$REMOTE_TMP/$parent"
    (
        cd "$REMOTE_TMP"
        path="$REMOTE_TMP/$parent"
        [ "$parent" != relative ] || path=relative
        if REMOTE_TMP="$path" import_remote_plan_dir; then fail 'unsupported plan directory accepted'; fi
    )
    [ -z "$(ls -A "$REMOTE_TMP/$parent")" ] || fail "a rejected plan directory leaked under $parent"
done
grep -q 'sudo -n rsync --server' "$CALLS.ssh" || fail 'the remote rsync did not use sudo'
import_disk_sampler "$tmp/disks" 1 &
sampler=$!
for ((i=0; i<100; i++)); do
    [ ! -s "$tmp/disks.previous" ] || break
    sleep 0.05
done
[ -s "$tmp/disks.previous" ] || fail 'the disk probe could not read through the login shell'
grep -q '^[0-9].* ' "$tmp/disks.previous" || fail 'missing disk reading'
echo 'PASS: the source shell can run both workers, keep chunk lists and read disk statistics'
