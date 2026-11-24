#!/bin/bash
# tests/run.sh runs every suite, the ones after a failing suite too, lists
# the suites that failed and fails then. It runs here on copies, next to
# suites written for the case.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# make_run <case> <suite>=<status>...: a tests directory with run.sh and
# suites that record that they ran, in order, and end with that status.
make_run() {
    local dir="$TEST_DIR/$1" suite
    shift

    mkdir "$dir"
    cp "$ROOT_DIR/tests/run.sh" "$dir/run.sh"
    for suite in "$@"; do
        printf '#!/bin/bash\necho "%s" >> "%s/ran"\necho "output of %s"\nexit %s\n' \
            "${suite%=*}" "$dir" "${suite%=*}" "${suite#*=}" > "$dir/${suite%=*}"
        chmod +x "$dir/${suite%=*}"
    done
    : > "$dir/ran"
    status=0
    "$dir/run.sh" > "$dir/out" 2> "$dir/err" || status=$?
    CASE_DIR=$dir
}

# The second of four suites fails, and so does the last one, the integration
# suite run.sh names: all four run, in order, the two are listed with their
# status and the run fails without saying that all passed.
make_run failures test_a.sh=0 test_b.sh=3 test_c.sh=0 integration_cloudflare_realip.sh=7
[ "$(paste -sd ' ' "$CASE_DIR/ran")" = 'test_a.sh test_b.sh test_c.sh integration_cloudflare_realip.sh' ] ||
    fail "the suites after a failing one did not all run, in order: $(paste -sd ' ' "$CASE_DIR/ran")"
[ "$status" -eq 1 ] || fail "a run with failing suites ended with status $status"
expected='FAILED: test_b.sh (status 3)
FAILED: integration_cloudflare_realip.sh (status 7)
2 of 4 hardening test suites failed:
  test_b.sh (status 3)
  integration_cloudflare_realip.sh (status 7)'
[ "$(cat "$CASE_DIR/err")" = "$expected" ] ||
    fail "the failing suites were not listed with their status: $(cat "$CASE_DIR/err")"
if grep -Fq 'passed' "$CASE_DIR/out"; then
    fail "a run with failing suites said that the suites passed"
fi
for suite in test_a.sh test_b.sh test_c.sh integration_cloudflare_realip.sh; do
    if ! grep -Fxq "Running $suite" "$CASE_DIR/out" || ! grep -Fxq "output of $suite" "$CASE_DIR/out"; then
        fail "the run did not announce $suite and show its output"
    fi
done
echo "PASS: every suite runs after a failing one, and the run lists the failures and fails"

# One failing suite among passing ones is enough to fail the run, whichever
# it is, the first included.
make_run first test_a.sh=2 test_b.sh=0 integration_cloudflare_realip.sh=0
[ "$status" -eq 1 ] && [ "$(wc -l < "$CASE_DIR/ran")" -eq 3 ] ||
    fail "a first failing suite gave status $status after $(wc -l < "$CASE_DIR/ran") suites"
grep -Fxq '1 of 3 hardening test suites failed:' "$CASE_DIR/err" ||
    fail "a single failing suite was not counted: $(cat "$CASE_DIR/err")"
echo "PASS: a single failing suite fails the run"

# Suites that all pass: status 0, nothing on standard error.
make_run passing test_a.sh=0 test_b.sh=0 integration_cloudflare_realip.sh=0
[ "$status" -eq 0 ] || fail "a run of passing suites ended with status $status: $(cat "$CASE_DIR/err")"
[ "$(tail -n 1 "$CASE_DIR/out")" = 'All hardening test suites passed' ] && [ ! -s "$CASE_DIR/err" ] ||
    fail "a run of passing suites did not say so: $(cat "$CASE_DIR/out" "$CASE_DIR/err")"
[ "$(wc -l < "$CASE_DIR/ran")" -eq 3 ] || fail "a passing run did not run its three suites"
echo "PASS: a run of passing suites says so and succeeds"

# Exercise both nginx import modes, the TLS build prerequisite, a missing
# suite and a later passing suite without using a Docker daemon.
dir=$TEST_DIR/integration
mkdir -p "$dir/tests" "$dir/bin"
ln -s "$ROOT_DIR/docker" "$dir/docker"
cp "$ROOT_DIR/tests/run-integration.sh" "$dir/tests/"
cat > "$dir/bin/docker" <<'DOCKER'
#!/bin/bash
case "$1 $2" in
    'info '|'image inspect'|'image rm') exit 0 ;;
    'build --quiet') exit 8 ;;
    *) exit 99 ;;
esac
DOCKER
cat > "$dir/tests/integration_nginx_import.sh" <<'IMPORT'
#!/bin/bash
echo "import $NGINX_IMPORT_TEST_MODE"
[[ $NGINX_IMPORT_TEST_MODE != file ]] || exit 3
IMPORT
echo 'raise SystemExit(9)' > "$dir/tests/integration_internal_tls.py"
echo 'print("last suite ran")' > "$dir/tests/last.py"
chmod +x "$dir/bin/docker" "$dir/tests/integration_nginx_import.sh"
status=0
PATH="$dir/bin:$PATH" "$dir/tests/run-integration.sh" integration_nginx_import.sh \
    integration_internal_tls.py missing.sh last.py > "$dir/out" 2> "$dir/err" || status=$?
[[ $status == 1 ]] || fail "integration runner returned $status"
if ! grep -Fxq 'import source' "$dir/out" || ! grep -Fxq 'last suite ran' "$dir/out"; then
    fail "integration runner skipped later cases"
fi
for failure in 'integration_nginx_import.sh (file) (status 3)' 'integration_internal_tls.py (status 8)' 'missing.sh (status 1)'; do
    grep -Fxq "  $failure" "$dir/err" || fail "missing integration failure: $failure"
done
grep -Fxq 'All integration suites passed' "$dir/out" && fail "integration failures reported as success"
PATH="$dir/bin:$PATH" "$dir/tests/run-integration.sh" last.py > "$dir/out"
grep -Fxq 'All integration suites passed' "$dir/out" || fail "passing integration run"
echo 'PASS: integration runner continues after failures and preserves their status'
