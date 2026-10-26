#!/bin/bash
# shellcheck disable=SC2034  # Variables are consumed by the extracted production functions.
# The manticore-data volume keeps its indexes when setup imports a database
# or starts a fresh one, and when search was off for a while, and a start
# that finds them serves them at once. Setup must ask Manticore to build
# them from the database first, and only then start it; a kept database
# that kept search on keeps its indexes. The need is written to .env when
# it arises, so a run that stops before Manticore starts leaves it to the
# next run.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETUP="$ROOT_DIR/docker/setup.sh"
TEST_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

extract_function() {
    local name="$1" file="${2:-$SETUP}"

    awk -v signature="${name}() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$file"
}

# The request runs on a resume too, where the functions setup.sh defines
# between its "if [ "$RESUME_IMPORT" != true ]" and the else that resumes
# the import do not exist: its harness holds only what a resume has.
mkdir -p "$TEST_DIR/lib" "$TEST_DIR/bin" "$TEST_DIR/site"
cp "$ROOT_DIR/docker/lib/manticore.sh" "$TEST_DIR/lib/"
request_harness="$TEST_DIR/request.sh"
{
    echo "log_command() { \"\$@\"; }"
    extract_function database_docker_query "$ROOT_DIR/docker/lib/database.sh"
    extract_function setup_resume_docker_query
    extract_function remove_env_value
    extract_function setup_request_manticore_rebuild
} > "$request_harness"
for name in setup_request_manticore_rebuild setup_resume_docker_query; do
    grep -q "^${name}() {" "$request_harness" || fail "$name not found in setup.sh"
done
# The questionnaire adds the search choice and the database note, with the
# helpers they write .env with.
questions_harness="$TEST_DIR/questions.sh"
{
    echo "RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''; SITE_PREFIX=kvs-test"
    for name in set_env_value remove_env_value add_compose_profile remove_compose_profile \
        select_manticore setup_select_manticore setup_note_manticore_rebuild; do
        extract_function "$name"
    done
} > "$questions_harness"
for name in setup_select_manticore setup_note_manticore_rebuild select_manticore set_env_value remove_env_value; do
    grep -q "^${name}() {" "$questions_harness" || fail "$name not found in setup.sh"
done
# Compose lists the images of the service and of the services it depends
# on: the database's comes with Manticore's.
cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_ROOT/calls"
case "$*" in
    'compose --profile manticore config --images manticore') printf '%s\n' kvs-test-manticore mariadb:11.8 ;;
    'image inspect --format {{.Id}} kvs-test-manticore') [ "${TEST_IMAGE_MISSING:-no}" != yes ] ;;
    *) [ "${TEST_DOCKER_FAILURE:-no}" != yes ] ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/docker"
export TEST_ROOT="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH"

request_calls=$(printf '%s\n' \
    'compose --profile manticore run --rm --no-deps -T --entrypoint touch manticore /var/lib/manticore/kvs-rebuild-before-start' \
    'compose --profile manticore rm --stop --force manticore')
image_calls=$(printf '%s\n' \
    'compose --profile manticore config --images manticore' \
    'image inspect --format {{.Id}} kvs-test-manticore' \
    'image inspect --format {{.Id}} mariadb:11.8')

# The .env of the site in $TEST_DIR/site, one line per argument.
write_env() {
    printf '%s\n' 'DOMAIN=example.com' 'COMPOSE_PROFILES=redis' "$@" > "$TEST_DIR/site/.env"
    chmod 600 "$TEST_DIR/site/.env"
}
pending() { grep -Fxq 'MANTICORE_REBUILD_PENDING=true' "$TEST_DIR/site/.env"; }

# Runs the request the way setup.sh does at Step 6, under set -e in its own
# shell, from the site directory.
run_request() {
    rm -f "$TEST_DIR/calls"
    (cd "$TEST_DIR/site" && bash -c 'set -e; source "$1"; ENABLE_MANTICORE="$2"; IMPORT_MODE="$3"; RESUME_IMPORT="$4"; setup_request_manticore_rebuild' \
        _ "$request_harness" "$@") > "$TEST_DIR/out" 2>&1
}

# What Docker saw against what the case expects.
check_calls() {
    local description="$1" expected="$2"

    case "$expected" in
        requested)
            [ "$(cat "$TEST_DIR/calls" 2>/dev/null)" = "$request_calls" ] ||
                fail "$description: expected the rebuild request, Docker saw: $(cat "$TEST_DIR/calls" 2>/dev/null)"
            ;;
        checked-and-requested)
            [ "$(cat "$TEST_DIR/calls" 2>/dev/null)" = "$(printf '%s\n%s' "$image_calls" "$request_calls")" ] ||
                fail "$description: expected the image check, then the rebuild request, Docker saw: $(cat "$TEST_DIR/calls" 2>/dev/null)"
            ;;
        kept)
            [ ! -e "$TEST_DIR/calls" ] ||
                fail "$description: no rebuild may be requested, Docker saw: $(cat "$TEST_DIR/calls")"
            ;;
    esac
}

run_case() {
    local description="$1" expected="$2" status=0
    shift 2

    run_request "$@" || status=$?
    [ "$status" -eq 0 ] || fail "$description: the request exited $status: $(cat "$TEST_DIR/out")"
    check_calls "$description" "$expected"
    if pending; then fail "$description: the note in .env outlived the request"; fi
    echo "PASS: $description"
}

#                                                                          expected               enabled import resume
write_env 'ENABLE_MANTICORE=true' 'MANTICORE_REBUILD_PENDING=true'
run_case "a database .env says the indexes no longer match gets indexes built from it" \
                                                                           requested              true    false  false
write_env 'ENABLE_MANTICORE=true'
run_case "an imported database gets indexes built from it"                requested              true    true   false
write_env 'ENABLE_MANTICORE=true'
run_case "a kept database that kept search on keeps its indexes"          kept                   true    false  false
write_env 'ENABLE_MANTICORE=false'
run_case "search turned off asks nothing of Manticore"                     kept                   false   true   false
write_env 'ENABLE_MANTICORE=true'
run_case "a resumed import gets indexes built from it, with the image of the interrupted run" \
                                                                           checked-and-requested  true    true   true

# A resumed import whose Manticore image is gone stops there: Compose run
# would build it, which a resume never does. The note stays for the next run.
write_env 'ENABLE_MANTICORE=true' 'MANTICORE_REBUILD_PENDING=true'
if TEST_IMAGE_MISSING=yes run_request true true true; then
    fail "a resumed import requested the rebuild without the image of the interrupted run"
fi
[ "$(cat "$TEST_DIR/calls")" = "$(printf '%s\n' "$image_calls" | head -n 2)" ] ||
    fail "a resumed import without its Manticore image ran more than the image check: $(cat "$TEST_DIR/calls")"
grep -Fq 'an image built before the import is unavailable (kvs-test-manticore)' "$TEST_DIR/out" ||
    fail "a resumed import without its Manticore image did not say so: $(cat "$TEST_DIR/out")"
pending || fail "a resumed import that could not ask for the rebuild dropped the note"
echo "PASS: a resumed import never builds the Manticore image"

# A request that fails stops the setup before Manticore starts, and leaves
# the note.
write_env 'ENABLE_MANTICORE=true' 'MANTICORE_REBUILD_PENDING=true'
if TEST_DOCKER_FAILURE=yes run_request true false false; then
    fail "a failed rebuild request was accepted"
fi
pending || fail "a failed rebuild request dropped the note"
call_line=$(grep -n '^if ! setup_request_manticore_rebuild; then$' "$SETUP" | cut -d: -f1)
start_line=$(grep -n '^if setup_start_runtime_services; then$' "$SETUP" | cut -d: -f1)
[ -n "$call_line" ] && [ -n "$start_line" ] && [ "$call_line" -lt "$start_line" ] ||
    fail "setup must request the rebuild before it starts the runtime services"
sed -n "$((call_line + 1)),$((call_line + 4))p" "$SETUP" | grep -Fxq '    exit 1' ||
    fail "setup must stop when the rebuild cannot be requested"
echo "PASS: a request that fails stops the setup and keeps the note"

# Runs of setup, each in its own shell from the site directory: the search
# choice, the database question's outcome, then either a stop before Step 6
# or the request of Step 6. $1 is MANTICORE_CHOICE (empty: none given), $2
# KEEP_EXISTING_DB, $3 IMPORT_MODE, $4 stop or step6.
setup_run() {
    rm -f "$TEST_DIR/calls"
    (cd "$TEST_DIR/site" && bash -c '
        set -e
        unset ENABLE_MANTICORE MANTICORE_REBUILD_PENDING
        source "$1"
        source "$2"
        set -a
        source .env
        set +a
        HEADLESS=y
        MANTICORE_CHOICE=$3
        setup_select_manticore > /dev/null
        KEEP_EXISTING_DB=$4
        IMPORT_MODE=$5
        setup_note_manticore_rebuild
        [ "$6" = step6 ] || exit 3
        rm -f "$TEST_ROOT/calls"
        RESUME_IMPORT=false
        setup_request_manticore_rebuild
    ' _ "$questions_harness" "$request_harness" "$@") > "$TEST_DIR/out" 2>&1
}

# A run that stops between the change and Step 6 (an image build, the
# MariaDB start, the KVS init or the certificate failed), then a run that
# keeps that database and changes nothing: Step 6 of the second run asks
# for the rebuild the first one needed, once, and a third run does not.
interrupted_case() {
    local description="$1" saved="$2" choice="$3" keep="$4" import="$5" status=0

    write_env "$saved"
    setup_run "$choice" "$keep" "$import" stop || status=$?
    [ "$status" -eq 3 ] || fail "$description: the first run exited $status: $(cat "$TEST_DIR/out")"
    grep -Fxq 'ENABLE_MANTICORE=true' "$TEST_DIR/site/.env" ||
        fail "$description: the first run did not switch search on: $(cat "$TEST_DIR/site/.env")"
    pending || fail "$description: the first run stopped without writing the need to .env"
    setup_run '' true false step6 || fail "$description: the rerun failed: $(cat "$TEST_DIR/out")"
    check_calls "$description, then a rerun that keeps the database" requested
    if pending; then fail "$description: the note outlived the request of the rerun"; fi
    setup_run '' true false step6 || fail "$description: the third run failed: $(cat "$TEST_DIR/out")"
    check_calls "$description, then a third run" kept
    echo "PASS: $description"
}

interrupted_case "search switched on again over a kept database, by a run that stopped before Step 6" \
    'ENABLE_MANTICORE=false' 1 true false
interrupted_case "search switched on over a kept database whose .env never had the setting, by a run that stopped before Step 6" \
    '' 1 true false
interrupted_case "a fresh database started by a run that stopped before Step 6" \
    'ENABLE_MANTICORE=true' '' false false
interrupted_case "an import by a run that stopped before Step 6, the staged dump removed afterwards" \
    'ENABLE_MANTICORE=true' '' false true

# The uninterrupted runs: switching search on asks at once; a run that keeps
# the database and the search setting asks nothing and writes nothing.
write_env 'ENABLE_MANTICORE=false'
setup_run 1 true false step6 || fail "a run that switches search on failed: $(cat "$TEST_DIR/out")"
check_calls "a run that switches search on over a kept database" requested
if pending; then fail "a run that switches search on left the note after its request"; fi
write_env 'ENABLE_MANTICORE=true'
setup_run '' true false step6 || fail "a run that keeps everything failed: $(cat "$TEST_DIR/out")"
check_calls "a run that keeps the database and search on" kept
if pending; then fail "a run that keeps the database and search on wrote a note"; fi
echo "PASS: a run that changes nothing keeps the indexes"

# Search switched off drops a note an earlier run left: switching it on
# again writes a new one, so nothing is lost. A fresh install that leaves
# search off writes none.
write_env 'ENABLE_MANTICORE=true' 'MANTICORE_REBUILD_PENDING=true'
setup_run 2 false false step6 || fail "a run that switches search off failed: $(cat "$TEST_DIR/out")"
check_calls "a run that switches search off" kept
if pending; then fail "a run that switches search off kept the note"; fi
grep -Fxq 'ENABLE_MANTICORE=false' "$TEST_DIR/site/.env" || fail "search was not switched off"
write_env
setup_run '' false false step6 || fail "a fresh install with search off failed: $(cat "$TEST_DIR/out")"
check_calls "a fresh install with search off" kept
if pending; then fail "a fresh install with search off wrote a note"; fi
echo "PASS: search left off writes no note"

# setup.sh runs the choice, then the note once the database question is
# answered, before an import deletes the database volume, and the request at
# Step 6. Each at the top level, once: a failure ends the setup.
line_of() {
    local lines
    lines=$(grep -n -x -F -- "$1" "$SETUP" | cut -d: -f1)
    [ "$(printf '%s\n' "$lines" | grep -c .)" = 1 ] || fail "setup.sh must run '$1' exactly once at the top level"
    printf '%s\n' "$lines"
}
select_line=$(line_of setup_select_manticore)
note_line=$(line_of setup_note_manticore_rebuild)
ask_line=$(line_of '    ask_existing_volume')
replace_line=$(line_of import_replace_database_volume)
if grep -q -x 'select_manticore' "$SETUP"; then
    fail "setup.sh asks the search question without setup_select_manticore"
fi
[ "$select_line" -lt "$ask_line" ] && [ "$ask_line" -lt "$note_line" ] &&
    [ "$note_line" -lt "$replace_line" ] && [ "$replace_line" -lt "$call_line" ] ||
    fail "setup.sh must note the search choice, then the database question's outcome before an import replaces the volume, and ask at Step 6"

# Nothing the request runs may come from the part of setup.sh a resume
# skips: from the first "if [ "$RESUME_IMPORT" != true ]" to the line that
# resumes the import instead.
# The line as setup.sh writes it.
# shellcheck disable=SC2016
resume_start=$(grep -n -x -F 'if [ "$RESUME_IMPORT" != true ]; then' "$SETUP" | head -n 1 | cut -d: -f1)
resume_line=$(awk -v from="${resume_start:-0}" 'NR > from && $0 == "    setup_resume_import" { print NR; exit }' "$SETUP")
[ -n "$resume_start" ] && [ -n "$resume_line" ] || fail "the part of setup.sh a resume skips was not found"
request_body=$(extract_function setup_request_manticore_rebuild | grep -v '^[[:space:]]*#')
while IFS= read -r name; do
    if grep -qw -- "$name" <<< "$request_body"; then
        fail "the request calls $name, which a resume does not define"
    fi
done < <(awk -v from="$resume_start" -v to="$resume_line" \
    'NR > from && NR < to && match($0, /^[A-Za-z_][A-Za-z0-9_]*\(\) \{$/) { sub(/\(\) \{$/, ""); print }' "$SETUP")
echo "PASS: setup notes each change when it happens and asks before Manticore starts, resumes included"


# The previous search state is a parsed setting. A line in another value
# cannot suppress the rebuild when search returns, and spelling true with
# quotes, export or interpolation must not restart unchanged indexes.
for state_form in quoted exported interpolated false_multiline true_multiline absent; do
    for selected_choice in 1 2 default; do
        prior_enabled=true
        expected_keep=stable
        case "$state_form" in
            quoted) saved_state="ENABLE_MANTICORE='true'" ;;
            exported) saved_state='export ENABLE_MANTICORE=true' ;;
            interpolated)
                # shellcheck disable=SC2016  # Parsed by the actual setup load.
                saved_state=$'SEARCH_SEED=true\nENABLE_MANTICORE="${SEARCH_SEED}"'
                ;;
            false_multiline)
                saved_state=$'ENABLE_MANTICORE=false\nKEEP="first\nENABLE_MANTICORE=true\nlast"'
                expected_keep=$'first\nENABLE_MANTICORE=true\nlast'
                prior_enabled=false
                ;;
            true_multiline)
                saved_state=$'ENABLE_MANTICORE=true\nKEEP="first\nENABLE_MANTICORE=false\nlast"'
                expected_keep=$'first\nENABLE_MANTICORE=false\nlast'
                ;;
            absent) saved_state=''; prior_enabled=false ;;
        esac
        choice=$selected_choice
        [ "$choice" != default ] || choice=''
        expected_enabled=false
        if [ "$choice" = 1 ] || { [ -z "$choice" ] && [ "$prior_enabled" = true ]; }; then
            expected_enabled=true
        fi
        needs_rebuild=false
        if [ "$expected_enabled" = true ] && [ "$prior_enabled" = false ]; then
            needs_rebuild=true
        fi
        write_env 'KEEP=stable' 'EXTRA=neighbor' "$saved_state"
        status=0
        setup_run "$choice" true false stop || status=$?
        [ "$status" = 3 ] || fail "$state_form/$selected_choice preparation failed: $(cat "$TEST_DIR/out")"
        if pending; then observed_pending=true; else observed_pending=false; fi
        [ "$observed_pending" = "$needs_rebuild" ] ||
            fail "$state_form/$selected_choice recorded pending=$observed_pending, expected $needs_rebuild"
        setup_run '' true false step6 || fail "$state_form/$selected_choice retry failed: $(cat "$TEST_DIR/out")"
        if [ "$needs_rebuild" = true ]; then
            check_calls "$state_form/$selected_choice rebuild after interruption" requested
        else
            check_calls "$state_form/$selected_choice unchanged indexes" kept
        fi
        if pending; then fail "$state_form/$selected_choice retained the completed request"; fi
        setup_run '' true false step6 || fail "$state_form/$selected_choice third run failed: $(cat "$TEST_DIR/out")"
        check_calls "$state_form/$selected_choice third run" kept
        # shellcheck disable=SC2016  # Only the fresh Bash process expands these.
        env -i PATH="$PATH" bash -ec 'source "$1/.env"; printf "%s\0%s\0%s" "$ENABLE_MANTICORE" "$KEEP" "$EXTRA"' \
            bash "$TEST_DIR/site" > "$TEST_DIR/saved-state"
        python3 - "$TEST_DIR/saved-state" "$expected_enabled" "$expected_keep" <<'PY'
from pathlib import Path
import sys
saved=Path(sys.argv[1]).read_text().split('\0')
assert saved==[sys.argv[2],sys.argv[3],'neighbor'],saved
PY
    done
done
echo 'PASS: parsed prior search state decides rebuilds, including interrupted and unchanged reruns'


# Once the volume has the rebuild request, clear only its saved marker.
# Fresh processes must not inherit a completed request, and unrelated
# multiline values or exported neighbors must survive the cleanup.
for marker_form in exported indented plain multiline fake_only shared_first shared_last shadow; do
    case "$marker_form" in
        exported) marker_setting='export MANTICORE_REBUILD_PENDING=true' ;;
        indented) marker_setting='  MANTICORE_REBUILD_PENDING=true' ;;
        plain|multiline) marker_setting='MANTICORE_REBUILD_PENDING=true' ;;
        fake_only) marker_setting='' ;;
        shared_first) marker_setting='export MANTICORE_REBUILD_PENDING="true" EXTRA="neighbor"' ;;
        shared_last) marker_setting='export EXTRA="neighbor" MANTICORE_REBUILD_PENDING="true"' ;;
        shadow) marker_setting=$'MANTICORE_REBUILD_PENDING=true\nSHADOW_MANTICORE_REBUILD_PENDING=true' ;;
    esac
    expected_keep=stable expected_shadow=''
    case "$marker_form" in
        multiline|fake_only)
            expected_keep='first
MANTICORE_REBUILD_PENDING=true
last'
            ;;
    esac
    [ "$marker_form" != shadow ] || expected_shadow=true
    write_env 'ENABLE_MANTICORE=true' "$marker_setting" "KEEP=\"$expected_keep\""
    case "$marker_form" in shared_*) ;; *) echo 'EXTRA=neighbor' >> "$TEST_DIR/site/.env" ;; esac
    rm -f "$TEST_DIR/calls"
    (
        cd "$TEST_DIR/site"
        # shellcheck disable=SC2016  # Expanded only by the isolated driver.
        bash -ec '
            source "$1"
            unset MANTICORE_REBUILD_PENDING
            set -a
            source .env
            set +a
            IMPORT_MODE=true RESUME_IMPORT=false
            setup_request_manticore_rebuild
            printf "%s\0%s\0" "${MANTICORE_REBUILD_PENDING+x}" "${MANTICORE_REBUILD_PENDING-}" > "$TEST_ROOT/marker-memory"
            /bin/bash -c "printf %s \"\${MANTICORE_REBUILD_PENDING+x}\"" >> "$TEST_ROOT/marker-memory"
        ' bash "$request_harness"
    ) > "$TEST_DIR/out" 2>&1 || fail "$marker_form cleanup failed: $(cat "$TEST_DIR/out")"
    check_calls "$marker_form completed marker" requested
    # shellcheck disable=SC2016  # A fresh process reads only the saved file.
    env -i PATH="$PATH" bash -ec 'source "$1/.env"; printf "%s\0%s\0%s\0%s" "${MANTICORE_REBUILD_PENDING-}" "$KEEP" "$EXTRA" "${SHADOW_MANTICORE_REBUILD_PENDING-}"' \
        bash "$TEST_DIR/site" > "$TEST_DIR/marker-saved"
    python3 - "$TEST_DIR" "$expected_keep" "$expected_shadow" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);keep,shadow=sys.argv[2:]
saved=(p/'marker-saved').read_text().split('\0')
assert saved==['',keep,'neighbor',shadow],saved
memory=(p/'marker-memory').read_text().split('\0')
assert memory==['','',''],memory
assert (p/'site/.env').stat().st_mode & 0o777==0o600
assert not list((p/'site').glob('.env.tmp.*'))
PY
done
echo 'PASS: completed rebuild markers disappear from saved settings, memory and exports without changing other values'

# Failure to persist the cleared marker must remain a failure and keep its
# loaded value, so a retry can safely request the rebuild again.
write_env 'ENABLE_MANTICORE=true' 'export MANTICORE_REBUILD_PENDING=true' 'EXTRA=neighbor'
cp "$TEST_DIR/site/.env" "$TEST_DIR/before-clear.env"
rm -f "$TEST_DIR/calls"
status=0
(
    cd "$TEST_DIR/site"
    # shellcheck disable=SC2016  # The failure oracle observes the driver's state.
    bash -ec '
        source "$1"
        set -a
        source .env
        set +a
        IMPORT_MODE=true RESUME_IMPORT=false
        remove_env_value() { return 23; }
        result=0
        setup_request_manticore_rebuild || result=$?
        printf "%s" "${MANTICORE_REBUILD_PENDING-}" > "$TEST_ROOT/failed-clear-memory"
        exit "$result"
    ' bash "$request_harness"
) > "$TEST_DIR/out" 2>&1 || status=$?
[ "$status" = 23 ] || fail "a failed marker removal returned $status instead of 23"
cmp -s "$TEST_DIR/site/.env" "$TEST_DIR/before-clear.env" || fail 'failed marker removal changed .env'
[ "$(cat "$TEST_DIR/failed-clear-memory")" = true ] || fail 'failed marker removal discarded the loaded request'
check_calls 'failed marker removal' requested
echo 'PASS: a failed marker removal keeps the saved and loaded request and returns its error'

echo "All Manticore rebuild request tests passed"
