#!/bin/bash
# Real rsync regression: a live source removes a file after worker planning.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-import-missing.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TEST_DIR/source/admin/data/stats" "$TEST_DIR/destination/admin/data/stats" "$TEST_DIR/plan"
printf 'site content\n' > "$TEST_DIR/source/keep.txt"
printf 'old counter\n' > "$TEST_DIR/destination/admin/data/stats/rotating.dat"
printf 'new counter\n' > "$TEST_DIR/source/admin/data/stats/rotating.dat"
printf './keep.txt\0' > "$TEST_DIR/plan/1.list"
printf './admin/data/stats/rotating.dat\0' > "$TEST_DIR/plan/2.list"
rm "$TEST_DIR/source/admin/data/stats/rotating.dat"

# Prove the exact failure with the previous worker invocation, without
# mocking an exit status: an explicitly listed missing source returns 23.
status=0
rsync -a --force --no-recursive --dirs --from0 --files-from="$TEST_DIR/plan/2.list" \
    "$TEST_DIR/source/" "$TEST_DIR/destination/" > "$TEST_DIR/before.log" 2>&1 || status=$?
[ "$status" -eq 23 ] || fail "missing planned file should reproduce status 23, got $status"

import_rsync_workers "$TEST_DIR/plan" 2 unused -a --delete \
    "$TEST_DIR/source/" "$TEST_DIR/destination/" > "$TEST_DIR/workers.log" 2>&1 || fail 'a vanished planned file stopped the workers'
cmp "$TEST_DIR/source/keep.txt" "$TEST_DIR/destination/keep.txt" || fail 'another worker did not copy its file'
grep -Fxq 'old counter' "$TEST_DIR/destination/admin/data/stats/rotating.dat" || fail 'a worker deleted a missing source path'
grep -Fxq 0 "$TEST_DIR/plan/2.status" || fail 'the missing-file worker did not complete successfully'
echo 'PASS: a real missing-file status 23 is avoided without interrupting other workers or deleting destination data'

# A file recreated before the final ordinary mirror must be copied with
# its latest contents; a path that stays absent must be removed there.
printf 'regenerated counter\n' > "$TEST_DIR/source/admin/data/stats/rotating.dat"
rsync -a --delete "$TEST_DIR/source/" "$TEST_DIR/destination/"
bash -eu -c 'cmp "$1/admin/data/stats/rotating.dat" "$2/admin/data/stats/rotating.dat"' \
    bash "$TEST_DIR/source" "$TEST_DIR/destination" || fail 'the final pass lost a regenerated file'
rm "$TEST_DIR/source/admin/data/stats/rotating.dat"
rsync -a --delete "$TEST_DIR/source/" "$TEST_DIR/destination/"
[ ! -e "$TEST_DIR/destination/admin/data/stats/rotating.dat" ] || fail 'the final pass kept a vanished file'
echo 'PASS: the final mirror copies regenerated files and removes paths that remain absent'

if [ "$EUID" -ne 0 ]; then
    printf 'restricted content\n' > "$TEST_DIR/source/restricted.txt"
    chmod 000 "$TEST_DIR/source/restricted.txt"
    printf './restricted.txt\0' > "$TEST_DIR/plan/1.list"
    status=0
    import_rsync_workers "$TEST_DIR/plan" 1 unused -a \
        "$TEST_DIR/source/" "$TEST_DIR/destination/" > "$TEST_DIR/permission.log" 2>&1 || status=$?
    chmod 600 "$TEST_DIR/source/restricted.txt"
    [ "$status" -eq 23 ] || fail "a real permission error must still fail with status 23, got $status"
    [ ! -e "$TEST_DIR/destination/restricted.txt" ] || fail 'an unreadable file was presented as copied'
    grep -Fxq 23 "$TEST_DIR/plan/1.status" || fail 'the permission failure was not recorded'
    echo 'PASS: real permission failures still stop the transfer with status 23'
else
    echo 'SKIP: permission-denied case requires an unprivileged test user'
fi
