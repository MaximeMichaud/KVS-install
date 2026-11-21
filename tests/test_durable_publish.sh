#!/bin/bash
# shellcheck disable=SC2015  # Any failed part of an assertion must call fail.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/sync" <<'SH'
#!/bin/bash
set -eu
if [ "${1:-}" = --help ]; then
    echo probe >> probes
    case $LEGACY in reject) exit 1 ;; ignore|yes) exit 0 ;; esac
    echo '  -f, --file-system'
    exit 0
fi
if [ "$LEGACY" != no ]; then
    if [ "$LEGACY" != ignore ]; then [ "$#" -eq 0 ] || exit 13; fi
    if [ -e renamed ]; then phase=directory; else phase=file; fi
else
    if [ "$#" = 0 ]; then echo global >> events; [ "$FAIL_AT" != fallback ]; exit; fi
    [ "$#" = 2 ] && [ "$1" = -- ] || exit 14
    if [ -d "$2" ]; then
        [ "$2" -ef "$(dirname -- "$TARGET")" ] || exit 15
        phase=directory
    else
        # The exact inode and final contents that will be published.
        stat -c %i -- "$2" > synced-inode
        cmp -s -- expected "$2" || exit 16
        phase=file
    fi
fi
echo "$phase" >> events
if [ "$phase" = directory ] && [ "$LEGACY" = no ]; then
    [ "${LC_ALL:-}" = C ] || exit 20
    case $FAIL_AT in
        invalid|fallback) echo "sync: $2: Invalid argument" >&2; exit 1 ;;
        unsupported) echo "sync: $2: Operation not supported" >&2; exit 1 ;;
        not-supported) echo "sync: $2: Not supported" >&2; exit 1 ;;
        directory) echo "sync: $2: Input/output error" >&2; exit 1 ;;
    esac
fi
if [ "$phase" = file ] && [ "$FAIL_AT" = file ]; then echo 'sync: file: Invalid argument' >&2; exit 1; fi
[ "$FAIL_AT" != "$phase" ]
SH
cat > "$work/bin/mv" <<'SH'
#!/bin/bash
set -eu
args=("$@")
src=${args[${#args[@]}-2]}
dst=${args[${#args[@]}-1]}
[ "$dst" = "$TARGET" ] || exit 17
if [ "$LEGACY" = no ]; then
    [ "$(stat -c %i -- "$src")" = "$(cat synced-inode)" ] || exit 18
fi
echo rename >> events
[ "$FAIL_AT" != rename ] || exit 19
/usr/bin/mv "$@"
touch renamed
SH
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=/dev/null
source <(sed -n '/^env_sync_failed() {/,/^}/p; /^remove_env_value() {/,/^}/p; /^set_env_value() {/,/^}/p' "$root/docker/setup.sh")
# shellcheck source=/dev/null
source <(sed -n '/^kvs_publish_export() {/,/^}/p; /^kvs_copy_export_permissions() {/,/^}/p; /^kvs_dirname() {/,/^}/p' "$root/kvs-export.sh")
# shellcheck disable=SC2329  # Called by the export function on failure.
kvs_error() { echo "$*" >&2; }
exercise() (
    local kind=$1
    export LEGACY=$2 FAIL_AT=$3 TARGET
    mkdir -p "$work/$kind-$LEGACY-$FAIL_AT/parent dir/stage"
    cd "$work/$kind-$LEGACY-$FAIL_AT"
    echo KEEP=value > original
    cp original expected
    case $kind in
        remove) TARGET='parent dir/settings'; echo OLD=value >> original ;;
        export) TARGET='parent dir/output'; echo complete > expected; cp expected 'parent dir/stage/file' ;;
        *) TARGET=.env; echo NEW=old >> original; echo NEW=value >> expected ;;
    esac
    cp original "$TARGET"
    : > events
    status=0
    case $kind in
        set|reconfigure) set_env_value NEW value || status=$? ;;
        remove) remove_env_value OLD "$TARGET" || status=$? ;;
        export) kvs_publish_export 'parent dir/stage/file' "$TARGET" 'parent dir' || status=$? ;;
    esac 2> notice
    case $FAIL_AT in
        none) sequence=$'file\nrename\ndirectory'; [ "$status" = 0 ] || fail "$kind failed" ;;
        invalid|unsupported|not-supported|fallback)
            sequence=$'file\nrename\ndirectory\nglobal'
            if [ "$FAIL_AT" != fallback ]; then [ "$status" = 0 ] || fail "$kind refused $FAIL_AT"; fi ;;
        file) sequence='file' ;;
        rename) sequence=$'file\nrename' ;;
        directory) sequence=$'file\nrename\ndirectory' ;;
    esac
    if [ "$LEGACY" != no ]; then
        case $FAIL_AT in
            none) sequence=$'rename\ndirectory' ;;
            rename) sequence=rename ;;
            directory) sequence=$'rename\ndirectory' ;;
        esac
    fi
    case $FAIL_AT in
        directory|fallback)
            [ "$status" != 0 ] && grep -Fq 'in place but its durability is not confirmed' notice ||
                fail "$kind ignored $FAIL_AT or did not explain publication" ;;
        file|rename) [ "$status" != 0 ] || fail "$kind ignored $FAIL_AT failure" ;;
    esac
    [ "$(cat events)" = "$sequence" ] || fail "$kind ($LEGACY, $FAIL_AT): $(cat events)"
    if [ "$LEGACY" != no ] && [ "$kind" != export ] && [ "$FAIL_AT" = none ]; then
        for _ in 1 2 3 4 5; do
            rm -f renamed
            cp original "$TARGET"
            if [ "$kind" = remove ]; then remove_env_value OLD "$TARGET"; else set_env_value NEW value; fi
        done
        [ "$(wc -l < probes)" = 1 ] && [ "$(grep -c '^directory$' events)" = 6 ] &&
            [ "$(wc -l < events)" = 12 ] || fail "$kind repeated legacy flushes or probes"
    fi
    case $FAIL_AT in
        none|directory|invalid|unsupported|not-supported|fallback) cmp -s expected "$TARGET" || fail "$kind published the wrong contents" ;;
        *) cmp -s original "$TARGET" || fail "$kind lost the previous file" ;;
    esac
)
for kind in set remove export reconfigure; do
    if [ "$kind" = reconfigure ]; then
        # shellcheck source=/dev/null
        source <(sed -n '/^set_env_value() {/,/^}/p' "$root/docker/reconfigure.sh")
    fi
    for fault in none file rename directory invalid unsupported not-supported fallback; do
        exercise "$kind" no "$fault"
        case $fault in
            none|rename|directory)
                exercise "$kind" reject "$fault"
                exercise "$kind" ignore "$fault" ;;
        esac
    done
done
echo 'Durable publication ordering and failure handling passed.'
