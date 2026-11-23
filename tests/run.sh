#!/bin/bash
# Runs every suite, also after one of them failed: a run that stopped at the
# first failure said nothing about the suites after it, and each further
# failure took a run of its own to find. The suites that failed are listed
# at the end, and the status is then 1.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

suites=(
    "$TEST_DIR"/test_*.sh
    "$TEST_DIR/integration_cloudflare_realip.sh"
)
failed=()

for test_script in "${suites[@]}"; do
    name=$(basename "$test_script")
    echo "Running $name"
    status=0
    "$test_script" || status=$?
    if [ "$status" -ne 0 ]; then
        echo "FAILED: $name (status $status)" >&2
        failed+=("$name (status $status)")
    fi
done

if [ "${#failed[@]}" -ne 0 ]; then
    echo "${#failed[@]} of ${#suites[@]} hardening test suites failed:" >&2
    printf '  %s\n' "${failed[@]}" >&2
    exit 1
fi

echo "All hardening test suites passed"
