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
remote_bin=""
import_ssh() {
    printf '%s\n' "$*" >> "$TEST_DIR/login-shell.log"
    PATH="${remote_bin:+$remote_bin:}$PATH" "$login_shell" -c "$*"
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
    run_fallback "$dest" "/$name" || fail "$login_shell, $remote_tar_kind tar, $2: the transfer failed: $(cat "$TEST_DIR/out")"
    [ -f "$dest/index.php" ] || fail "$login_shell, $remote_tar_kind tar, $2: the site files did not come through: $(cat "$TEST_DIR/out")"
    [ ! -e "$dest/$name" ] || fail "$login_shell, $remote_tar_kind tar, $2: the excluded directory came through"
    rm -rf "${site:?}/$name"
}

# literal <name> <sibling> <case>: tar reads an exclude as a wildcard unless
# told otherwise, where [1] matches the character 1 and a backslash escapes
# the next one: the name alone stays behind, the sibling such a reading
# would match comes through.
literal() {
    local name="$1" sibling="$2" dest="$TEST_DIR/dest"
    mkdir -p "$site/$sibling"
    printf 'kept\n' > "$site/$sibling/kept.txt"
    excluded "$name" "$3"
    [ -f "$dest/$sibling/kept.txt" ] || fail "$login_shell, $remote_tar_kind tar, $3: '$sibling' must not be read as matching '$name'"
    rm -rf "${site:?}/$sibling"
}

# children <name> <sibling> <case>: what is under the name stays behind,
# the name itself and a sibling a wildcard reading would match come through.
children() {
    local name="$1" sibling="$2" dest="$TEST_DIR/dest"
    mkdir -p "$site/$name" "$site/$sibling"
    printf 'left\n' > "$site/$name/left.txt"
    printf 'kept\n' > "$site/$sibling/kept.txt"
    run_fallback "$dest" "/$name/*" || fail "$login_shell, $remote_tar_kind tar, $3: the transfer failed: $(cat "$TEST_DIR/out")"
    [ -d "$dest/$name" ] && [ ! -e "$dest/$name/left.txt" ] || fail "$login_shell, $remote_tar_kind tar, $3: what is under '$name' must stay behind, the directory must come"
    [ -f "$dest/$sibling/kept.txt" ] || fail "$login_shell, $remote_tar_kind tar, $3: '$sibling' must not be read as matching '$name'"
    rm -rf "${site:?}/$name" "${site:?}/$sibling"
}

# The tar of the old server, first on its PATH only: the one of this host
# (GNU), a tar that stops on the GNU-only matching options and reads every
# exclude as a wildcard pattern, as BusyBox does, and BusyBox itself where
# this host has one. The local side always unpacks with the tar of this host.
real_tar=$(command -v tar)
mkdir -p "$TEST_DIR/plain-tar"
cat > "$TEST_DIR/plain-tar/tar" <<STUB
#!/bin/sh
[ "\$1" != --version ] || { echo "BusyBox tar: unrecognized option '--version'" >&2; exit 1; }
for word in "\$@"; do
    case "\$word" in
        --wildcards | --no-wildcards | --anchored | --no-anchored)
            echo "tar: unrecognized option '\$word'" >&2
            exit 1
            ;;
    esac
done
exec "$real_tar" "\$@"
STUB
chmod +x "$TEST_DIR/plain-tar/tar"
mkdir -p "$TEST_DIR/status-tar"
cat > "$TEST_DIR/status-tar/tar" <<STUB
#!/bin/sh
case "\$1" in --version) echo "\${TEST_TAR_VERSION:-BusyBox tar}"; exit 0 ;; esac
for word do
    case "\$word" in
        "$site") touch "$TEST_DIR/site-opened" ;;
        --exclude=*) [ "\${TEST_NO_EXCLUDE:-no}" = no ] || exit 1 ;;
    esac
done
"$real_tar" "\$@" || exit
exit "\${TEST_TAR_STATUS:-0}"
STUB
chmod +x "$TEST_DIR/status-tar/tar"
remote_bin="$TEST_DIR/status-tar"
if TEST_TAR_STATUS=1 import_remote_files "$site" "$TEST_DIR/status-dest" no > "$TEST_DIR/out" 2>&1; then
    fail "status 1 of BusyBox tar accepted on a readable stream"
fi
grep -q 'ended with status 1' "$TEST_DIR/out" || fail "remote tar status missing"
grep -q 'BusyBox tar also returns 1.*install rsync on the old server' "$TEST_DIR/out" || fail "missing BusyBox retry advice"
TEST_TAR_VERSION='GNU tar' TEST_TAR_STATUS=1 import_remote_files "$site" "$TEST_DIR/status-dest" no > "$TEST_DIR/out" 2>&1 ||
    fail "status 1 of GNU tar refused"
grep -q 'changed or vanished' "$TEST_DIR/out" || fail "missing live-site notice"
if TEST_TAR_STATUS=42 import_remote_files "$site" "$TEST_DIR/status-dest" no > "$TEST_DIR/out" 2>&1; then
    fail "ordinary tar error used the reserved GNU status"
fi
(
    import_ssh() { return 255; }
    if import_remote_files "$site" "$TEST_DIR/status-dest" no > "$TEST_DIR/out" 2>&1; then fail "SSH failure accepted"; fi
    grep -q 'status 255' "$TEST_DIR/out" || fail "missing SSH failure diagnostic"
)
(
    tar() { cat >/dev/null; return 23; }
    rc=0
    TEST_TAR_VERSION='GNU tar' TEST_TAR_STATUS=1 import_remote_files "$site" "$TEST_DIR/status-dest" no > "$TEST_DIR/out" 2>&1 || rc=$?
    [ "$rc" = 23 ] || fail "GNU warning masked the local extractor status"
)
rm -f "$TEST_DIR/site-opened"
if TEST_NO_EXCLUDE=yes run_fallback "$TEST_DIR/status-dest" /tmp; then
    fail "tar without --exclude accepted"
fi
grep -q 'cannot.*--exclude' "$TEST_DIR/out" || fail "missing exclude diagnostic"
[ ! -e "$TEST_DIR/site-opened" ] || fail "tar opened the site before checking its options"

# A tar named gtar is an alternative only when it identifies itself as GNU.
ln -s tar "$remote_bin/gtar"
TEST_TAR_VERSION=bsdtar import_remote_files "$site" "$TEST_DIR/status-dest" no > "$TEST_DIR/out" 2>&1 ||
    fail "tar without exclusions must still transfer the site"
rm -f "$TEST_DIR/site-opened"
if TEST_TAR_VERSION=bsdtar run_fallback "$TEST_DIR/status-dest" /tmp; then
    fail "bsdtar accepted with a site exclusion"
fi
grep -q 'bsdtar.*tmp and compiled templates.*GNU tar or BusyBox tar.*gtar.*install rsync on the old server' "$TEST_DIR/out" || fail "missing tar implementation diagnostic"
[ ! -e "$TEST_DIR/site-opened" ] || fail "bsdtar opened the excluded site"

ln -sf "$real_tar" "$remote_bin/gtar"
TEST_TAR_STATUS=9 TEST_TAR_VERSION=bsdtar run_fallback "$TEST_DIR/gtar-dest" /tmp || fail "GNU gtar did not replace bsdtar"
cmp "$site/index.php" "$TEST_DIR/gtar-dest/index.php" || fail "gtar did not transfer the site"
[ ! -e "$TEST_DIR/site-opened" ] || fail "bsdtar opened the site despite GNU gtar"
rm "$remote_bin/gtar"

# Each tar accepts the option but implements a different wrong match.
mkdir -p "$TEST_DIR/mismatch"
cat > "$TEST_DIR/mismatch/tar" <<'STUB'
#!/bin/bash
args=()
for arg do
    if [[ "$arg" = --exclude=* ]]; then arg="--exclude=$TEST_PATTERN"; fi
    args+=("$arg")
done
exec "$REAL_TAR" "${args[@]}"
STUB
chmod +x "$TEST_DIR/mismatch/tar"
remote_bin="$TEST_DIR/mismatch"
for pattern in './missing/*' './tmp' '*/tmp/*'; do
    if REAL_TAR="$real_tar" TEST_PATTERN="$pattern" run_fallback "$TEST_DIR/mismatch-dest" /tmp; then
        fail "accepted incorrect exclusion behavior for $pattern"
    fi
    grep -q 'cannot apply --exclude' "$TEST_DIR/out" || fail "missing matching diagnostic"
    [ ! -e "$TEST_DIR/mismatch-dest" ] || fail "created the destination before probing tar"
done

# GNU tar, with the words it was run with: it must keep the command line it
# always had, with the name as it is under --no-wildcards.
mkdir -p "$TEST_DIR/gnu-tar"
cat > "$TEST_DIR/gnu-tar/tar" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$TEST_DIR/gnu-tar.log"
exec "$real_tar" "\$@"
STUB
chmod +x "$TEST_DIR/gnu-tar/tar"
tars=(gnu plain)
busybox=""
for candidate in "$(command -v busybox 2>/dev/null || true)" /usr/lib/initramfs-tools/bin/busybox /usr/lib/initcpio/busybox; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" tar --help 2>&1 | grep -q -- '--exclude'; then
        busybox=$candidate
        mkdir -p "$TEST_DIR/busybox-tar"
        ln -s "$busybox" "$TEST_DIR/busybox-tar/tar"
        tars+=(busybox)
        break
    fi
done

shells=(bash sh)
if command -v fish > /dev/null 2>&1; then
    shells+=(fish)
fi
for remote_tar_kind in "${tars[@]}"; do
    remote_bin="$TEST_DIR/$remote_tar_kind-tar"
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
        excluded '.back\slash' "a name with a backslash"
        excluded '.ends\' "a name ending in a backslash"
        literal '.c[1]' '.c1' "a name with brackets"
        literal '.st*r' '.star' "a name with an asterisk"
        literal '.q?' '.qx' "a name with a question mark"
        literal '.b\x' '.bx' "a backslash before a plain character"
        children '.st*r' '.star' "the entries under a name with an asterisk"
        # The login shell saw no data from the old server.
        while IFS= read -r words; do
            [ "$words" = "sh -s" ] || fail "$login_shell: the login shell was handed more than sh -s: $words"
        done < "$TEST_DIR/login-shell.log"
        [ -s "$TEST_DIR/login-shell.log" ] || fail "$login_shell: the transfer never reached the old server"
    done
    if [ "$remote_tar_kind" = gnu ]; then
        grep -Fq -- "--no-wildcards --exclude=./.c[1] -chf - ." "$TEST_DIR/gnu-tar.log" || fail "GNU tar must get a name as it is, under --no-wildcards"
        grep -Fq -- "--wildcards --exclude=./.st\*r/* -chf - ." "$TEST_DIR/gnu-tar.log" || fail "GNU tar must get the entries of a directory under --wildcards"
        ! grep -- ' -chf - \.$' "$TEST_DIR/gnu-tar.log" | grep -v -- '-wildcards --exclude=' | grep -q . || fail "GNU tar was run without its matching options"
    fi
done

echo "PASS: the tar fallback hands the old server's login shell only sh -s, and excludes every name, literally (${shells[*]}; old server tar: ${tars[*]})"
