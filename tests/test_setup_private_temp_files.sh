#!/bin/bash
# log_command and run_step of docker/setup.sh kept a command's output in
# /tmp/log_cmd_<pid>.log and /tmp/run_step_<pid>.log, and detect_ioncube
# extracted the archive into /tmp/kvs-detect-<pid>: names another local
# user could guess, create or link beforehand, and files the 022 umask made
# readable to everyone. They are now made by mktemp in TMPDIR, so each run
# gets files of its own that only root reads. The test plants the old names
# for the PID of the run, a link to a victim file and a directory holding
# a forged PHP file, and checks that the setup uses neither.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kvs-private-temp.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

extract_function() {
    awk -v signature="$1() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$ROOT_DIR/docker/setup.sh"
}
for name in report_step_failure log_command run_step remove_env_value set_env_value detect_ioncube; do
    extract_function "$name" >> "$WORK/functions.sh"
    grep -q "^${name}() {" "$WORK/functions.sh" || fail "$name is not defined in docker/setup.sh"
done

# A gum that runs the command after --, as gum spin does.
mkdir -p "$WORK/gum-bin"
cat > "$WORK/gum-bin/gum" <<'GUM'
#!/bin/bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
GUM
chmod 755 "$WORK/gum-bin/gum"

# run_case <name> <gum dir or empty> <snippet>: the snippet runs in a
# shell that first plants, for its own PID, the names the setup used to
# take in /tmp: links to victim files, and a directory with a PHP file
# that looks ionCube encoded. TMPDIR is the case's own directory.
run_case() {
    local name=$1 gum_dir=$2 snippet=$3 dir="$WORK/$1"
    mkdir -p "$dir/tmp" "$dir/work/kvs-archive"
    : > "$dir/victim-run"
    : > "$dir/victim-log"
    : > "$dir/debug.log"
    # shellcheck disable=SC2016
    (cd "$dir/work" && PATH="${gum_dir:+$gum_dir:}/usr/bin:/bin" TMPDIR="$dir/tmp" DEBUG_LOG="$dir/debug.log" \
        CASE="$dir" bash -c '
            planted=("/tmp/run_step_$$.log" "/tmp/log_cmd_$$.log" "/tmp/kvs-detect-$$")
            trap '\''rm -rf "${planted[@]}"'\'' EXIT
            rm -rf "${planted[@]}"
            ln -s "$CASE/victim-run" "/tmp/run_step_$$.log"
            ln -s "$CASE/victim-log" "/tmp/log_cmd_$$.log"
            mkdir "/tmp/kvs-detect-$$"
            printf "<?php //0046b\nif(!extension_loaded('\''ionCube Loader'\'')){die();}\n" > "/tmp/kvs-detect-$$/functions_base.php"
            RED="" GREEN="" YELLOW="" CYAN="" NC=""
            source "$1"
            eval "$2"
            echo "rc=$?"
            if [ -f "/tmp/kvs-detect-$$/functions_base.php" ]; then echo planted-dir-kept; fi
            if [ -L "/tmp/run_step_$$.log" ] && [ -L "/tmp/log_cmd_$$.log" ]; then echo planted-links-kept; fi
        ' _ "$WORK/functions.sh" "$snippet" < /dev/null) > "$dir/out" 2>&1
}

no_leftovers() {
    [ -z "$(find "$WORK/$1/tmp" -mindepth 1)" ] || fail "$1: temporary files were left: $(ls -A "$WORK/$1/tmp")"
    grep -qx 'planted-links-kept' "$WORK/$1/out" || fail "$1: a planted /tmp name was removed or replaced"
    [ ! -s "$WORK/$1/victim-run" ] || fail "$1: the output went through a planted /tmp/run_step_<pid>.log: $(cat "$WORK/$1/victim-run")"
    [ ! -s "$WORK/$1/victim-log" ] || fail "$1: the output went through a planted /tmp/log_cmd_<pid>.log: $(cat "$WORK/$1/victim-log")"
}

# The step prints the mode of the file its output goes to.
# shellcheck disable=SC2016
step='sh -c '\''echo step-output; stat -L -c "mode=%a" /proc/self/fd/1'\'

for gum in without with; do
    gum_dir=''
    [ "$gum" = without ] || gum_dir="$WORK/gum-bin"
    run_case "run-step-$gum-gum" "$gum_dir" "run_step 'A step' $step"
    grep -qx 'rc=0' "$WORK/run-step-$gum-gum/out" || fail "run_step $gum gum must succeed: $(cat "$WORK/run-step-$gum-gum/out")"
    grep -qx 'step-output' "$WORK/run-step-$gum-gum/debug.log" || fail "run_step $gum gum must keep the output in the debug log: $(cat "$WORK/run-step-$gum-gum/debug.log")"
    grep -qx 'mode=600' "$WORK/run-step-$gum-gum/debug.log" || fail "run_step $gum gum must write to a file only root reads: $(cat "$WORK/run-step-$gum-gum/debug.log")"
    no_leftovers "run-step-$gum-gum"
    pass "run_step $gum gum keeps the output in a private file of its own"
done

# A failed step still shows its last lines.
run_case run-step-failed '' "run_step 'A failing step' sh -c 'echo the-cause; exit 3'"
grep -qx 'rc=1' "$WORK/run-step-failed/out" || fail "a failed step must fail run_step: $(cat "$WORK/run-step-failed/out")"
grep -q 'the-cause' "$WORK/run-step-failed/out" || fail "a failed step must show its last lines: $(cat "$WORK/run-step-failed/out")"
no_leftovers run-step-failed
pass "a failed step still shows its last lines"

run_case log-command '' "log_command $step"
grep -qx 'rc=0' "$WORK/log-command/out" || fail "log_command must succeed: $(cat "$WORK/log-command/out")"
grep -qx 'step-output' "$WORK/log-command/debug.log" || fail "log_command must keep the output in the debug log: $(cat "$WORK/log-command/debug.log")"
grep -qx 'mode=600' "$WORK/log-command/debug.log" || fail "log_command must write to a file only root reads: $(cat "$WORK/log-command/debug.log")"
no_leftovers log-command
pass "log_command keeps the output in a private file of its own"

# The archive holds a plain functions_base.php; the planted directory an
# encoded one. The detection reads the archive and leaves the directory.
mkdir -p "$WORK/stage/admin/include"
printf '<?php\nfunction kvs_base() { return 1; }\n' > "$WORK/stage/admin/include/functions_base.php"
(cd "$WORK/stage" && zip -q -r "$WORK/KVS_7.0.2.zip" admin) || fail "the test needs zip"
mkdir -p "$WORK/detect/work/kvs-archive"
cp "$WORK/KVS_7.0.2.zip" "$WORK/detect/work/kvs-archive/"
printf 'IONCUBE=YES\n' > "$WORK/detect/work/.env"
run_case detect '' "IMPORT_SITE_IONCUBE='' detect_ioncube '$WORK/no-site'"
grep -qx 'rc=0' "$WORK/detect/out" || fail "the detection must succeed: $(cat "$WORK/detect/out")"
grep -qx 'IONCUBE=NO' "$WORK/detect/work/.env" || fail "the detection must read the archive, not a planted file: $(cat "$WORK/detect/out")"
grep -qx 'planted-dir-kept' "$WORK/detect/out" || fail "the detection must leave a directory it did not make"
no_leftovers detect
pass "the IonCube detection extracts into a private directory of its own"

# Without a temporary directory, the detection stops: it must not extract
# the archive where it stands.
mkdir -p "$WORK/detect-no-tmp/work/kvs-archive"
cp "$WORK/KVS_7.0.2.zip" "$WORK/detect-no-tmp/work/kvs-archive/"
printf 'IONCUBE=YES\n' > "$WORK/detect-no-tmp/work/.env"
run_case detect-no-tmp '' "TMPDIR='$WORK/detect-no-tmp/missing' IMPORT_SITE_IONCUBE='' detect_ioncube '$WORK/no-site'"
grep -qx 'rc=0' "$WORK/detect-no-tmp/out" && fail "the detection must fail without a temporary directory: $(cat "$WORK/detect-no-tmp/out")"
[ ! -e "$WORK/detect-no-tmp/work/functions_base.php" ] || fail "the detection extracted the archive into the docker directory"
grep -qx 'IONCUBE=YES' "$WORK/detect-no-tmp/work/.env" || fail "a failed detection must keep the saved setting"
pass "the IonCube detection stops when it cannot make its directory"
