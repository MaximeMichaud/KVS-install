#!/bin/bash
# The tar fallback of import_remote_files runs tar on the old server through
# ssh, which joins the words of the remote command and lets the SSH user's
# login shell split them again. That shell may not be POSIX: fish reads \'
# inside single quotes as a quote, so a quoted --exclude built from a name on
# the old server could still close early there. The fallback must hand the
# login shell nothing but "sh -s", the tar command, quoted for sh, on its
# standard input, and every excluded name, whatever bytes it holds, must stay
# out of the transfer.
# shellcheck disable=SC1003,SC2016,SC2034,SC2329  # Names hold literal quotes, backslashes and dollars.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-import-quoting.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# The old server's login shell, run locally: it gets the joined words, as
# from ssh, and its standard input. A command the quoting failed to contain
# leaves a trace here; the words it saw are logged.
login_shell=bash
import_ssh() {
    printf '%s\n' "$*" >> "$TEST_DIR/login-shell.log"
    "$login_shell" -c "$*"
}
IMPORT_REMOTE_PREFIX=()
IMPORT_SSH_TARGET=old-server

site="$TEST_DIR/site"
mkdir -p "$site"
printf 'keep\n' > "$site/index.php"
marker="$TEST_DIR/PWNED"

run_fallback() {
    local dest="$1" pattern="$2"
    rm -rf "$dest"
    # The count and plan helpers are not reached on the tar path; the pipe runs
    # tar on $site through the stub and extracts it into $dest.
    import_remote_files "$site" "$dest" no "$pattern" > "$TEST_DIR/out" 2>&1
}

# excluded <name> <case>: a directory of that name, with a file in it, is
# left out of the transfer while the rest of the site comes through.
excluded() {
    local name="$1" dest="$TEST_DIR/dest"
    mkdir -p "$site/$name"
    printf 'secret\n' > "$site/$name/secret.txt"
    run_fallback "$dest" "/$name" || fail "$login_shell, $2: the transfer failed: $(cat "$TEST_DIR/out")"
    [ -f "$dest/index.php" ] || fail "$login_shell, $2: the site files did not come through: $(cat "$TEST_DIR/out")"
    [ ! -e "$dest/$name" ] || fail "$login_shell, $2: the excluded directory came through"
    rm -rf "${site:?}/$name"
}

# carried <name> <case>: an exclude of that name does not break the transfer.
# tar reads its excludes as wildcards, where a backslash escapes the next
# character, so such a name is not matched exactly; it must still be passed
# intact and harm nothing.
carried() {
    local name="$1" dest="$TEST_DIR/dest"
    mkdir -p "$site/$name"
    run_fallback "$dest" "/$name" || fail "$login_shell, $2: the transfer failed: $(cat "$TEST_DIR/out")"
    [ -f "$dest/index.php" ] || fail "$login_shell, $2: the site files did not come through: $(cat "$TEST_DIR/out")"
    rm -rf "${site:?}/$name"
}

shells=(bash sh)
if command -v fish > /dev/null 2>&1; then
    shells+=(fish)
fi
for login_shell in "${shells[@]}"; do
    rm -f "$marker" "$TEST_DIR/login-shell.log"
    # Injection, POSIX style and fish style: no command runs on the old server.
    run_fallback "$TEST_DIR/d1" "/.a';touch $marker;'" || true
    [ ! -e "$marker" ] || fail "$login_shell: a crafted exclude ran a command on the old server"
    run_fallback "$TEST_DIR/d2" "/.a\\';touch $marker;#" || true
    [ ! -e "$marker" ] || fail "$login_shell: a crafted exclude with a backslash ran a command on the old server"
    [ -f "$TEST_DIR/d2/index.php" ] || fail "$login_shell: the transfer did not carry the site files: $(cat "$TEST_DIR/out")"
    # Names the exclusion must still match exactly.
    excluded ".cache" "a plain name"
    excluded ".o'brien" "a name with a quote"
    excluded '.dollar$(touch X)`id`;#!' "a name with shell expansions"
    excluded '.two  spaces	tab' "a name with spaces and a tab"
    excluded '.-dash' "a name with a dash"
    carried '.back\slash' "a name with a backslash"
    carried '.ends\' "a name ending in a backslash"
    # The login shell saw no data from the old server.
    while IFS= read -r words; do
        [ "$words" = "sh -s" ] || fail "$login_shell: the login shell was handed more than sh -s: $words"
    done < "$TEST_DIR/login-shell.log"
    [ -s "$TEST_DIR/login-shell.log" ] || fail "$login_shell: the transfer never reached the old server"
done

echo "PASS: the tar fallback hands the old server's login shell only sh -s, and excludes every name (${shells[*]})"
