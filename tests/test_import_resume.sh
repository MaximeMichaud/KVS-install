#!/bin/bash
# shellcheck disable=SC2034,SC2329  # Helpers consume the fixture globals/stubs.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/native-import.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import-resume.sh"
TEST_DIR=$(mktemp -d /tmp/kvs-resume-unit.XXXXXX)
trap 'rm -rf -- "$TEST_DIR"' EXIT
TOKEN=20260926T230000Z-a1b2c3d4
OTHER_TOKEN=20260926T230001Z-a1b2c3d4
fail() { echo "FAIL: $*" >&2; exit 1; }
reject() {
    if "$@" > "$TEST_DIR/rejected.out" 2> "$TEST_DIR/rejected.err"; then
        fail "unexpected success: $*"
    fi
}
fixture() {
    rm -rf "$TEST_DIR/init"
    mkdir "$TEST_DIR/init"
    {
        echo 'SELECT 1;'
        echo 'SET autocommit=1;'
        printf "INSERT INTO \`ktvs_options\` (variable, value) VALUES ('KVS_INSTALL_IMPORT', '%s') ON DUPLICATE KEY UPDATE value = VALUES(value);\n" "$TOKEN"
    } > "$TEST_DIR/init/10-kvs-import.sql"
}
discover() { import_resume_discover "$TEST_DIR/init" new-site.example ktvs_; }

fixture
import_dump_cat() { fail 'discovery decoded the dump'; }
discover
[ "$IMPORT_STAGED_DUMP" = "$TEST_DIR/init/10-kvs-import.sql" ] || fail 'staged filename'
[ "$IMPORT_DB_DUMP" = "$IMPORT_STAGED_DUMP" ] || fail 'unexpected raw source'
[ -z "$IMPORT_NATIVE_STAGE" ] && [ -z "$IMPORT_DUMP_TABLES" ] || fail 'SQL discovery needs no full scan'
[ "$(import_resume_token "$IMPORT_STAGED_DUMP")" = "$TOKEN" ] || fail 'plain SQL marker'
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"

for compression in gz xz zst; do
    fixture
    case "$compression" in
        gz) gzip "$TEST_DIR/init/10-kvs-import.sql" ;;
        xz) xz "$TEST_DIR/init/10-kvs-import.sql" ;;
        zst) zstd -q --rm "$TEST_DIR/init/10-kvs-import.sql" ;;
    esac
    discover
    [ "$(import_resume_token "$IMPORT_STAGED_DUMP")" = "$TOKEN" ] || fail "$compression marker"
done

# A finished database can still require a long read of an older compressed
# dump. Show immediate and periodic status on stderr while stdout stays empty
# until the complete, checksum-verified token is available.
import_dump_cat() {
    sleep 7
    command zstd -dc -- "$1"
}
scan_started=$SECONDS
TMPDIR="$TEST_DIR" import_resume_token "$IMPORT_STAGED_DUMP" > "$TEST_DIR/slow.token" 2> "$TEST_DIR/slow.progress" &
scan_call=$!
for ((attempt = 0; attempt < 20; attempt++)); do
    if grep -q 'Checking staged dump: 0:00:00 elapsed' "$TEST_DIR/slow.progress"; then break; fi
    sleep 0.1
done
[ "$((SECONDS - scan_started))" -le 2 ] || fail 'dump checking status was not immediate'
grep -q 'Checking staged dump: 0:00:00 elapsed' "$TEST_DIR/slow.progress" || fail 'missing immediate dump checking status'
[ ! -s "$TEST_DIR/slow.token" ] || fail 'stdout exposed status or an unverified token'
wait "$scan_call"
[ "$(cat "$TEST_DIR/slow.token")" = "$TOKEN" ] || fail 'scan progress contaminated the captured token'
awk '
    /Checking staged dump:/ {
        split($4, elapsed, ":")
        seconds=elapsed[1]*3600+elapsed[2]*60+elapsed[3]
        if (count && seconds-last>5) bad=1
        last=seconds; count++
    }
    END { if (bad || count<3) exit 1 }
' "$TEST_DIR/slow.progress" || fail 'slow decoder had no regular progress within five seconds'
grep -q 'no SQL is replayed' "$TEST_DIR/slow.progress" || fail 'dump checking status describes the wrong phase'
if compgen -G "$TEST_DIR/kvs-resume-token.*" >/dev/null; then fail 'successful scan left its token directory'; fi

# Interrupt the actual scanning shell, then check its isolated decoder group
# and timer have gone away. The dump and captured stdout must stay untouched.
import_dump_cat() {
    local worker scanner sleeper decoder=$BASHPID
    worker=$(ps -o ppid= -p "$decoder" | tr -d ' ')
    scanner=$(ps -o ppid= -p "$worker" | tr -d ' ')
    sleep 60 &
    sleeper=$!
    printf '%s %s %s %s\n' "$scanner" "$worker" "$decoder" "$sleeper" > "$TEST_DIR/interrupt.pids"
    wait "$sleeper"
}
TMPDIR="$TEST_DIR" import_resume_token "$IMPORT_STAGED_DUMP" > "$TEST_DIR/interrupt.token" 2> "$TEST_DIR/interrupt.progress" &
scan_call=$!
for ((attempt = 0; attempt < 30; attempt++)); do
    [ ! -s "$TEST_DIR/interrupt.pids" ] || break
    sleep 0.1
done
[ -s "$TEST_DIR/interrupt.pids" ] || fail 'interruptible decoder did not start'
read -r scanner worker decoder sleeper < "$TEST_DIR/interrupt.pids"
mapfile -t scanner_children < <(ps -o pid= --ppid "$scanner" | tr -d ' ')
kill -TERM "$scanner"
if wait "$scan_call"; then fail 'interrupted scan succeeded'; fi
[ ! -s "$TEST_DIR/interrupt.token" ] || fail 'interrupted scan exposed a token'
for process in "$scanner" "$worker" "$decoder" "$sleeper" "${scanner_children[@]}"; do
    state=$(ps -o stat= -p "$process") || state=''
    case "$state" in ''|Z*) ;; *) fail "interrupted scan left process $process running ($state)" ;; esac
done
if compgen -G "$TEST_DIR/kvs-resume-token.*" >/dev/null; then fail 'interrupted scan left its token directory'; fi
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"

# A decoder that produces the last line but fails its checksum must not expose
# a token, even when setup.sh itself did not enable pipefail.
import_dump_cat() {
    printf "INSERT INTO \`ktvs_options\` (variable, value) VALUES ('KVS_INSTALL_IMPORT', '%s') ON DUPLICATE KEY UPDATE value = VALUES(value);\n" "$TOKEN"
    return 1
}
reject import_resume_token "$IMPORT_STAGED_DUMP"
[ ! -s "$TEST_DIR/rejected.out" ] || fail 'damaged stream exposed a token'
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"

fixture
gzip "$TEST_DIR/init/10-kvs-import.sql"
truncate -s -4 "$TEST_DIR/init/10-kvs-import.sql.gz"
discover
reject import_resume_token "$IMPORT_STAGED_DUMP"
[ ! -s "$TEST_DIR/rejected.out" ] || fail 'truncated gzip exposed a token'

fixture
cp "$TEST_DIR/init/10-kvs-import.sql" "$TEST_DIR/init/20-kvs-import.sql"
reject discover
fixture
rm "$TEST_DIR/init/10-kvs-import.sql"
reject discover
fixture
mv "$TEST_DIR/init/10-kvs-import.sql" "$TEST_DIR/elsewhere.sql"
ln -s "$TEST_DIR/elsewhere.sql" "$TEST_DIR/init/10-kvs-import.sql"
reject discover
fixture
reject import_resume_discover "$TEST_DIR/init" ../other ktvs_
reject import_resume_discover "$TEST_DIR/init" new-site.example 'ktvs_;DROP'
discover
printf '\n' >> "$IMPORT_STAGED_DUMP"
reject import_resume_token "$IMPORT_STAGED_DUMP"
grep -q 'changed during recovery' "$TEST_DIR/rejected.err" || fail 'missing artifact replacement diagnostic'

for mutation in wrong_prefix invalid_token later_statement missing_marker; do
    fixture
    case "$mutation" in
        wrong_prefix) sed -i 's/ktvs_options/other_options/' "$TEST_DIR/init/10-kvs-import.sql" ;;
        invalid_token) sed -i "s/$TOKEN/not-an-import-token/" "$TEST_DIR/init/10-kvs-import.sql" ;;
        later_statement) echo 'SELECT 2;' >> "$TEST_DIR/init/10-kvs-import.sql" ;;
        missing_marker) sed -i '$d' "$TEST_DIR/init/10-kvs-import.sql" ;;
    esac
    discover
    reject import_resume_token "$IMPORT_STAGED_DUMP"
done

# An older staged dump without SET autocommit remains eligible only if the
# exact marker can actually be read back from the database after TCP readiness.
fixture
sed -i '/SET autocommit/d' "$TEST_DIR/init/10-kvs-import.sql"
discover
[ "$(import_resume_token "$IMPORT_STAGED_DUMP")" = "$TOKEN" ] || fail 'legacy staged finalizer'
MOCK_DB_MARKER=$TOKEN
MOCK_DB_STATUS=0
database_root_query() {
    printf '%s\n' "$@" > "$TEST_DIR/query.args"
    [ "$MOCK_DB_STATUS" = 0 ] || return "$MOCK_DB_STATUS"
    printf '%s\n' "$MOCK_DB_MARKER"
}
import_resume_verify new-site.example ktvs_ "$TOKEN"
grep -qx -- '--protocol=tcp' "$TEST_DIR/query.args" || fail 'verification did not require TCP'
grep -qx -- '--database=new-site.example' "$TEST_DIR/query.args" || fail 'wrong destination database'
grep -q '^SELECT value FROM ' "$TEST_DIR/query.args" || fail 'verification did not read the marker'
if grep -Eq 'DELETE|UPDATE|INSERT|REPLACE' "$TEST_DIR/query.args"; then fail 'verification mutated the database'; fi
MOCK_DB_MARKER=$OTHER_TOKEN
reject import_resume_verify new-site.example ktvs_ "$TOKEN"
grep -q 'does not match' "$TEST_DIR/rejected.err" || fail 'missing mismatch diagnostic'
MOCK_DB_MARKER=''
reject import_resume_verify new-site.example ktvs_ "$TOKEN"
grep -q 'uncommitted' "$TEST_DIR/rejected.err" || fail 'legacy transaction ambiguity not explained'
MOCK_DB_MARKER=$TOKEN$'\n'$TOKEN
reject import_resume_marker new-site.example ktvs_
MOCK_DB_STATUS=1
reject import_resume_marker new-site.example ktvs_

fixture
mkdir -p "$TEST_DIR/init/10-kvs-import-native/data/new-site.example"
mv "$TEST_DIR/init/10-kvs-import.sql" "$TEST_DIR/init/10-kvs-import-native/finalize.sql"
printf 'exit 91 # This hook must never be executed by recovery.\n' > "$TEST_DIR/init/10-kvs-import-native.sh"
cat > "$TEST_DIR/init/10-kvs-import-native/kvs-native-export.manifest" <<'MANIFEST'
format=1
complete=yes
source_database=old_source
tables_prefix=ktvs_
kvs_version=7.0.2
tables=2
MANIFEST
discover
[ "$IMPORT_DUMP_TABLES" = 2 ] || fail 'native table count'
[ "$(import_resume_token "$IMPORT_STAGED_DUMP")" = "$TOKEN" ] || fail 'native finalization token'
reject import_resume_discover "$TEST_DIR/init" another-site.example ktvs_
reject import_resume_discover "$TEST_DIR/init" new-site.example other_
rm "$TEST_DIR/init/10-kvs-import-native.sh"
reject discover
echo 'PASS: import recovery discovers the original artifact without decoding, verifies its final marker and never changes the database.'
