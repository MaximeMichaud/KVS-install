#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for test_script in "$TEST_DIR"/test_*.sh; do
    echo "Running $(basename "$test_script")"
    "$test_script"
done

echo "All hardening test suites passed"
