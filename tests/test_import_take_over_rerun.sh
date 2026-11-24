#!/bin/bash
# Run the real questionnaire and fetch against an isolated tree and stub SSH.
# shellcheck disable=SC2034,SC2329  # Read or called by the extracted functions.
set -eu -o pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-take-over-rerun.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
for name in prompt_read import_save_nginx_config import_remote_size_text import_remote_free_space_check \
    import_remote_earlier_pass import_inspect_remote import_confirm select_import_source import_fetch_remote; do
    awk -v signature="$name() {" '$0 == signature { capture = 1 } capture { print } capture && /^}$/ { exit }' \
        "$ROOT_DIR/docker/setup.sh"
done | sed "s|/var/www/|$TEST_DIR/www/|g" > "$TEST_DIR/setup-functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/setup-functions.sh"
cd "$TEST_DIR" || exit 1
mkdir -p logs import www
LOG_DIR="$TEST_DIR/logs" HEADLESS=y RED='' GREEN='' YELLOW='' CYAN='' NC=''
DOMAIN=example.com IMPORT_STAGING="$TEST_DIR/import" IMPORT_MARKER_DIR="$TEST_DIR/import"
IMPORT_TRANSFER_JOBS=4 IMPORT_SIZE_TIMEOUT=300 IMPORT_REMOTE_PASSWORD=fixture
IMPORT_REMOTE_HOST=old.example.com IMPORT_REMOTE_PORT=22 IMPORT_REMOTE_USER=root IMPORT_REMOTE_DIR=''
IMPORT_SSH_KEY='' IMPORT_SSH_ACCEPT_NEW=y IMPORT_EXCLUDE='' IMPORT_INCLUDE=''
IMPORT_DATABASE_FORMAT=auto IMPORT_REMOTE_SUDO_ERROR='' IMPORT_EXPORTER="$ROOT_DIR/kvs-export.sh"
IMPORT_NGINX_REWRITES='' IMPORT_MODE=true IMPORT_REUSE_SITE_DIR="$TEST_DIR/www/dev.example.com"
import_ensure_tool() { return 0; }
import_ssh_setup() { IMPORT_SSH_TARGET=root@old.example.com; }
import_ssh_close() { return 0; }
import_remote_privileges() { IMPORT_REMOTE_PRIVILEGES=root; }
import_remote_show_entries() { return 0; }
import_remote_show_servers() { return 0; }
import_remote_show_links() { return 0; }
import_remote_load_excludes() { return 0; }
import_remote_database_space_mb() { [ "$3" = "$TEST_DIR/www/example.com" ] && echo 1; }
import_free_space_mb_ok() { [ "$1" = 1 ] && [ "$2" = "$destination" ]; }
import_remote_detect() {
    printf 'kvs_export=1\nsite_dir=/var/www/example.com\nproject_path=/var/www/example.com\nkvs_version=7.0.2\n' > "$3"
    printf 'tables_prefix=ktvs_\ndb_ok=yes\nrsync=yes\ncompressor=gzip\ndomain=example.com\n' >> "$3"
    printf 'site_size_status=exact\nsite_size_mb=999\n' >> "$3"
}
import_check_completed() { :; }
import_check_kvs_archive_version() { :; }
refuse_unbuildable_kvs_php() { echo checked-compatibility; [ "$scenario" != incompatible ]; }
import_check_domain() { :; }
import_record_source_domain() { HEADLESS=''; }
import_remote_dump() { printf dump > "$3"; }
import_remote_recheck_links() { :; }
import_remote_files() {
    [ "$2" = "$TEST_DIR/www/example.com" ] && [ "$(stat -c '%d:%i' "$2")" = "$original" ] &&
        [ -f "$2/admin/file" ] && [ "$(cat "$new_marker")" = "$source_id" ]
}

IMPORT_SOURCE=remote
IMPORT_EXCLUDE_PATTERNS=()
source_id=ssh://root@old.example.com:22/var/www/example.com
destination="$TEST_DIR/www/example.com"
previous=$IMPORT_REUSE_SITE_DIR
new_marker=$(import_marker_file "$destination")
old_marker=$(import_marker_file "$previous")
fail() { cat run.log >&2; echo "FAIL: $*" >&2; exit 1; }
fresh() {
    rm -rf www import
    mkdir -p "$previous/admin" "$destination" import
    echo video > "$previous/admin/file"
    import_mark_destination "$previous" "$source_id"
    original=$(stat -c '%d:%i' "$previous")
    empty=$(stat -c '%d:%i' "$destination")
}
# Capture an ordinary errexit caller; a function used as an if condition
# would suppress errexit in the questionnaire's bare reads on older setups.
run() {
    local scenario=$1 input=$2
    set +e
    (
        set -e
        if [[ "$scenario" == interrupt-* || "$scenario" == replace-* ]]; then
            import_take_over_rename() {
                command mv -T -- "$1" "$2" || return 1
                if [ "$scenario" = replace-final-marker ]; then
                    if [ "$2" = "$new_marker" ]; then
                        command mv "$new_marker" "$new_marker.saved"
                        cp "$new_marker.saved" "$new_marker"
                    fi
                    return 0
                fi
                if [ "$scenario" = replace-marker ] && [ "$2" = "$destination" ]; then
                    command mv "$old_marker" "$old_marker.saved"
                    cp "$old_marker.saved" "$old_marker"
                    return 0
                fi
                if [ "$scenario" = replace-during-rename ] && [ "$2" = "$destination" ]; then
                    command mv "$destination" "$destination.saved"
                    mkdir "$destination"
                    return 0
                fi
                if [ "$scenario" = interrupt-dir ] || [ "$2" = "$new_marker" ]; then exit 91; fi
            }
        fi
        if [[ "$scenario" == cross-device* ]]; then
            local other_device=$previous
            if [ "$scenario" = cross-device-destination ]; then other_device=$destination; fi
            stat() {
                if [ "${*: -1}" = "$other_device" ] && [ "$2" = '%d:%i' ]; then echo 999999:1; else command stat "$@"; fi
            }
        fi
        select_import_source
        case "$scenario" in
            swap-source) mv "$previous" "$previous.saved"; mkdir -p "$previous" ;;
            swap-destination) mv "$destination" "$destination.saved"; mkdir -p "$destination" ;;
            swap-marker) mv "$old_marker" "$old_marker.saved"; cp "$old_marker.saved" "$old_marker" ;;
        esac
        import_fetch_remote
        touch transferred
    ) < "$input" > run.log 2>&1
    status=$?
    set -e
}
# Exercise both rename implementations on hosts with either version of mv.
# Reject any invocation that could silently copy across a mount boundary.
mkdir rename-bin
cat > rename-bin/mv <<'SH'
#!/bin/sh
if [ "$1" = --help ]; then
    [ "$RENAME_MODE" != modern ] || echo '  --no-copy'
    exit 0
fi
[ "$RENAME_MODE" = modern ] && [ "$1" = --no-copy ] || exit 64
shift
exec "$SYSTEM_MV" "$@"
SH
chmod +x rename-bin/mv
SYSTEM_MV=$(command -v mv)
export SYSTEM_MV
for mode in modern legacy; do
    mkdir 'rename source'
    inode=$(stat -c '%d:%i' 'rename source')
    PATH="$TEST_DIR/rename-bin:$PATH" RENAME_MODE=$mode import_take_over_rename 'rename source' 'rename target'
    [ ! -e 'rename source' ]
    [ "$(stat -c '%d:%i' 'rename target')" = "$inode" ]
    rmdir 'rename target'
done
fresh
ln -s "$previous" source-link
ln -s "$destination" destination-link
for pair in source destination; do
    src=$previous dst=$destination
    if [ "$pair" = source ]; then src=./source-link; else dst=./destination-link; fi
    if import_take_over_site "$src" "$dst" "$source_id" inspect > run.log 2>&1; then fail "accepted $pair symlink"; fi
    grep -Fq 'final symlink' run.log || fail "$pair symlink diagnostic"
done
fresh
printf '%s\n' "$source_id" > "$new_marker"
IMPORT_FILES_ONLY=yes import_take_over_site "$previous" "$destination" "$source_id" inspect
[ "$IMPORT_TAKEOVER_HELD" = "$destination" ] || fail 'files-only pass planned a directory move'
unset IMPORT_TAKEOVER_PLAN IMPORT_TAKEOVER_HELD IMPORT_TAKEOVER_MARKER

printf 'n\n' > no
printf '\n' > yes
fresh
for scenario in cancel eof incompatible; do
    case "$scenario" in
        cancel) run "$scenario" no; { [ "$status" = 0 ] && grep -q 'Import cancelled' run.log; } || fail cancellation ;;
        eof) run "$scenario" /dev/null; { [ "$status" != 0 ] && grep -q 'Continue with this site' run.log; } || fail EOF ;;
        incompatible) run "$scenario" yes; { [ "$status" != 0 ] && grep -q checked-compatibility run.log; } || fail compatibility ;;
    esac
    [ "$(stat -c '%d:%i' "$previous")" = "$original" ] && [ -f "$previous/admin/file" ] &&
        [ "$(stat -c '%d:%i' "$destination")" = "$empty" ] && [ "$(cat "$old_marker")" = "$source_id" ] &&
        [ ! -e "$new_marker" ] && [ ! -e "$new_marker.takeover" ] && [ ! -e transferred ] || fail "$scenario changed paths"
done

for scenario in swap-source swap-destination swap-marker; do
    fresh
    run "$scenario" yes
    [ "$status" != 0 ] && [ ! -e "$new_marker" ] && [ ! -e transferred ] || fail "$scenario accepted"
done
fresh
run replace-during-rename yes
[ "$status" != 0 ] && [ -f "$old_marker" ] && [ ! -e "$new_marker" ] || fail 'replacement received marker'
fresh
run replace-marker yes
[ "$status" != 0 ] && [ -f "$old_marker" ] && [ ! -e "$new_marker" ] || fail 'replacement marker published'

fresh
run replace-final-marker yes
[ "$status" != 0 ] && [ -f "$new_marker.takeover" ] || fail 'changed final marker consumed intent'

for scenario in interrupt-dir interrupt-marker; do
    fresh
    run "$scenario" yes
    [ "$status" = 91 ] && [ -f "$new_marker.takeover" ] && [ ! -e "$previous" ] || fail "$scenario"
    if [ "$scenario" = interrupt-dir ]; then
        [ -f "$old_marker" ] && [ ! -e "$new_marker" ] || fail 'marker moved too soon'
    else
        [ ! -e "$old_marker" ] && [ -f "$new_marker" ] || fail 'marker did not follow'
    fi
    mv "$destination" "$destination.saved"
    mkdir "$destination"
    run retry yes
    [ "$status" != 0 ] && [ -f "$new_marker.takeover" ] && [ ! -e transferred ] || fail 'replacement tree accepted'
    grep -Fq "$new_marker.takeover records the import source, both paths, and the device and inode numbers." run.log ||
        fail 'missing intent identity information'
    grep -Fq 'Remove the intent file only after checking both paths and confirming where the site directory is.' run.log ||
        fail 'missing intent recovery instructions'
    rmdir "$destination"
    mv "$destination.saved" "$destination"
    run retry yes
    [ "$status" = 0 ] && [ -f transferred ] && [ ! -e "$new_marker.takeover" ] || fail 'identical retry failed'
    rm transferred
    run retry yes
    [ "$status" = 0 ] && [ -f transferred ] || fail 'completed take-over refused'
    rm transferred
done

fresh
printf '%s\n' "$source_id" > "$new_marker"
run stale-marker yes
[ "$status" = 0 ] && [ -f transferred ] && [ ! -e "$previous" ] || fail 'stale marker hid the held tree'
rm transferred
fresh
printf '%s\n' "$source_id" > "$new_marker"
touch "$destination/other"
run nonempty yes
{ [ "$status" != 0 ] && grep -q 'already holds something' run.log; } || fail 'nonempty destination accepted'
rm "$destination/other"
for scenario in cross-device cross-device-destination; do
    run "$scenario" yes
    [ "$status" != 0 ] && grep -q 'normal copy import' run.log && [ -f "$previous/admin/file" ] || fail "$scenario"
done
fresh
mv -T "$previous" "$destination"
run legacy yes
[ "$status" != 0 ] && [ -f "$old_marker" ] && [ ! -e "$new_marker" ] && [ -f "$destination/admin/file" ] ||
    fail 'legacy interruption changed paths'
{ grep -Fq "$previous is missing" run.log && grep -Fq "$old_marker still records $source_id" run.log &&
    grep -Fq "$destination has no source marker" run.log; } || fail 'legacy interruption diagnostic'
echo 'PASS: take-over checks, cancellation, path changes, both rename boundaries and repeated transfers'
