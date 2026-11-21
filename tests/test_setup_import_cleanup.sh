#!/bin/bash
# shellcheck disable=SC2034  # Sourced setup functions read the fixture settings.
# shellcheck disable=SC2015  # Any failed part of an assertion must call fail.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# shellcheck source=/dev/null
source <(sed -n '/^import_protect_supplied_dump() {/,/^}/p; /^import_check_completed() {/,/^}/p; /^import_check_leftover_dump() {/,/^}/p; /^import_record_transfers() {/,/^}/p; /^import_remove_transfers() {/,/^}/p; /^run_root_mariadb() {/,/^}/p' "$root/docker/setup.sh")
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
cd "$work"
mkdir -p mariadb/init bin
cat > bin/docker <<'SH'
#!/bin/bash
set -eu
echo attempt >> attempts
[ "$1 $2 $3 $4 $5 $6" = 'compose exec -T mariadb sh -c' ]
shift 8
[ "$#" = 5 ] && [ "$1 $2 $3 $4" = '-u root site.test -e' ]
[ "$5" = "DELETE FROM fixture_options WHERE variable='KVS_INSTALL_IMPORT';" ]
[ ! -f offline ]
rm -f token
echo delete >> calls
SH
chmod +x bin/docker
export PATH="$work/bin:$PATH"
RED='' GREEN='' YELLOW='' NC='' IMPORT_MODE=false
echo 'DOMAIN=site.test
TABLES_PREFIX=fixture_
KVS_IMPORT_COMPLETED=2030-01-02T03:04:05Z' > .env
# shellcheck source=/dev/null
source ./.env
fail() { echo "FAIL: $*" >&2; exit 1; }
check() { (import_check_leftover_dump) > output 2>&1; }
dump=mariadb/init/10-kvs-import.sql.zst
native=mariadb/init/10-kvs-import-native
touch "$dump" token mariadb/init/keep.sql
( IMPORT_MODE=true HEADLESS=y IMPORT_SOURCE=directory VOLUME_CHOICE=''
  import_check_completed && import_check_leftover_dump
) > output 2>&1 || fail "receipt and staged dump: $(cat output)"
[ ! -e token ] && [ ! -e "$dump" ] && [ -f mariadb/init/keep.sql ] || fail "incomplete cleanup"
grep -Fq 'cleanup' output || fail "missing cleanup notice"
if grep -Eq 'may be partial|VOLUME_CHOICE=1' output; then fail "replacement advice after completion"; fi
check || fail "second cleanup failed"
[ "$(cat calls)" = delete ] || fail "queried the database with nothing staged"

# A crash after removing the hook can leave only the native payload.
mkdir "$native"
touch "$native/data" "$native.sh" token offline
if check; then fail "ignored a failed database cleanup"; fi
[ -f token ] && [ -f "$native.sh" ] && [ -f "$native/data" ] || fail "database failure lost the stage"
rm offline
check || fail "native cleanup: $(cat output)"
[ ! -e "$native" ] && [ ! -e "$native.sh" ] || fail "retained the native stage"
mkdir "$native"
# shellcheck disable=SC2329  # Inject a failure into the sourced cleanup.
if (rm() { return 1; }; import_check_leftover_dump) > output 2>&1; then fail "ignored failed native cleanup"; fi
check || fail "native payload without its hook"
[ ! -e "$native" ] || fail "retained a partially removed native stage"

touch "$dump" token
if KVS_IMPORT_COMPLETED='' check; then fail "adopted an unfinished import"; fi
grep -Fq 'may be partial' output && [ -f "$dump" ] && [ -f token ] || fail "lost unfinished import"
IMPORT_MODE=true check || fail "blocked an explicit import"
[ -f "$dump" ] && [ -f token ] || fail "cleaned up an active import"

# An unfamiliar entry is never recursively removed as an import artifact.
rm -f attempts
cp .env saved.env
echo "TABLES_PREFIX='bad name'" >> .env
if check; then fail "accepted an invalid saved table prefix"; fi
[ ! -f attempts ] || fail "queried with an invalid saved prefix"
# The other options table exists. A missing saved prefix must prevent the
# query even when the invoking shell exported a valid but unrelated one.
sed -i '/^TABLES_PREFIX=/d' .env
if (export TABLES_PREFIX=other_
    # shellcheck source=/dev/null
    source <(sed -n '/^# Load environment$/,/^source .env$/p' "$root/docker/setup.sh")
    import_check_leftover_dump) > output 2>&1; then fail "accepted inherited prefix"; fi
[ ! -f attempts ] && [ -f token ] && [ -f "$dump" ] || fail "used inherited prefix"
# shellcheck disable=SC2016  # An operator-supplied .env expression.
echo 'TABLES_PREFIX=${PREFIX_FROM_SHELL:-}' >> .env
if (export PREFIX_FROM_SHELL=other_; import_check_leftover_dump) > output 2>&1; then fail "used an inherited interpolation"; fi
[ ! -f attempts ] && [ -f token ] && [ -f "$dump" ] || fail "queried using an inherited interpolation"
cp saved.env .env
sed -i '/^DOMAIN=/d' .env
if DOMAIN=other.test check; then fail "accepted inherited domain"; fi
[ ! -f attempts ] && [ -f token ] && [ -f "$dump" ] && grep -q 'DOMAIN' output || fail "cleaned without saved DOMAIN"
mv saved.env .env
DOMAIN=other.test check || fail "used the shell domain instead of the saved domain"
touch "$dump" token
rm -f attempts

# A repeated directory import names a real operator input even if an alias
# resolves to the reserved stage. Stop before replacing or cleaning it.
ln -s mariadb/init alias
if (IMPORT_DB_DUMP=$PWD/alias/10-kvs-import.sql.zst IMPORT_MODE=true HEADLESS=y
    import_check_completed; import_check_leftover_dump) > output 2>&1; then fail "accepted input at the reserved path"; fi
[ -e "$dump" ] && [ -e token ] && [ ! -e attempts ] && grep -Fq IMPORT_DB_DUMP output || fail "lost supplied stage"


# Two names for one regular file must give the same preflight result.
ln "$dump" supplied.sql
if (IMPORT_DB_DUMP=$PWD/supplied.sql; import_protect_supplied_dump) > output 2>&1; then
    fail "accepted another name for the reserved inode"
fi
grep -Fq IMPORT_DB_DUMP output || fail "missing identity warning"
rm supplied.sql

# A local source can also occupy the registry pathname before a new import.
echo 'CREATE TABLE fixture_options (id int);' > mariadb/init/.import-transfers
if (IMPORT_DB_DUMP=$PWD/alias/.import-transfers IMPORT_MODE=true KVS_IMPORT_COMPLETED=''
    import_check_completed) > output 2>&1; then fail "accepted an operator dump at the registry path"; fi
grep -Fq 'CREATE TABLE' mariadb/init/.import-transfers && grep -Fq IMPORT_DB_DUMP output || fail "lost the supplied registry-path dump"
rm mariadb/init/.import-transfers

# A partial listing must not authorize even the first deletion.
# shellcheck disable=SC2329  # The cleanup calls the failing enumerator.
if (find() { printf '%s\0' "$dump"; return 1; }; import_check_leftover_dump) > output 2>&1; then fail "accepted partial listing"; fi
[ ! -f attempts ] && [ -f "$dump" ] || fail "queried with a partial listing"
touch mariadb/init/.old-kvs-import.sql
if check; then fail "accepted a hidden stage"; fi
[ ! -f attempts ] && [ -f token ] && [ -f "$dump" ] || fail "queried before validating hidden stage"
rm mariadb/init/.old-kvs-import.sql
mkdir mariadb/init/10-kvs-import.sql.gz
if check; then fail "accepted a directory in place of a SQL file"; fi
[ ! -f attempts ] && [ -f "$dump" ] || fail "queried before validating stage types"
rmdir mariadb/init/10-kvs-import.sql.gz
mv mariadb/init mariadb/kept
ln -s kept mariadb/init
if check; then fail "followed a linked init directory"; fi
[ -f mariadb/kept/10-kvs-import.sql.zst ] && [ -f token ] || fail "modified a linked stage"
rm mariadb/init
mv mariadb/kept mariadb/init
# shellcheck disable=SC2329  # Inject a failure into the sourced cleanup.
if (rm() { [ "${!#}" != "$dump" ] && command rm "$@"; }; import_check_leftover_dump) > output 2>&1; then fail "ignored failed stage removal"; fi
[ -f "$dump" ] || fail "lost the pending stage"
touch token
mkdir mariadb/init/other-kvs-import
if check; then fail "accepted an unfamiliar stage"; fi
[ -d mariadb/init/other-kvs-import ] && [ -f token ] || fail "modified an unfamiliar stage"
rmdir mariadb/init/other-kvs-import
mkdir import
IMPORT_STAGING=$PWD/import
raw="$IMPORT_STAGING/source copy.sql.gz"
manifest="$IMPORT_STAGING/kvs-export.manifest"
for source in archive replaced-archive remote directory; do
    touch "$dump" token "$raw" "$manifest"
    IMPORT_MODE=true
    IMPORT_RAW_DUMP='' IMPORT_RAW_MANIFEST=''
    case $source in
        archive|replaced-archive)
            mkdir -p extracted/www/admin/include site
            touch extracted/www/admin/include/setup.php "extracted/${raw##*/}" extracted/kvs-export.manifest
            # Replace both files during site settlement, before it returns.
            settled=$(
                if [ "$source" = replaced-archive ]; then
                    # shellcheck disable=SC2329  # Called inside archive settlement.
                    mv() {
                        if [ "${!#}" = site/ ]; then
                            command mv "$raw" initial-dump; echo new-dump > "$raw"
                            command mv "$IMPORT_STAGING/kvs-export.manifest" initial-manifest; echo new-manifest > "$IMPORT_STAGING/kvs-export.manifest"
                        fi
                        command mv "$@"
                    }
                fi
                import_archive_settle extracted www/ "${raw##*/}" kvs-export.manifest "$IMPORT_STAGING" site
            )
            import_save_nginx_config() { :; }
            # shellcheck source=/dev/null
            source "$root/docker/lib/import.sh"
            # Use the paths returned by archive settlement, as setup does.
            # shellcheck disable=SC2016  # Match the literal assignment in setup.
            eval "$(sed -n '/^    IMPORT_DB_DUMP=$(import_field "\$settled" 1)/,/^    IMPORT_RAW_DUMP=\$IMPORT_DB_DUMP$/p' "$root/docker/setup.sh")" ;;
        remote) IMPORT_RAW_DUMP=$raw; IMPORT_RAW_DUMP_ID=$(import_transfer_identity "$raw") ;;
    esac
    # Run the production steps between staging and starting MariaDB.
    eval "$(sed -n '/^import_stage_dump$/,/^import_replace_database_volume$/{ /^import_stage_dump$/d; /^import_replace_database_volume$/d; p; }' "$root/docker/setup.sh")"
    IMPORT_MODE=false
    unset IMPORT_DB_DUMP
    if [ "$source" = archive ]; then
        # Simulate a stop after the stage and first transfer were removed.
        rm "$dump" "$raw"
    fi
    check || fail "first $source cleanup"
    check || fail "retry $source cleanup"
    case $source in
        archive) [ ! -e "$manifest" ] || fail "retained archive manifest" ;;
        replaced-archive)
            grep -Fxq new-dump "$raw" && grep -Fxq new-manifest "$manifest" || fail "removed replacement archive inputs"
            rm "$manifest" ;;
        remote) [ ! -e "$raw" ] && [ -e "$manifest" ] || fail "wrong SSH cleanup" ;;
        directory) [ -e "$raw" ] && [ -e "$manifest" ] || fail "removed operator files" ;;
    esac
done

# Replace the SSH dump while site files are being copied, before SQL staging.
# shellcheck source=/dev/null
source <(sed -n '/^import_fetch_remote() {/,/^}/p' "$root/docker/setup.sh")
# shellcheck disable=SC2329
import_remote_dump() {
    [ "$(stat -Lc %a -- "$3")" = 600 ] || return 1
    echo received > "$3"
    stat -Lc '%d:%i' -- "$3" > receiver.identity
}
# shellcheck disable=SC2329
import_destination_ready() { mv "$raw" original; echo replacement > "$raw"; }
# shellcheck disable=SC2329
import_mark_destination() { :; }
# shellcheck disable=SC2329
import_remote_files() { :; }
# shellcheck disable=SC2329
import_remote_recheck_links() { :; }
# shellcheck disable=SC2329
import_ssh_close() { :; }
IMPORT_SSH_TARGET=site.test IMPORT_REMOTE_PORT=22 IMPORT_REMOTE_DIR=/site IMPORT_REMOTE_COMPRESSOR=gzip
IMPORT_REMOTE_DATABASE_FORMAT=sql IMPORT_REMOTE_RSYNC=yes IMPORT_EXCLUDE_PATTERNS=() IMPORT_MODE=true IMPORT_EXPORTER=fixture
CYAN='' LOG_DIR=$PWD IMPORT_RAW_MANIFEST='' raw=$IMPORT_STAGING/$DOMAIN.sql.gz
unset IMPORT_RAW_DUMP_ID
if command -v setfacl >/dev/null; then setfacl -d -m u::r-x,g::r-x "$IMPORT_STAGING"; fi
# Observe which file stat inspects after the transfer finishes.
# shellcheck disable=SC2329  # Called by the sourced receiver.
stat() {
    if [[ "$*" == *%z* && ${!#} == /proc/self/fd/* ]]; then
        command stat -Lc '%d:%i' -- "${!#}" > descriptor.identity
    fi
    command stat "$@"
}
import_fetch_remote > output
cmp receiver.identity descriptor.identity || fail "recorded identity did not come from the receiving descriptor"
[[ "$IMPORT_RAW_DUMP_ID" == "$(cat receiver.identity):"* ]] || fail "wrong received identity"
unset -f stat
( # A changed mode on the received file must stop before staging.
    # shellcheck disable=SC2329  # Called by the sourced receiver.
    import_remote_dump() { echo fixture > "$3"; chmod 640 "$3"; }
    DOMAIN=mode.test import_fetch_remote
) > mode.log 2>&1 && fail "recorded a received file with mode 0640"
grep -Fq '0600' mode.log || fail "missing mode warning"
import_record_transfers
IMPORT_MODE=false
unset IMPORT_DB_DUMP
check || fail "replacement cleanup"
grep -Fxq replacement "$raw" && grep -Fiq keeping output || fail "lost replacement or warning"

# A complete first record cannot authorize a partial cleanup.
IMPORT_MODE=true
IMPORT_RAW_DUMP_ID=$(import_transfer_identity "$raw")
import_record_transfers
IMPORT_MODE=false
touch "$dump" token
rm -f attempts
record=mariadb/init/.import-transfers
cp "$record" valid
for tail in record-boundary missing-identity partial-name empty-name bad-identity; do
    cp valid "$record"
    case $tail in
        record-boundary)
            # Keep exactly one complete name/identity pair, without the end marker.
            { IFS= read -r -d '' name; IFS= read -r -d '' identity; } < valid
            printf '%s\0%s\0' "$name" "$identity" > "$record" ;;
        missing-identity) printf 'next.sql\0' >> "$record" ;;
        partial-name) printf next >> "$record" ;;
        empty-name) printf '\0' >> "$record" ;;
        bad-identity) printf 'next.sql\0bad\0' >> "$record" ;;
    esac
    if check; then fail "accepted $tail"; fi
    [ ! -e attempts ] && [ -f token ] && [ -f "$raw" ] && [ -f "$dump" ] &&
        grep -Fq "$record" output || fail "partial cleanup for $tail"
done
# Normal completion must also verify the entire registry before its first query.
# shellcheck source=/dev/null
source <(sed -n '/^import_finish() {/,/^}/p' "$root/docker/setup.sh")
if (IMPORT_MODE=true; import_finish) > output 2>&1; then fail "finalized an invalid registry"; fi
[ ! -e attempts ] && grep -Fq "$record" output || fail "queried before checking the completion registry"
cp valid "$record"
( IMPORT_MODE=true IMPORT_DB_DUMP=$raw HEADLESS=y
  import_check_completed; import_check_leftover_dump
) > output 2>&1 || fail "could not clean the stage with an explicitly supplied transfer"
[ -f "$raw" ] && [ ! -e "$dump" ] && grep -Fq IMPORT_DB_DUMP output || fail "removed supplied transfer"
echo 'Completed import cleanup checks passed.'
