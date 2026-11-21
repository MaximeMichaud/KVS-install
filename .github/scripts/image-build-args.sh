#!/usr/bin/env bash
# Write the build arguments for one workflow matrix entry.
set -euo pipefail

# A failed lookup or a floating tag stops the build before any argument is
# written: the Dockerfile would otherwise fall back to its default base.
pinned_base() {
    local base
    base=$(./docker/bin/resolve-bases.sh --get "$1" "$2") || return 1
    if [[ ! "$base" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
        echo "Expected a SHA-256 pin for $1 $2 in the image lock" >&2
        return 1
    fi
    printf '%s\n' "$base"
}

args=()
if [ -n "$PHP_SERIES" ]; then
    php_base=$(pinned_base "$BASE_NAME" "$PHP_SERIES")
    debian_base=$(pinned_base debian -)
    args=("PHP_VERSION=$PHP_SERIES" "PHP_BASE=$php_base" "DEBIAN_BASE=$debian_base")
fi
printf '%s\n' 'value<<ARGS_EOF' "${args[@]}" 'ARGS_EOF' >> "$GITHUB_OUTPUT"
