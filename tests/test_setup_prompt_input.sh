#!/bin/bash
# Complete lines answer interactive confirmations, including an empty line.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed -n -e '/^prompt_read() {/,/^}/p' -e '/^import_files_only() {/,/^}/p' \
    -e '/^import_confirm() {/,/^}/p' "$root/docker/setup.sh" > "$tmp/prompts"
cat >> "$tmp/prompts" <<'BASH'
DOMAIN=example.test PREVIOUS_DOMAIN='' RED='' CYAN='' NC='' GREEN=''
IMPORT_DATABASE_FORMAT_REQUEST=auto
import_validate_site() { :; }
import_inspect_remote() { :; }
import_fetch_remote() { echo transfer; exit 0; }
if [ "$2" = conditional ]; then
    if "$1"; then echo transfer; fi
else
    "$1"
    echo transfer
fi
BASH
for prompt in import_confirm import_files_only; do
    for caller in direct conditional; do
        for input in '' y n; do
            status=0
            printf '%s' "$input" | bash -e "$tmp/prompts" "$prompt" "$caller" > "$tmp/log" 2>&1 || status=$?
            if [ "$status" != 1 ] || ! grep -Fq 'no answer left on standard input' "$tmp/log" || grep -q transfer "$tmp/log"; then
                echo "FAIL: $prompt ($caller) accepted incomplete input or omitted its diagnostic" >&2
                exit 1
            fi
        done
        printf '\n' | bash -e "$tmp/prompts" "$prompt" "$caller" | grep -q transfer
        HEADLESS=y bash -e "$tmp/prompts" "$prompt" "$caller" </dev/null | grep -q transfer
        printf 'n\n' | bash -e "$tmp/prompts" "$prompt" "$caller" > "$tmp/log"
        if grep -q transfer "$tmp/log"; then exit 1; fi
    done
done

# Only standalone reads immediately following an interactive prompt.
if awk '/^[[:space:]]*echo -n / { prompt=1; next }
    prompt && /^[[:space:]]*read -r([[:space:]]+[[:alnum:]_]+)?$/ {print NR ": " $0; found=1}
    {prompt=0}
    END {exit !found}' "$root/docker/setup.sh"; then
    echo 'FAIL: interactive prompt bypasses prompt_read' >&2
    exit 1
fi
echo 'PASS: complete answers, EOF and headless confirmations'
