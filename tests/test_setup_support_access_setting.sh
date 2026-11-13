#!/bin/bash
# X1: the KVS support access opt-out setup exports to kvs-init must be the
# value the shell gets from sourcing .env (the last line wins, an export
# prefix, indentation, quotes, a trailing comment and a reference to another
# variable are accepted, as Compose accepts them), or the explicit request of
# this run.
# A second reader of .env took the first plain line instead: with the
# template's DISABLE_KVS_SUPPORT_ACCESS=false followed by =true, an export
# line or a quoted value, setup exported false while Compose alone read
# true, and DISABLE_KVS_SUPPORT_ACCESS=true over an export line was turned
# into false. Support access stays enabled when nothing asks otherwise.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETUP="$ROOT_DIR/docker/setup.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-support-access.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

passed=0
pass() { passed=$((passed + 1)); echo "ok $passed - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

for name in remove_env_value set_env_value resolve_support_access_setting; do
    awk -v signature="$name() {" '$0 == signature { capture = 1 } capture { print } capture && /^}$/ { exit }' "$SETUP"
done > "$TEST_DIR/functions.sh"
grep -q '^resolve_support_access_setting() {$' "$TEST_DIR/functions.sh" ||
    fail 'setup.sh has no resolve_support_access_setting'
grep -qx 'resolve_support_access_setting || exit 1' "$SETUP" ||
    fail 'setup.sh does not apply resolve_support_access_setting'
if grep -q "s/^DISABLE_KVS_SUPPORT_ACCESS=" "$SETUP"; then
    fail 'setup.sh still re-reads DISABLE_KVS_SUPPORT_ACCESS from .env with sed'
fi

compose=false
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    compose=true
elif [ -n "${CI:-}" ]; then
    fail 'docker compose is needed for the Compose cross-check'
fi

# What kvs-init gets from Compose, with or without the value setup exports.
compose_value() {
    local dir="$1" exported="$2"
    local -a value=(-u DISABLE_KVS_SUPPORT_ACCESS)
    [ -z "$exported" ] || value=(DISABLE_KVS_SUPPORT_ACCESS="$exported")
    (
        cd "$dir"
        env -u COMPOSE_FILE -u COMPOSE_PROFILES -u COMPOSE_PROJECT_NAME -u COMPOSE_ENV_FILES "${value[@]}" \
            docker compose --env-file .env --profile setup -f "$ROOT_DIR/docker/docker-compose.yml" config --format json
    ) | python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["kvs-init"]["environment"]["DISABLE_KVS_SUPPORT_ACCESS"])'
}

# run_setting <dir> [request]: the part of setup.sh from the two reads of .env
# to the export, with the request captured from the environment beforehand.
run_setting() {
    local dir="$1" request="${2:-}"
    (
        cd "$dir"
        unset DISABLE_KVS_SUPPORT_ACCESS
        # shellcheck disable=SC2034 # read by the functions taken from setup.sh
        RED='' NC=''
        # shellcheck disable=SC2034 # setup.sh captures it before sourcing .env
        DISABLE_KVS_SUPPORT_ACCESS_REQUEST=$request
        # shellcheck source=/dev/null
        source "$TEST_DIR/functions.sh"
        # shellcheck source=/dev/null
        source .env
        # shellcheck source=/dev/null
        source .env
        resolve_support_access_setting || exit 1
        [ "$(bash -c 'printf %s "$DISABLE_KVS_SUPPORT_ACCESS"')" = "$DISABLE_KVS_SUPPORT_ACCESS" ] ||
            { echo 'not exported'; exit 1; }
        printf '%s\n' "$DISABLE_KVS_SUPPORT_ACCESS"
    )
}

# check <case> <lines appended to the template .env> <request> <expected>
check() {
    local name="$1" lines="$2" request="$3" expected="$4" dir got alone
    dir="$TEST_DIR/$name"
    mkdir -p "$dir"
    cp "$ROOT_DIR/docker/.env.example" "$dir/.env"
    printf '%b' "$lines" >> "$dir/.env"
    got=$(run_setting "$dir" "$request") || fail "$name: setup refused the setting: $got"
    [ "$got" = "$expected" ] || fail "$name: setup exports '$got', expected '$expected'"
    if [ "$compose" = true ]; then
        alone=$(compose_value "$dir" '')
        [ "$alone" = "$expected" ] || fail "$name: Compose alone reads '$alone' from the saved .env, setup exports '$got'"
        [ "$(compose_value "$dir" "$got")" = "$expected" ] || fail "$name: kvs-init does not get '$expected'"
    fi
    # The next run, with no request, keeps the same value.
    got=$(run_setting "$dir" '') || fail "$name: the next run refused the setting: $got"
    [ "$got" = "$expected" ] || fail "$name: the next run exports '$got', expected '$expected'"
    pass "$name: setup and Compose both give '$expected'"
}

check template-only '' '' false
check appended-true 'DISABLE_KVS_SUPPORT_ACCESS=true\n' '' true
check export-line 'export DISABLE_KVS_SUPPORT_ACCESS=true\n' '' true
check quoted 'DISABLE_KVS_SUPPORT_ACCESS="true"\n' '' true
check indented '  DISABLE_KVS_SUPPORT_ACCESS=true\n' '' true
check export-two-spaces 'export  DISABLE_KVS_SUPPORT_ACCESS=true\n' '' true
check trailing-comment 'DISABLE_KVS_SUPPORT_ACCESS=true # no support access\n' '' true
# shellcheck disable=SC2016 # the reference is for .env to expand, not this shell
check variable-reference 'KVS_SUPPORT_OFF=true\nDISABLE_KVS_SUPPORT_ACCESS=${KVS_SUPPORT_OFF}\n' '' true
check request-true-over-export 'export DISABLE_KVS_SUPPORT_ACCESS=false\n' true true
check request-false-over-export 'export DISABLE_KVS_SUPPORT_ACCESS=true\n' false false

# An explicit request leaves one line, with the export prefix it found.
lines=$(grep -c 'DISABLE_KVS_SUPPORT_ACCESS=' "$TEST_DIR/request-true-over-export/.env")
[ "$lines" -eq 1 ] || fail "the request left $lines DISABLE_KVS_SUPPORT_ACCESS lines in .env"
grep -qx 'export DISABLE_KVS_SUPPORT_ACCESS=true' "$TEST_DIR/request-true-over-export/.env" ||
    fail 'the request was not saved as one export line'
pass 'an explicit request is saved as the only line'

# Without any line, support access stays enabled and .env is not touched.
mkdir -p "$TEST_DIR/no-line"
grep -v 'DISABLE_KVS_SUPPORT_ACCESS' "$ROOT_DIR/docker/.env.example" > "$TEST_DIR/no-line/.env"
cp "$TEST_DIR/no-line/.env" "$TEST_DIR/no-line.before"
got=$(run_setting "$TEST_DIR/no-line" '')
[ "$got" = false ] || fail "no line: setup exports '$got', expected false"
cmp -s "$TEST_DIR/no-line/.env" "$TEST_DIR/no-line.before" || fail 'no line: .env was changed'
pass 'no line and no request: support access stays enabled, .env untouched'

# A value that is neither true nor false stops the run.
mkdir -p "$TEST_DIR/invalid"
cp "$ROOT_DIR/docker/.env.example" "$TEST_DIR/invalid/.env"
echo 'DISABLE_KVS_SUPPORT_ACCESS=yes' >> "$TEST_DIR/invalid/.env"
if out=$(run_setting "$TEST_DIR/invalid" '' 2>&1); then
    fail "an invalid saved value was accepted: $out"
fi
[[ "$out" == *'DISABLE_KVS_SUPPORT_ACCESS in .env must be true or false'* ]] ||
    fail "the refusal does not say why: $out"
pass 'an invalid saved value stops the run'

# A line ending in CRLF is one Compose reads as true while the shell keeps
# the carriage return: the run stops rather than export another value.
mkdir -p "$TEST_DIR/crlf"
cp "$ROOT_DIR/docker/.env.example" "$TEST_DIR/crlf/.env"
printf 'DISABLE_KVS_SUPPORT_ACCESS=true\r\n' >> "$TEST_DIR/crlf/.env"
if out=$(run_setting "$TEST_DIR/crlf" '' 2>&1); then
    fail "a CRLF line was accepted: $(printf %q "$out")"
fi
[[ "$out" == *'DISABLE_KVS_SUPPORT_ACCESS in .env must be true or false'* ]] ||
    fail "the CRLF refusal does not say why: $out"
pass 'a CRLF line stops the run'

echo "PASS: KVS support access setting ($passed checks)"
