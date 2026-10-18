#!/usr/bin/env bash
set -euo pipefail
if ! command -v php > /dev/null; then
    echo "SKIP: PHP is needed to check the cache migration parser"
    exit 0
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 "$root/tests/cache_config_cases.py"
