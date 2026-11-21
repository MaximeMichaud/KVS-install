#!/usr/bin/env bash
# Print the build arguments for one entry of the image matrix.
set -euo pipefail

if [ -n "$PHP_SERIES" ]; then
    base=$(./docker/bin/resolve-bases.sh --get "$BASE_NAME" "$PHP_SERIES")
    if [[ ! "$base" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
        echo "Expected a SHA-256 pin for $BASE_NAME $PHP_SERIES in the image lock" >&2
        exit 1
    fi
fi

echo 'value<<ARGS_EOF'
if [ -n "$PHP_SERIES" ]; then
    printf 'PHP_VERSION=%s\nPHP_BASE=%s\n' "$PHP_SERIES" "$base"
fi
echo 'ARGS_EOF'
