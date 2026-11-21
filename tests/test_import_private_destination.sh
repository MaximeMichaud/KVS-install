#!/bin/bash
# The copy and its staging directories must protect the source credentials
# even while the transfer is incomplete and the file retains its old mode.
# shellcheck disable=SC2034,SC2329
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
umask 022
site="$tmp/source" dest="$tmp/dest" config=admin/include/setup_db.php
mkdir -p "$site/admin/include" "$tmp/bin"
export TMPDIR="$tmp" SSH_CALLS="$tmp/ssh.log"
cat > "$tmp/bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SSH_CALLS"
shift
exec sh -c "$*"
STUB
chmod +x "$tmp/bin/ssh"
PATH="$tmp/bin:$PATH"
printf 'fixture\n' > "$site/$config"
mkdir "$site/#media"
printf 'cover\n' > "$site/#media/cover"
printf 'index\n' > "$site/;index"
touch "$site/admin/include/setup.php" "$site/.hidden"
chmod 755 "$site" "$site/$config"
IMPORT_MARKER_DIR="$tmp/markers" IMPORT_REMOTE_SUDO=no IMPORT_SSH_TARGET=old.test
IMPORT_SSH_COMMAND=(ssh) IMPORT_SSH_OPTS=() IMPORT_REMOTE_PREFIX=()
fail() { echo "FAIL: $*" >&2; exit 1; }
private() { [ "$(stat -c %a -- "$1")" = 700 ] || fail "public directory: $1"; }
copied() {
    private "$dest"
    cmp "$site/#media/cover" "$dest/#media/cover" || fail 'missing #media content'
    cmp "$site/;index" "$dest/;index" || fail 'missing ;index content'
    cmp "$site/$config" "$dest/$config" || fail 'missing configuration'
    [ -f "$dest/.hidden" ] || fail 'missing hidden file'
}
import_mark_destination "$dest" local
private "$dest"
chmod 755 "$dest"
import_mark_destination_files_only "$dest" local "$tmp/dump"
private "$dest"
rm -rf "$dest"
import_place_site "$site" "$dest"
copied
chmod 755 "$dest"
import_place_site "$dest" "$dest"
private "$dest"
rm -rf "$dest"
(
    command() {
        if [ "$1" = -v ] && [ "$2" = rsync ]; then return 1; fi
        builtin command "$@"
    }
    import_place_site "$site" "$dest"
)
copied
# A wide source may exceed one cp command line. Hard links in different
# top-level entries must still arrive as one inode when rsync is absent.
wide="$tmp/wide"
mkdir "$wide"
printf 'linked content\n' > "$wide/base"
printf -v prefix '%0180d' 0
for ((n=0; n<850; n++)); do ln "$wide/base" "$wide/$prefix$n"; done
rm -rf "$dest"
(
    command() {
        if [ "$1" = -v ] && [ "$2" = rsync ]; then return 1; fi
        builtin command "$@"
    }
    ulimit -s 512
    import_place_site "$wide" "$dest"
)
private "$dest"
[ "$(stat -c %h "$dest/base")" -eq 851 ] || fail 'the wide copy lost a hard link'
for method in yes no; do
    rm -rf "$dest"
    mkdir -m 755 "$dest"
    import_remote_files "$site" "$dest" "$method" > "$tmp/out" 2>&1 || fail "$(cat "$tmp/out")"
    copied
done
chmod 755 "$dest"
mkdir "$tmp/settle"
cp -a "$site/." "$tmp/settle/"
import_archive_settle "$tmp/settle" '' '' '' "$tmp/staged" "$dest"
copied
[ -s "$SSH_CALLS" ] || fail 'the remote commands must run through the stub'

# Exercise the archive setup entry point with an unpacker that explicitly
# restores a public mode to its extraction root (as an archive can request).
awk '/^import_fetch_archive\(\) \{/,/^}/' "$root/docker/setup.sh" |
    sed "s|/var/www/|$tmp/|g" > "$tmp/fetch"
# shellcheck source=/dev/null
source "$tmp/fetch"
DOMAIN=archive.test IMPORT_STAGING="$tmp/staging" IMPORT_ARCHIVE="$tmp/in.tar"
IMPORT_ARCHIVE_COMMAND=tar IMPORT_ARCHIVE_ROOT='' IMPORT_ARCHIVE_DUMP=db.sql IMPORT_ARCHIVE_MANIFEST=''
CYAN='' NC='' GREEN=''
import_archive_extract() {
    mkdir -p "$3"
    chmod 755 "$3"
    cp -a "$site/." "$3/"
    touch "$3/db.sql"
    parent=$(dirname "$3")
    [ "$parent" != "$tmp" ] || fail 'extraction overwrote the private stage mode'
    private "$parent"
}
dest="$tmp/$DOMAIN"
import_fetch_archive
copied
# Exercise the permission module on storage that acknowledges chmod but
# leaves the mounted root untouched. All other modes are real.
export KVS_PATH="$dest" KVS_INIT_RUN_DIR="$tmp/run"
sed '/^export KVS_PATH=/d; /^export KVS_INIT_RUN_DIR=/d' "$root/docker/init/lib/common.sh" > "$tmp/common"
sed "s|source /init/lib/common.sh|source \"$tmp/common\"|" \
    "$root/docker/init/docker-entrypoint.d/60-permissions.sh" > "$tmp/permissions"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/chown"
cat > "$tmp/bin/chmod" <<'STUB'
#!/bin/sh
if [ "$1" = 600 ] && [ "$2" = "$KVS_PATH/admin/include/setup_db.php" ] && [ "${LOCK_CONFIG:-no}" = yes ]; then exit 0; fi
if [ "$2" = "$KVS_PATH" ] && [ "${LOCK_ROOT:-no}" = yes ]; then exit "${CHMOD_STATUS:-0}"; fi
exec /bin/chmod "$@"
STUB
# This suite also runs without privileges to switch users. Model only
# the identity switch and the answer for this exact access check.
cat > "$tmp/bin/setpriv" <<'STUB'
#!/bin/sh
[ "$#" = 7 ] && [ "$1" = --reuid=101 ] && [ "$2" = --regid=101 ] &&
    [ "$3" = --clear-groups ] && [ "$4" = -- ] && [ "$5" = test ] &&
    [ "$6" = -x ] && [ "$7" = "$KVS_PATH" ] || exit 2
[ "${NGINX_ACCESS:-yes}" = yes ]
STUB
chmod +x "$tmp/bin/chown" "$tmp/bin/chmod" "$tmp/bin/setpriv"
if NGINX_ACCESS=no LOCK_ROOT=yes bash "$tmp/permissions" > "$tmp/init.log" 2>&1; then fail 'init accepted a private site root'; fi
grep -Fq "nginx cannot traverse the site root $dest (mode 700)" "$tmp/init.log" || fail 'missing traversal error'
chmod 710 "$dest"
LOCK_ROOT=yes CHMOD_STATUS=1 NGINX_ACCESS=yes bash "$tmp/permissions" > "$tmp/init.log" 2>&1 || fail 'init refused nginx traversal granted by ACL'
[ "$(stat -c %a "$dest")" = 710 ] || fail 'the fixture did not preserve the restrictive mode'
chmod 751 "$dest"
if LOCK_ROOT=yes NGINX_ACCESS=no bash "$tmp/permissions" > "$tmp/init.log" 2>&1; then fail 'other execute overrode a denied nginx ACL'; fi
grep -Fq "nginx cannot traverse the site root $dest (mode 751)" "$tmp/init.log" || fail 'missing ACL denial diagnostic'
grep -Fq 'UID 101' "$tmp/init.log" || fail 'missing nginx identity in the remedy'
bash "$tmp/permissions" > "$tmp/init.log" 2>&1 || fail 'init refused a traversable root'
[ "$(stat -c %a "$dest")" = 755 ] && [ "$(stat -c %a "$dest/$config")" = 600 ] || fail 'incorrect final modes'
if grep -Fq 'chmod 600' "$tmp/init.log"; then fail 'warning for a protected file'; fi
chmod 644 "$dest/$config"
chmod 700 "$dest"
LOCK_CONFIG=yes bash "$tmp/permissions" > "$tmp/init.log" 2>&1 || fail 'unapplied credential mode stopped init'
[ "$(stat -c %a "$dest/$config")" = 644 ] && [ "$(stat -c %a "$dest")" = 755 ] || fail 'expected a live site with the original file mode'
grep -F '[WARN]' "$tmp/init.log" | grep -F "$dest/$config (mode 644)" | grep -Fq "chmod 600 \"$dest/$config\"" || fail 'missing credential path, effective mode or chmod command in warning'
echo 'PASS: local, archive and remote imports protect credentials behind a private directory'
