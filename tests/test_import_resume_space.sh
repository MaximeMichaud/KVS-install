#!/bin/bash
# Local rsync and df stand-ins exercise the copy boundary without a server.
# shellcheck disable=SC2034
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export TMPDIR="$tmp" CALLS="$tmp/calls" AVAILABLE=17
mkdir "$tmp/bin"
cat > "$tmp/bin/rsync" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case " $* " in
    *' --dry-run '*)
        if [ "${PARTIAL_STATS:-no}" = yes ]; then
            printf '%s\n' 'Number of regular files transferred: 0' 'Total transferred file size: 0 bytes'
        fi
        exit "${COUNT_STATUS:-124}" ;;
esac
STUB
cat > "$tmp/bin/df" <<'STUB'
#!/bin/sh
printf 'Filesystem MB Used Available Capacity Mount\nfake 999 0 %s 0%% /\n' "$AVAILABLE"
STUB
chmod +x "$tmp/bin/"*
PATH="$tmp/bin:$PATH"
IMPORT_MARKER_DIR="$tmp/records" IMPORT_SSH_TARGET=root@old.test IMPORT_REMOTE_SUDO=no
IMPORT_TRANSFER_RESERVE_MB=5 IMPORT_TRANSFER_RETRIES=0 IMPORT_SIZE_TIMEOUT=30
dest="$tmp/example.test"
source_id=ssh://root@old.test:22/srv/site
import_mark_destination "$dest" "$source_id"
truncate -s 8M "$dest/video"
mkdir -p "$dest/backup" "$dest/cache" "$dest/media/backup"
truncate -s 40M "$dest/backup/ignored" "$dest/cache/ignored"
truncate -s 2M "$dest/media/backup/kept"
truncate -s 6M "$dest/video"
scope=$(import_count_scope /backup '/cache/*')
import_count_save "$dest" "$scope" 4 3 $((20 * 1048576))
flag=$(import_count_timeout_file "$dest")
touch "$flag"
copy() { import_remote_files /srv/site "$dest" yes /backup '/cache/*' > "$tmp/out" 2>&1; }
: > "$CALLS"
if copy; then fail 'the saved remainder and the reserve exceed the available space'; fi
[ ! -s "$CALLS" ] || fail 'a resumed pass started rsync on a full disk'
grep -qi 'not enough free space' "$tmp/out" || fail 'missing space diagnostic'
AVAILABLE=18 copy || fail "the remainder fits: $(cat "$tmp/out")"
[ "$(wc -l < "$CALLS")" = 1 ] || fail 'a resumed pass recounted the remote site'
# A bind root may be reached through a symlink. Keep the same marker and
# scan contents under its destination name, then use that route for a pass.
mkdir "$tmp/alias"
ln -s "$dest" "$tmp/alias/example.test"
dest="$tmp/alias/example.test"
: > "$CALLS"
AVAILABLE=18 copy || fail "the remainder also fits through a symlink: $(cat "$tmp/out")"
[ "$(wc -l < "$CALLS")" = 1 ] || fail 'a symlinked site was recounted'
rm "$flag"
: > "$CALLS"
if copy; then fail 'a new timeout ignored the saved remainder'; fi
[ -f "$flag" ] || fail 'a space refusal lost the timeout marker and forces another remote count'
[ "$(wc -l < "$CALLS")" = 1 ] || fail 'a timed-out count started copying'
grep -q -- --dry-run "$CALLS" || fail 'only the dry run may start'
truncate -s 24M "$dest/video"
if AVAILABLE=4 copy; then fail 'a larger destination cancelled the database reserve'; fi
AVAILABLE=5 copy || fail 'the database reserve fits after the files arrived'
rm "$(import_count_file "$dest")"
AVAILABLE=1 copy || fail 'an unknown site size must allow the copy'

# Without a usable count, neither transport may start a copy that cannot fit.
resume="$tmp/resumed site"
mkdir "$tmp/source"
printf 'payload\n' > "$tmp/source/video"
import_mark_destination "$resume" "$source_id"
touch "$resume/earlier"
import_count_save "$resume" "$(import_count_scope)" 3 2 $((20 * 1048576))
import_ssh() { echo tar >> "$CALLS"; sh -s; }
IMPORT_REMOTE_PREFIX=()
for method in no yes; do
    for count_status in 12 23 0; do
        : > "$CALLS"
        if COUNT_STATUS=$count_status AVAILABLE=1 IMPORT_TRANSFER_RESERVE_MB=0 import_remote_files "$tmp/source" "$resume" "$method" > "$tmp/out" 2>&1; then
            fail "$method/$count_status copied without room for the saved estimate"
        fi
        grep -qi 'not enough free space' "$tmp/out" || fail "missing space error: $(cat "$tmp/out")"
        if grep -Eq '^tar$|--info=progress2' "$CALLS" || [ -e "$resume/video" ]; then fail 'started transferring the payload'; fi
        [ "$method" = yes ] || break
    done
    if COUNT_STATUS=12 PARTIAL_STATS=yes AVAILABLE=1 import_remote_files "$tmp/source" "$resume" "$method" > "$tmp/out" 2>&1; then
        fail 'partial totals from an interrupted scan overrode the saved size'
    fi
    COUNT_STATUS=12 AVAILABLE=22 IMPORT_TRANSFER_RESERVE_MB=0 import_remote_files "$tmp/source" "$resume" "$method" > "$tmp/out" 2>&1 || fail "the remainder fits: $(cat "$tmp/out")"
    if [ "$method" = no ]; then
        cmp "$tmp/source/video" "$resume/video" || fail 'tar did not copy the payload'
        rm "$resume/video"
    else
        grep -q -- --info=progress2 "$CALLS" || fail 'rsync did not start the transfer'
    fi
done

awk '/^import_remote_free_space_check\(\) \{/,/^}/' "$root/docker/setup.sh" > "$tmp/check.sh"
# shellcheck source=/dev/null
source "$tmp/check.sh"
# shellcheck source=/dev/null
source <(sed -n '/^import_remote_size_text() {/,/^}/p' "$root/docker/setup.sh")
declare -F import_remote_size_text >/dev/null || fail 'setup.sh no longer defines import_remote_size_text'
(
    # shellcheck disable=SC2329  # Called by the sourced transfer function.
    du() { return 1; }
    if COUNT_STATUS=12 AVAILABLE=1 import_remote_files "$tmp/source" "$resume" no > "$tmp/out" 2>&1; then fail 'an unreadable destination bypassed the saved estimate'; fi
    grep -Fq 'full estimate' "$tmp/out" || fail 'missing local measurement warning'
)
rm "$(import_count_file "$resume")"
(
    RED='' YELLOW='' NC=''
    IMPORT_RESUME_SPACE_REPORT="$tmp/resume.report"
    IMPORT_TRANSFER_RESERVE_MB=0
    printf 'site_size_status=exact\nsite_size_mb=20\ndb_size_mb=0\n' > "$IMPORT_RESUME_SPACE_REPORT"
    # A sparse file is large in logical bytes but contributes few disk blocks.
    truncate -s 20M "$resume/sparse"
    for method in no yes; do
        if COUNT_STATUS=12 AVAILABLE=1 import_remote_files "$tmp/source" "$resume" "$method" > "$tmp/out" 2>&1; then fail 'ignored an exact source measurement'; fi
        COUNT_STATUS=12 AVAILABLE=22 import_remote_files "$tmp/source" "$resume" "$method" > "$tmp/out" 2>&1 || fail 'exact source measurement fits'
    done
    # A resumed tar pass needs only the unfiltered bound minus allocated
    # bytes already present, plus the database reserve.
    printf 'site_size_status=upper_bound\nsite_size_mb=20\ndb_size_mb=0\n' > "$IMPORT_RESUME_SPACE_REPORT"
    import_mark_destination "$tmp/empty" "$source_id"
    if AVAILABLE=10 import_remote_files "$tmp/source" "$tmp/empty" no > "$tmp/out" 2>&1; then
        fail "an empty marked destination bypassed the upper bound"
    fi
    [ ! -e "$tmp/empty/video" ] || fail "an empty marked destination started the transfer"
    dd if=/dev/zero of="$resume/old-name" bs=1M count=16 status=none
    echo renamed > "$tmp/source/new-name"
    AVAILABLE=7 IMPORT_TRANSFER_RESERVE_MB=2 import_remote_files "$tmp/source" "$resume" no > "$tmp/out" 2>&1 ||
        fail "resumed tar charged the full upper bound: $(cat "$tmp/out")"
    AVAILABLE=4 IMPORT_TRANSFER_RESERVE_MB=2 import_remote_files "$tmp/source" "$resume" no > "$tmp/out" 2>&1 ||
        fail "a bound-only shortage on retry must warn"
    grep -q 'upper bound.*estimate' "$tmp/out" || fail "missing estimate warning"
    [ -f "$resume/old-name" ] || fail "tar removed the old name"
    cmp "$tmp/source/new-name" "$resume/new-name" || fail "tar did not copy the renamed file"
    for free in 1 unknown; do
        if AVAILABLE=$free IMPORT_TRANSFER_RESERVE_MB=2 import_remote_files "$tmp/source" "$resume" no > "$tmp/out" 2>&1; then
            fail "resumed tar ignored the database reserve or unreadable free space"
        fi
    done
    # With no estimate, keep the ordinary inspection's upper-bound warning.
    printf 'site_size_status=skipped\nsite_fs_used_mb=50\ndb_size_mb=0\n' > "$IMPORT_RESUME_SPACE_REPORT"
    COUNT_STATUS=12 AVAILABLE=1 import_remote_files "$tmp/source" "$resume" no > "$tmp/out" 2>&1 || fail 'unknown size prevented tar'
    grep -Fq 'site size is not known exactly' "$tmp/out" || fail 'unknown size skipped the first-pass check'
    ! grep -Fq 'IMPORT_SIZE_TIMEOUT=0' "$tmp/out" || fail 'a resumed pass offered a measure it skips'
)
# A report without a numeric size describes an unknown site, not an empty
# one: check the filesystem bound and say so when it does not fit.
(
    RED='' YELLOW='' NC=''
    for fields in none status-only exact exact-text upper-bound; do
        case "$fields" in
            none) : ;;
            status-only) printf 'site_size_status=\n' ;;
            exact) printf 'site_size_status=exact\n' ;;
            exact-text) printf 'site_size_status=exact\nsite_size_mb=?\nsite_required_mb=\n' ;;
            upper-bound) printf 'site_size_status=upper_bound\n' ;;
        esac > "$tmp/absent.report"
        printf 'site_fs_used_mb=50\ndb_size_mb=0\n' >> "$tmp/absent.report"
        AVAILABLE=3 import_remote_free_space_check "$tmp/absent.report" "$tmp/absent" > "$tmp/out" 2>&1 || fail "$fields: an absent size must not stop the import"
        grep -Fq 'reported no size, at most 50 MB' "$tmp/out" || fail "$fields: an absent size passed for a site of 0 MB: $(cat "$tmp/out")"
        ! grep -Fq 'IMPORT_SIZE_TIMEOUT=0' "$tmp/out" || fail "$fields: offered a measure that returns no figure"
        AVAILABLE=3 import_remote_free_space_check "$tmp/absent.report" "$tmp/absent" '' before-prefix > "$tmp/out" 2>&1 || fail "$fields: refused before the prefix"
        [ ! -s "$tmp/out" ] || fail "$fields: warned twice, before the final budget"
        AVAILABLE=55 import_remote_free_space_check "$tmp/absent.report" "$tmp/absent" > "$tmp/out" 2>&1 || fail "$fields: the bound fits"
        [ ! -s "$tmp/out" ] || fail "$fields: warned although the filesystem bound fits"
        # A resumed pass without a saved count reaches the same check.
        IMPORT_RESUME_SPACE_REPORT="$tmp/absent.report" IMPORT_TRANSFER_RESERVE_MB=0 COUNT_STATUS=12 AVAILABLE=3 \
            import_remote_files "$tmp/source" "$resume" no > "$tmp/out" 2>&1 || fail "$fields: an absent size prevented the resumed copy"
        grep -Fq 'reported no size, at most 50 MB' "$tmp/out" || fail "$fields: a resumed pass took an absent size for 0 MB"
    done
    # Free space that cannot be read stops an absent size at every stage,
    # as it stops a measured one.
    printf 'site_size_status=exact\nsite_fs_used_mb=50\ndb_size_mb=0\n' > "$tmp/absent.report"
    for stage in pending before-prefix received; do
        # shellcheck disable=SC2329  # Called by the sourced check.
        if (df() { :; }; import_remote_free_space_check "$tmp/absent.report" "$tmp/absent" '' "$stage") > "$tmp/out" 2>&1; then
            fail "$stage: unreadable free space let an absent size through: $(cat "$tmp/out")"
        fi
        grep -Fq 'ERROR: not enough free space for the site' "$tmp/out" || fail "$stage: unreadable free space gave the wrong reason: $(cat "$tmp/out")"
    done
    # Without the filesystem usage either, the warning names no bound.
    printf 'site_size_status=exact\ndb_size_mb=0\n' > "$tmp/absent.report"
    AVAILABLE=55 import_remote_free_space_check "$tmp/absent.report" "$tmp/absent" > "$tmp/out" 2>&1 || fail 'no size and no usage must not stop the import'
    grep -Fq '(the old server reported neither a size nor its filesystem usage)' "$tmp/out" || fail "an absent usage was shown as a figure: $(cat "$tmp/out")"
    # A measure cut short, failed or skipped keeps its own wording without a figure.
    for status in incomplete failed skipped; do
        printf 'site_size_status=%s\nsite_fs_used_mb=50\ndb_size_mb=0\n' "$status" > "$tmp/absent.report"
        AVAILABLE=3 import_remote_free_space_check "$tmp/absent.report" "$tmp/absent" > "$tmp/out" 2>&1 || fail "$status: an unfinished measure must not stop the import"
        grep -Fq 'site size is not known exactly' "$tmp/out" || fail "$status: missing warning"
        ! grep -Fq 'reported no size' "$tmp/out" || fail "$status: an unfinished measure was reported as a missing figure: $(cat "$tmp/out")"
        if [ "$status" = skipped ]; then
            ! grep -Fq 'IMPORT_SIZE_TIMEOUT=0' "$tmp/out" || fail 'a skipped measure offered the timeout'
        else
            grep -Fq 'IMPORT_SIZE_TIMEOUT=0 measures the whole site.' "$tmp/out" || fail "$status: the timeout advice was lost"
        fi
        # shellcheck disable=SC2329  # Called by the sourced check.
        (df() { :; }; import_remote_free_space_check "$tmp/absent.report" "$tmp/absent") > "$tmp/out" 2>&1 || fail "$status: unreadable free space must keep warning only"
    done
    for field in site_required_mb site_size_mb db_size_mb site_fs_used_mb; do
        printf 'site_size_status=exact\n%s=8796093022208\n' "$field" > "$tmp/large.report"
        if AVAILABLE=100 import_remote_free_space_check "$tmp/large.report" "$tmp/absent" > "$tmp/out" 2>&1; then
            fail "$field: accepted an oversized report"
        fi
        grep -Fq "$field is too large" "$tmp/out" || fail "$field: missing range diagnostic"
    done
    printf 'site_size_status=upper_bound\nsite_required_mb=8796093022208\n' > "$tmp/large.report"
    if IMPORT_RESUME_SPACE_REPORT="$tmp/large.report" import_check_estimated_transfer_space "$resume" 0 '' > "$tmp/out" 2>&1; then
        fail "converted an oversized resumed estimate to bytes"
    fi
    grep -Fq "site_required_mb is too large" "$tmp/out" || fail "missing range diagnostic on retry"
    # Decimal megabytes can carry leading zeroes in older or hand-written reports.
    for field in site_size_mb site_required_mb site_fs_used_mb; do
        status=exact
        [ "$field" != site_fs_used_mb ] || status=skipped
        printf 'site_size_status=%s\n%s=0010\ndb_size_mb=0\n' "$status" "$field" > "$tmp/decimal.report"
        if AVAILABLE=9 import_remote_free_space_check "$tmp/decimal.report" "$tmp/absent" > "$tmp/out" 2>&1; then
            [ "$status" = skipped ] || fail "$field: read 0010 as octal"
            grep -q 'not known exactly' "$tmp/out" || fail "$field: missing filesystem bound warning"
        else
            [ "$status" = exact ] || fail "$field: unexpected refusal"
        fi
        printf 'site_size_status=%s\n%s=08\ndb_size_mb=0\n' "$status" "$field" > "$tmp/decimal.report"
        (AVAILABLE=9 import_remote_free_space_check "$tmp/decimal.report" "$tmp/absent") > "$tmp/out" 2>&1 ||
            fail "$field: rejected decimal 08"
        [ ! -s "$tmp/out" ] || fail "$field: unexpected diagnostic for 08"
    done
    # A measured size keeps its verdicts, zero included.
    printf 'site_size_status=exact\nsite_size_mb=0\nsite_fs_used_mb=50\ndb_size_mb=0\n' > "$tmp/absent.report"
    AVAILABLE=3 import_remote_free_space_check "$tmp/absent.report" "$tmp/absent" > "$tmp/out" 2>&1 || fail 'a measured empty site was refused'
    [ ! -s "$tmp/out" ] || fail 'a measured empty site was reported as unknown'
    printf 'site_size_status=exact\nsite_size_mb=9\nsite_fs_used_mb=50\ndb_size_mb=0\n' > "$tmp/absent.report"
    if AVAILABLE=3 import_remote_free_space_check "$tmp/absent.report" "$tmp/absent" > "$tmp/out" 2>&1; then fail 'an exact size that does not fit must stop'; fi
)
# Model independent mount points at the four allocation paths.
cd "$tmp"
mkdir -p import mariadb/init data/volumes existing-volume
export IMPORT_STAGING="$tmp/import" IMPORT_VOLUME_PROJECT=example
unset DOCKER_HOST DOCKER_CONTEXT
printf '%s' fixture-engine > "$tmp/data/engine-id"
docker() {
    printf '%s\n' "$*" >> "$tmp/docker-calls"
    [ "${DOCKER_UNAVAILABLE:-no}" != yes ] || return 1
    case "$*" in
        "context inspect --format {{.Endpoints.docker.Host}}"*)
            [ "${CONTEXT_ERROR:-no}" != yes ] || return 1
            echo "${CONTEXT_ENDPOINT:-unix:///var/run/docker.sock}" ;;
        "volume inspect --format {{.Mountpoint}} example_mariadb-data")
            if [ -n "${INSPECT_ERROR:-}" ]; then echo "$INSPECT_ERROR" >&2; return 1; fi
            if [ "${EXISTING:-no}" != yes ]; then
                printf '\n' # The CLI also writes an empty formatted result to stdout.
                echo 'Error response from daemon: get example_mariadb-data: no such volume' >&2
                return 1
            fi
            echo "${MOUNTPOINT-$tmp/existing-volume}" ;;
        "volume inspect --format {{.Mountpoint}} kvs_mariadb-data") echo "$tmp/small-volume" ;;
        "volume inspect --format {{.Mountpoint}} kvs-example_mariadb-data") echo "$tmp/existing-volume" ;;
        "info --format {{.ID}}{{println}}{{.DockerRootDir}}")
            printf '%s\n' "${ENGINE_ID-fixture-engine}" "${DOCKER_ROOT-$tmp/data}" ;;
        *) return 1 ;;
    esac
}
device() {
    [ -d "$1" ] || return 1
    case "$(realpath -- "$1")" in
        "$tmp/import") echo "${RAW_DEVICE:-1}" ;;
        "$tmp/mariadb/init") echo "${REPLAY_DEVICE:-1}" ;;
        "$tmp/data/volumes") [ "${EXISTING:-no}" = no ] || return 1; echo "${DB_DEVICE:-1}" ;;
        "$tmp/existing-volume") echo "${DB_DEVICE:-1}" ;;
        "$tmp/data") echo "${ROOT_DEVICE:-1}" ;;
        "$tmp/client"|"$tmp/small-volume") echo 5 ;;
        *) echo 1 ;;
    esac
}
stat() {
    if [ "$1 $2" = '-Lc %d' ]; then device "${@: -1}"; else command stat "$@"; fi
}
df() {
    local id capacity
    id=$(device "${@: -1}") || return 1
    capacity="FREE_$id"
    printf 'Filesystem MB Used Available Capacity Mount\nfake 999 0 %s 0%% /\n' "${!capacity:-$AVAILABLE}"
}
RED='' YELLOW='' NC=''
printf 'db_size_mb=4\nsite_size_mb=2\nsite_size_status=exact\n' > "$tmp/report"
for source_arg in '' "$source_id"; do
    if AVAILABLE=11 import_remote_free_space_check "$tmp/report" "$dest" "$source_arg"; then
        fail 'inspection omitted the raw dump, staging copy or loaded database'
    fi
done
AVAILABLE=15 import_remote_free_space_check "$tmp/report" "$dest"
AVAILABLE=13 import_remote_free_space_check "$tmp/report" "$dest" "$source_id"
if IMPORT_REUSE_DUMP=yes AVAILABLE=7 import_remote_free_space_check "$tmp/report" "$dest" "$source_id"; then
    fail 'reusing a raw dump still needs room for staging and loading'
fi
IMPORT_REUSE_DUMP=yes AVAILABLE=8 import_remote_free_space_check "$tmp/report" "$dest" "$source_id"
# shellcheck source=/dev/null
source <(sed -n '/^import_remote_earlier_pass() {/,/^}/p' "$root/docker/setup.sh")
IMPORT_REMOTE_DIR=/srv/site IMPORT_REMOTE_PORT=22
import_remote_earlier_pass "$dest" || fail 'the inspection would rescan the symlinked site'
for EXISTING in no yes; do
    RAW_DEVICE=2 REPLAY_DEVICE=3 DB_DEVICE=4
    FREE_1=0 FREE_2=4 FREE_3=4 FREE_4=4
    import_remote_free_space_check "$tmp/report" "$dest" "$source_id" || fail 'database space was charged to the site'
    for disk in 2 3 4; do
        if (printf -v "FREE_$disk" 3; import_remote_free_space_check "$tmp/report" "$dest" "$source_id"); then
            fail "omitted database requirement on device $disk"
        fi
    done
    if REPLAY_DEVICE=2 FREE_2=7 import_remote_free_space_check "$tmp/report" "$dest" "$source_id"; then
        fail 'the raw and replay copies must fit together'
    fi
    FREE_2=0 IMPORT_REUSE_DUMP=yes import_remote_free_space_check "$tmp/report" "$dest" "$source_id" || fail 'charged for a reused dump'
    expected=$(DB_DEVICE=1 FREE_2=0 import_remote_database_space_mb "$tmp/report" received "$dest")
    [ "$expected" = 4 ] || fail 'wrong transfer reserve for the site device'
done
# Before prefix selection, only the site and the two known dump locations
# can veto an import. No Docker path belongs to this project yet.
: > "$tmp/docker-calls"
FREE_1=2 FREE_4=0 import_remote_free_space_check "$tmp/report" "$dest" '' before-prefix || fail 'premature volume check'
for disk in 1 2 3; do
    if (FREE_1=2 FREE_4=0; printf -v "FREE_$disk" 0; import_remote_free_space_check "$tmp/report" "$dest" '' before-prefix); then
        fail "preliminary check omitted device $disk"
    fi
done
[ ! -s "$tmp/docker-calls" ] || fail 'preliminary check probed Docker storage'
printf 'site_size_status=incomplete\ndb_size_mb=4\n' > "$tmp/report"
if DB_DEVICE=1 FREE_1=3 import_remote_free_space_check "$tmp/report" "$dest"; then fail 'an unknown site size hid a database shortage'; fi
# An unknown volume belongs in the site budget. Keep checking both known
# dump disks and never use an ancestor of a daemon-only path on this host.
mkdir "$tmp/client"
for storage in unavailable hidden-mount empty-mount relative-mount hidden-root empty-root inspect-error wrong-volume remote-mount remote-new remote-context unknown-context forwarded-socket missing-id; do
    (
        EXISTING=yes
        case "$storage" in
            unavailable) DOCKER_UNAVAILABLE=yes ;;
            hidden-mount) MOUNTPOINT="$tmp/client/missing/data" ;;
            empty-mount) MOUNTPOINT='' ;;
            relative-mount) MOUNTPOINT=mariadb/init ;;
            hidden-root) EXISTING=no DOCKER_ROOT="$tmp/client/missing" ;;
            empty-root) EXISTING=no DOCKER_ROOT='' ;;
            inspect-error) INSPECT_ERROR='Error response from daemon: failed to inspect existing volume' ;;
            wrong-volume) INSPECT_ERROR='Error response from daemon: get other-data: no such volume' ;;
            remote-mount) DOCKER_HOST=tcp://engine.test:2376 ;;
            remote-new) EXISTING=no DOCKER_HOST=ssh://engine.test ;;
            remote-context) DOCKER_HOST=unix:///var/run/docker.sock DOCKER_CONTEXT=other CONTEXT_ENDPOINT=ssh://engine.test ;;
            unknown-context) CONTEXT_ERROR=yes ;;
            forwarded-socket) ENGINE_ID=other-engine ;;
            missing-id) ENGINE_ID='' ;;
        esac
        : > "$tmp/docker-calls"
        FREE_1=4 import_remote_free_space_check "$tmp/report" "$dest" "$source_id" 2> "$tmp/error" || fail "$storage refused a sufficient site reserve"
        grep -Fq 'WARNING:' "$tmp/error" || fail "$storage omitted the fallback warning"
        grep -Fq "$dest" "$tmp/error" || fail "$storage did not name the fallback filesystem"
        if FREE_1=3 import_remote_free_space_check "$tmp/report" "$dest" "$source_id"; then fail "$storage omitted the MariaDB reserve"; fi
        if FREE_1=4 FREE_2=3 import_remote_free_space_check "$tmp/report" "$dest" "$source_id"; then fail "$storage skipped the raw dump check"; fi
        if FREE_1=4 FREE_3=3 import_remote_free_space_check "$tmp/report" "$dest" "$source_id"; then fail "$storage skipped the replay check"; fi
        case "$storage" in
            inspect-error|wrong-volume)
                if grep -q '^info ' "$tmp/docker-calls"; then fail "$storage substituted the default volume driver"; fi ;;
        esac
    )
done
: > "$tmp/docker-calls"
IMPORT_VOLUME_PROJECT='' FREE_1=4 import_remote_free_space_check "$tmp/report" "$dest" "$source_id" || fail 'files-only pass required a selected volume'
[ ! -s "$tmp/docker-calls" ] || fail 'a files-only pass inspected storage for an unselected project'
# A fresh daemon may not have created its volumes directory yet.
rmdir "$tmp/data/volumes"
EXISTING=no ROOT_DEVICE=4 FREE_1=0 import_remote_free_space_check "$tmp/report" "$dest" "$source_id" || fail 'ignored a visible Docker root'

# Run the prefix selection and the production check that follows it. A small
# placeholder volume must not veto the chosen project, or vice versa.
mkdir "$tmp/small-volume"
printf 'db_size_mb=4\nsite_size_mb=0\nsite_size_status=exact\n' > "$tmp/report"
sed -n '/^select_site_prefix() {/,/^}/p; /^# Only ask about prefix if using default/,/^warn_if_existing_project_resources /p' "$root/docker/setup.sh" |
    sed "s|/var/www/|$tmp/alias/|g" > "$tmp/prefix-flow"
for selected_free in 3 4; do
    # shellcheck disable=SC2329  # These stubs run in the sourced setup code.
    (
        printf 'SITE_PREFIX=kvs\nCOMPOSE_PROJECT_NAME=kvs\n' > .env
        DOMAIN=example.test HEADLESS=y PREFIX_CHOICE=1 IMPORT_SOURCE=remote
        IMPORT_REMOTE_REPORT="$tmp/report" IMPORT_REMOTE_SPACE_SOURCE="$source_id"
        IMPORT_MARKER_DIR="$tmp/markers" KVS_EMAIL_OVERRIDE_SET=false
        RED='' GREEN='' CYAN='' NC=''
        set_env_value() { :; }
        remove_env_value() { :; }
        validate_site_prefix() { :; }
        site_prefix_is_saved() { return 1; }
        warn_if_existing_project_resources() { :; }
        FREE_1=4 FREE_4=$selected_free FREE_5=0
        : > "$tmp/docker-calls"
        # shellcheck source=/dev/null
        source "$tmp/prefix-flow"
    ) > "$tmp/prefix.log" 2>&1 && rc=0 || rc=$?
    grep -Fq 'kvs-example_mariadb-data' "$tmp/docker-calls" || fail 'the selected volume was never checked'
    if grep -Fq 'kvs_mariadb-data' "$tmp/docker-calls"; then fail 'the placeholder volume was checked'; fi
    if [ "$selected_free" = 3 ]; then [ "$rc" != 0 ]; else [ "$rc" = 0 ]; fi || fail "wrong selected-volume verdict: $(cat "$tmp/prefix.log")"
done
echo 'PASS: resumed copies check the saved remainder and budget for database staging'
