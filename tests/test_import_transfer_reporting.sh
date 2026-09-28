#!/bin/bash
# Transfer timing, diagnostics and exit codes, using synthetic local data.
# Put a different awk on PATH to run the same checks with Debian mawk.
# shellcheck disable=SC2034,SC2329,SC2030,SC2031
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-transfer-reporting.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Exercise real elapsed time, not an assumed random-seed representation.
out=$(
    {
        printf ' 0 0%% 0.00B/s 0:00:00 (xfr#0)\n'
        sleep 2
        printf ' 4194304 100%% 2.00MB/s 0:00:02 (xfr#150)\n'
    } | import_rsync_progress 0 0 no
)
[[ "$out" =~ in\ ([0-9]+):([0-9]{2}):([0-9]{2}) ]] || fail "missing elapsed time: $out"
elapsed=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
[ "$elapsed" -ge 1 ] && [ "$elapsed" -le 30 ] || fail "two seconds became $elapsed seconds"
grep -Eq 'Transferred 150 files, 4.0 MB.*\([1-9][0-9.]* (MB|kB|B)/s, [1-9][0-9,]* files/s\)' <<< "$out" || fail "incorrect rates: $out"
echo 'PASS: real elapsed seconds and nonzero byte/file rates'

# A carriage-return record must appear while the producer is still busy,
# even when stdout is a log file and the input pipe has not filled up.
{
    printf ' 0 0%% 0.00B/s 0:00:00 (xfr#0)\r'
    sleep 2
    printf ' 1024 100%% 1.00kB/s 0:00:02 (xfr#1)\n'
} | import_rsync_progress 0 0 no > "$TEST_DIR/live" &
progress_pid=$!
live=no
for ((attempt = 0; attempt < 20; attempt++)); do
    if [ -s "$TEST_DIR/live" ]; then live=yes; break; fi
    sleep 0.05
done
wait "$progress_pid"
[ "$live" = yes ] || fail 'progress waited for a full input buffer or EOF'
echo 'PASS: progress is displayed before the next record or EOF'

out=$(printf 'Number of files: 5000000000\nNumber of regular files transferred: 4000000000\nTotal file size: 12000000000 bytes\nTotal transferred file size: 11000000000 bytes\n' | import_rsync_stats_totals)
[ "$out" = $'4000000000\t11000000000\t5000000000\t12000000000' ] || fail "large totals overflowed: $out"
echo 'PASS: totals above 32-bit integer limits'

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/logs" "$TEST_DIR/destination"
cat > "$TEST_DIR/bin/rsync" <<'RSYNC'
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = --dry-run ]; then
        printf 'Number of regular files transferred: 1\nTotal transferred file size: 1024 bytes\n'
        exit 0
    fi
done
printf ' 1024 100%% 1.00kB/s 0:00:01 (xfr#1)\n'
if [ "${FIXTURE_RSYNC_STATUS:-0}" -ne 0 ]; then
    echo 'rsync: fixture connection unexpectedly closed' >&2
fi
exit "${FIXTURE_RSYNC_STATUS:-0}"
RSYNC
chmod +x "$TEST_DIR/bin/rsync"
(
    PATH="$TEST_DIR/bin:$PATH"
    IMPORT_TRANSFER_JOBS=1 IMPORT_REMOTE_SUDO=no IMPORT_SIZE_TIMEOUT=1
    IMPORT_SSH_TARGET=root@source.test IMPORT_TRANSFER_LOG_DIR="$TEST_DIR/logs"
    import_ssh_rsh() { printf unused; }
    export FIXTURE_RSYNC_STATUS=12
    status=0
    import_remote_files /srv/example "$TEST_DIR/destination" yes > "$TEST_DIR/output" 2>&1 || status=$?
    [ "$status" -eq 12 ] || fail "rsync status 12 became $status"
    grep -q 'final rsync synchronization failed (status 12)' "$TEST_DIR/output" || fail 'missing rsync exit code'
    grep -q 'fixture connection unexpectedly closed' "$TEST_DIR/logs/final-rsync.err" || fail 'missing durable rsync error'
    grep -Fxq 'rsync=12 progress=0' "$TEST_DIR/logs/final.status" || fail 'missing pipeline exit codes'
    # A renderer failure must not turn a successful rsync into setup success.
    import_rsync_progress() { cat >/dev/null; return 7; }
    export FIXTURE_RSYNC_STATUS=0
    status=0
    import_remote_files /srv/example "$TEST_DIR/destination" yes > "$TEST_DIR/output" 2>&1 || status=$?
    [ "$status" -eq 7 ] || fail "renderer status 7 became $status"
    grep -Fxq 'rsync=0 progress=7' "$TEST_DIR/logs/final.status" || fail 'missing renderer exit code'
) || exit 1
echo 'PASS: rsync and progress failures retain distinct exit codes and diagnostics'

mkdir -p "$TEST_DIR/plan" "$TEST_DIR/worker-logs"
printf 'file\0' > "$TEST_DIR/plan/1.list"
status=0
PATH="$TEST_DIR/bin:$PATH" FIXTURE_RSYNC_STATUS=12 IMPORT_TRANSFER_LOG_DIR="$TEST_DIR/worker-logs" \
    import_rsync_workers "$TEST_DIR/plan" 1 unused > "$TEST_DIR/worker-output" 2>&1 || status=$?
[ "$status" -eq 12 ] || fail "worker status 12 became $status"
rm -rf "$TEST_DIR/plan"
grep -q 'fixture connection unexpectedly closed' "$TEST_DIR/worker-logs/1.err" || fail 'worker cleanup lost its diagnostics'
grep -Fxq 12 "$TEST_DIR/worker-logs/1.status" || fail 'worker exit code was not saved'
echo 'PASS: worker diagnostics survive temporary file-list cleanup'

# Exercise the setup caller without touching /var/www or contacting SSH.
awk '
    /^import_fetch_remote\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/fetch.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/fetch.sh"
DOMAIN=example.test IMPORT_STAGING="$TEST_DIR/staging" LOG_DIR="$TEST_DIR/setup-logs"
IMPORT_REMOTE_COMPRESSOR=gzip IMPORT_REMOTE_DATABASE_FORMAT=sql IMPORT_REMOTE_PORT=22
IMPORT_REMOTE_DIR=/srv/example IMPORT_REMOTE_RSYNC=yes IMPORT_EXPORTER=unused
IMPORT_SSH_TARGET=root@source.test IMPORT_EXCLUDE_PATTERNS=()
RED='' GREEN='' CYAN='' NC=''
mkdir -p "$LOG_DIR"
import_remote_dump() { printf 'synthetic dump\n' > "$3"; }
import_destination_ready() { return 0; }
import_mark_destination() { return 0; }
import_ssh_close() { return 0; }
import_remote_files() {
    printf 'durable fixture error\n' > "$IMPORT_TRANSFER_LOG_DIR/final-rsync.err"
    return 12
}
status=0
(import_fetch_remote) > "$TEST_DIR/fetch-output" 2>&1 || status=$?
[ "$status" -eq 12 ] || fail "setup discarded status 12: $status"
grep -q 'file transfer failed (status 12)' "$TEST_DIR/fetch-output" || fail 'setup omitted the failure status'
saved=$(sed -n 's/^  Transfer diagnostics: //p' "$TEST_DIR/fetch-output")
[[ "$saved" == "$LOG_DIR"/import-transfer.* ]] || fail 'setup omitted the diagnostics path'
bash -eu -c 'grep -Fxq "durable fixture error" "$1/final-rsync.err"' bash "$saved" || fail 'a fresh process cannot read saved diagnostics'
[ "$(stat -c %a "$saved")" = 700 ] || fail 'diagnostics directory is not private'
import_remote_files() { return 0; }
import_fetch_remote > "$TEST_DIR/fetch-success"
mapfile -t remaining < <(find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d)
[ "${#remaining[@]}" -eq 1 ] && [ "${remaining[0]}" = "$saved" ] || fail 'success removed previous errors or left a new diagnostics directory'
echo 'PASS: setup preserves failed diagnostics across processes and cleans successful attempts'
