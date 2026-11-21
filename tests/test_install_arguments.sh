#!/bin/bash
# shellcheck disable=SC1091,SC2329
set -eo pipefail
source "$(dirname "$0")/../kvs-install.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Stub every main step after argument parsing, including opening the root
# log. Only an actual install request may reach any of them.
initialize_runtime_defaults() { echo defaults >> "$work/effects"; }
initialize_runtime_output() { echo log >> "$work/effects"; }
initialize_runtime_input() { echo input >> "$work/effects"; }
initialCheck() { echo checks >> "$work/effects"; }
manageMenu() { echo "install [${SETUP_ARGS[*]}]" >> "$work/effects"; }
chooseInstallationType() { manageMenu; }
run() {
    rm -f "$work/effects"
    status=0
    (main "$@") > "$work/out" 2> "$work/err" || status=$?
}
for option in -h --help; do
    run "$option"
    [[ ! -e "$work/effects" ]] || fail "$option started initialization"
    [[ $status == 0 && ! -s "$work/err" ]] || fail "$option should succeed"
    grep -iq 'usage:.*kvs-install.sh' "$work/out" || fail "$option lacks usage"
    grep -q -- '--dev' "$work/out" || fail "missing supported option"
done
for argument in --bogus -x 'unexpected operand'; do
    for help in before after; do
        if [[ $help == before ]]; then run --help "$argument"; else run "$argument" --help; fi
        [[ $status == 2 && ! -e "$work/effects" ]] || fail "accepted $argument with help"
        grep -Fq -- "$argument" "$work/err" || fail "missing diagnostic for $argument"
    done
    run "$argument"
    [[ $status == 2 && ! -e "$work/effects" ]] || fail "accepted $argument"
done
run
[[ $status == 0 ]] || fail "plain install failed"
grep -qxF 'install []' "$work/effects" || fail "plain install changed"
run --dev
[[ $status == 0 ]] || fail "development install failed"
grep -qxF 'install [--dev]' "$work/effects" || fail "--dev was not forwarded"
echo 'ok - installer arguments are checked before initialization'
