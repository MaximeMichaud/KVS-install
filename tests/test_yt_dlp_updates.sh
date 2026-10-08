#!/bin/bash
# yt-dlp in the PHP-FPM and cron containers: the yt-dlp command becomes the
# newer of the release the image carries and the one the cron container keeps
# in the yt-dlp volume, yt-dlp-update installs a newer release there only
# once it is checked, from the build of the architecture the image names,
# readable by www-data, and moves to it in one rename once it is on disk, and
# both Compose files share that volume between the two containers and pass
# them YT_DLP_AUTO_UPDATE.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-yt-dlp.XXXXXX)
TESTS_RUN=0

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "ok $TESTS_RUN - $1"
}

COMMAND="$ROOT_DIR/docker/php/yt-dlp.sh"
UPDATER="$ROOT_DIR/docker/cron/yt-dlp-update.sh"
RELEASES=https://releases.invalid/yt-dlp/releases
PINNED=2026.08.19

# Writes a stand-in for a yt-dlp release at $1/yt-dlp: it prints the version
# $2 for --version, its process ID for --pid, and otherwise names its copy
# and repeats its arguments. With RUN_LOG set when it is written, every run
# also adds the user it runs as to that file, root unless a stand-in for
# setpriv started it (KVS_TEST_USER).
fake_yt_dlp() {
    local dir="$1"
    local version="$2"
    local copy="$3"
    local log=""

    [ -z "${RUN_LOG:-}" ] || log="echo \"run as \${KVS_TEST_USER:-root}: \$*\" >> '${RUN_LOG}'"
    mkdir -p "$dir"
    cat > "$dir/yt-dlp" << EOF
#!/bin/sh
${log}
if [ "\$1" = --version ]; then
    echo "$version"
    exit 0
fi
if [ "\$1" = --pid ]; then
    echo "\$\$"
    exit 0
fi
printf '%s' "$copy $version"
printf ' [%s]' "\$@"
echo
exit "\${FAKE_STATUS:-0}"
EOF
    chmod 0755 "$dir/yt-dlp"
}

# Puts stand-ins for id and setpriv in the bin of a sandbox, which run_update
# puts first on the PATH, so every update runs the way root runs it in the
# cron container, whoever runs the suite: a release it checks runs through
# setpriv as www-data. The real setpriv would switch to www-data only for
# root, and only on a host that has that user, and the sandbox is closed to
# it. This one records its arguments, refuses a command behind a directory
# www-data cannot enter, as the kernel would, and runs the command as the
# user of the suite, which fake_yt_dlp then names www-data (KVS_TEST_USER).
fake_root() {
    local sandbox="$1"

    cat > "$sandbox/bin/id" << 'EOF'
#!/bin/sh
[ "$1" = -u ] && echo 0
EOF
    cat > "$sandbox/bin/setpriv" << EOF
#!/bin/sh
echo "setpriv \$*" >> "$sandbox/setpriv.log"
user=
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --reuid=*) user=\${1#--reuid=} ;;
        --) shift; break ;;
    esac
    shift
done
dir=\${1%/*}
while [ "\$dir" != "$sandbox" ]; do
    case "\$(stat -c %A "\$dir")" in
        *x) ;;
        *) echo "setpriv: \$dir is closed to \$user" >&2; exit 126 ;;
    esac
    dir=\${dir%/*}
done
KVS_TEST_USER=\$user exec "\$@"
EOF
    chmod 0755 "$sandbox/bin/id" "$sandbox/bin/setpriv"
}

# Lays out the image side of a sandbox: the pinned release under lib/yt-dlp,
# the asset it names, and the updates link to the volume, as the Dockerfiles
# build them, the volume open to www-data as Docker makes it; the yt-dlp
# command with its paths moved into the sandbox; and the stand-ins of
# fake_root.
make_sandbox() {
    local sandbox="$1"

    rm -rf "$sandbox"
    mkdir -p "$sandbox/lib/yt-dlp" "$sandbox/volume" "$sandbox/bin"
    chmod 0755 "$sandbox/volume"
    fake_yt_dlp "$sandbox/lib/yt-dlp/$PINNED" "$PINNED" image
    ln -s "$PINNED" "$sandbox/lib/yt-dlp/current"
    ln -s "$sandbox/volume" "$sandbox/lib/yt-dlp/updates"
    echo yt-dlp_linux.zip > "$sandbox/lib/yt-dlp/asset"
    sed -e "s|/usr/local/lib/yt-dlp|${sandbox}/lib/yt-dlp|g" "$COMMAND" > "$sandbox/bin/yt-dlp"
    chmod 0755 "$sandbox/bin/yt-dlp"
    fake_root "$sandbox"
}

# Installs a release in the volume of a sandbox the way yt-dlp-update does.
volume_release() {
    local sandbox="$1"
    local version="$2"

    fake_yt_dlp "$sandbox/volume/$version" "$version" volume
    ln -sfn "$version" "$sandbox/volume/current"
}

# The yt-dlp command replaces itself with the release it runs: a signal sent
# to the process PHP started, to stop a download, reaches yt-dlp, which would
# otherwise go on under a shell that is gone.
assert_command_execs() {
    local sandbox="$1"
    local what="$2"
    local pid

    "$sandbox/bin/yt-dlp" --pid > "$sandbox/pid" &
    pid=$!
    wait "$pid" || fail "$what: the yt-dlp command failed"
    [ "$(cat "$sandbox/pid")" = "$pid" ] ||
        fail "$what: the yt-dlp command must become yt-dlp (exec), not run it in a child process"
}

test_the_command_runs_the_newer_checked_copy() {
    local sandbox="$TEST_DIR/command"
    local output
    local status
    local version
    local name

    make_sandbox "$sandbox"
    output=$("$sandbox/bin/yt-dlp" -f 'best video' '' --no-color)
    [ "$output" = "image $PINNED [-f] [best video] [] [--no-color]" ] ||
        fail "an empty volume must leave yt-dlp on the release of the image, arguments intact: $output"
    assert_command_execs "$sandbox" "the release of the image"

    volume_release "$sandbox" 2026.10.01
    output=$("$sandbox/bin/yt-dlp" --flat-playlist 'a b')
    [ "$output" = "volume 2026.10.01 [--flat-playlist] [a b]" ] ||
        fail "a newer release in the volume must be the one that runs: $output"
    [ "$("$sandbox/bin/yt-dlp" --version)" = 2026.10.01 ] || fail "--version must name the release that runs"
    assert_command_execs "$sandbox" "the release of the volume"

    status=0
    FAKE_STATUS=3 "$sandbox/bin/yt-dlp" x > /dev/null || status=$?
    [ "$status" = 3 ] || fail "the yt-dlp command must return the status of yt-dlp, got $status"

    # A newer image is never shadowed by what an older one left in the volume.
    for version in 2026.07.01 "$PINNED" 2026.08.18.9; do
        volume_release "$sandbox" "$version"
        output=$("$sandbox/bin/yt-dlp" x)
        [ "$output" = "image $PINNED [x]" ] ||
            fail "release $version of the volume is not newer than $PINNED, yet it ran: $output"
    done
    volume_release "$sandbox" 2026.08.19.1
    [ "$("$sandbox/bin/yt-dlp" x)" = "volume 2026.08.19.1 [x]" ] ||
        fail "release 2026.08.19.1 is newer than $PINNED"

    # A copy that cannot run, or that is not a release, is never run.
    volume_release "$sandbox" 2026.11.01
    chmod 0644 "$sandbox/volume/2026.11.01/yt-dlp"
    [ "$("$sandbox/bin/yt-dlp" x)" = "image $PINNED [x]" ] || fail "a copy that is not executable must not run"
    rm -rf "$sandbox/volume/2026.11.01"
    [ "$("$sandbox/bin/yt-dlp" x)" = "image $PINNED [x]" ] || fail "a missing copy must not run"
    for name in latest .. '2026..10' '../../tmp'; do
        rm -f "$sandbox/volume/current"
        ln -s "$name" "$sandbox/volume/current"
        [ "$("$sandbox/bin/yt-dlp" x 2> /dev/null)" = "image $PINNED [x]" ] ||
            fail "a volume whose current is '$name' must not run"
    done

    # YT_DLP_AUTO_UPDATE=no: the entrypoint removes the link to the volume.
    volume_release "$sandbox" 2026.12.01
    rm "$sandbox/lib/yt-dlp/updates"
    [ "$("$sandbox/bin/yt-dlp" x)" = "image $PINNED [x]" ] ||
        fail "without the link to the volume, yt-dlp must stay at the release of the image"

    cmp -s "$ROOT_DIR/docker/php/yt-dlp.sh" "$ROOT_DIR/docker/cron/yt-dlp.sh" ||
        fail "the PHP-FPM and cron images must carry the same yt-dlp command"
    pass "the yt-dlp command becomes the newer of the image's release and the volume's, and nothing else"
}

# A stand-in for curl that serves $sandbox/releases as github.com serves the
# yt-dlp releases: /latest leads to /tag/<the tag in latest-tag>, and
# /download/<tag>/<file> is the file at that path. It insists on -f, which
# turns an HTTP error into a failure.
fake_curl() {
    local sandbox="$1"

    cat > "$sandbox/bin/curl" << EOF
#!/bin/bash
out= write= url= fail_on_error=
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        -o) out=\$2; shift ;;
        -w) write=\$2; shift ;;
        --connect-timeout | --max-time) shift ;;
        -*) [[ "\$1" == -*f* ]] && fail_on_error=yes ;;
        *) url=\$1 ;;
    esac
    shift
done
[ -n "\$fail_on_error" ] || { echo "curl: called without -f" >&2; exit 2; }
case "\$url" in
    "$RELEASES/latest")
        [ -s "$sandbox/releases/latest-tag" ] || exit 22
        [ "\$write" = '%{url_effective}' ] && printf '%s' "$RELEASES/tag/\$(cat "$sandbox/releases/latest-tag")"
        exit 0
        ;;
    "$RELEASES/download/"*)
        file="$sandbox/releases/download/\${url#"$RELEASES/download/"}"
        [ -f "\$file" ] || exit 22
        cp "\$file" "\$out"
        ;;
    *) exit 6 ;;
esac
EOF
    chmod 0755 "$sandbox/bin/curl"
}

# Writes the command of a build for another CPU at $1/yt-dlp: it does not
# start, and the shell says why, as on a server of the other architecture.
foreign_yt_dlp() {
    mkdir -p "$1"
    cat > "$1/yt-dlp" << 'EOF'
#!/bin/sh
echo "${0}: cannot execute binary file: Exec format error" >&2
exit 126
EOF
    chmod 0755 "$1/yt-dlp"
}

# Publishes a build of a release in the fake github.com of a sandbox: the zip
# $5 of the directory build (yt-dlp_linux.zip unless given), holding its
# command, named after the zip, and _internal/, and the line of that zip in
# the SHA2-256SUMS of the release, with the sha256 $4 when given. The command
# prints $3 for --version (the tag, unless a test needs a liar), or does not
# start at all when $3 is "foreign".
publish_release() {
    local sandbox="$1"
    local tag="$2"
    local says="${3:-$2}"
    local sha="${4:-}"
    local asset="${5:-yt-dlp_linux.zip}"
    local dir="$sandbox/releases/download/$tag"
    local build="$TEST_DIR/build-$tag-$says-${asset%.zip}"
    local sums="$dir/SHA2-256SUMS"

    mkdir -p "$dir"
    rm -rf "$build"
    if [ "$says" = foreign ]; then
        foreign_yt_dlp "$build"
    else
        fake_yt_dlp "$build" "$says" volume
    fi
    mv "$build/yt-dlp" "$build/${asset%.zip}"
    mkdir -p "$build/_internal"
    echo library > "$build/_internal/lib.txt"
    # The modes the zips of yt-dlp store, whatever the umask of the test.
    chmod 0755 "$build/_internal"
    chmod 0644 "$build/_internal/lib.txt"
    (cd "$build" && python3 - "$dir/$asset" << 'EOF'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    for root, dirs, files in os.walk("."):
        for name in sorted(dirs + files):
            path = os.path.join(root, name)[2:]
            info = zipfile.ZipInfo(path + ("/" if os.path.isdir(path) else ""))
            info.external_attr = (os.stat(path).st_mode & 0xFFFF) << 16
            archive.writestr(info, b"" if os.path.isdir(path) else open(path, "rb").read())
EOF
    )
    [ -n "$sha" ] || sha=$(sha256sum "$dir/$asset" | awk '{ print $1 }')
    # One line per file of the release, the zipapp first, as yt-dlp lists
    # them; a build published again replaces its line.
    [ -f "$sums" ] || printf '%s  yt-dlp\n' "${sha//?/a}" > "$sums"
    awk -v asset="$asset" '$2 != asset' "$sums" > "$sums.new"
    printf '%s  %s\n' "$sha" "$asset" >> "$sums.new"
    mv "$sums.new" "$sums"
    echo "$tag" > "$sandbox/releases/latest-tag"
}

# Runs yt-dlp-update in a sandbox, as root does in the cron container, under
# the strictest umask: what it installs must stay readable by www-data
# whatever umask cron gives it. Leaves its output in $sandbox/out and returns
# its status.
run_update() {
    local sandbox="$1"

    (
        umask 077
        env -i PATH="$sandbox/bin:/usr/bin:/bin" \
            YT_DLP_RELEASES="$RELEASES" \
            YT_DLP_DIR="$sandbox/volume" \
            YT_DLP_IMAGE_DIR="$sandbox/lib/yt-dlp" \
            sh "$UPDATER"
    ) > "$sandbox/out" 2>&1
}

assert_volume_runs() {
    local sandbox="$1"
    local version="$2"
    local what="$3"

    [ "$(readlink "$sandbox/volume/current")" = "$version" ] ||
        fail "$what: the volume must run $version, not $(readlink "$sandbox/volume/current" || true): $(cat "$sandbox/out")"
    [ "$("$sandbox/bin/yt-dlp" --version)" = "$version" ] || fail "$what: the yt-dlp command does not run $version"
}

assert_volume_holds() {
    local sandbox="$1"
    local expected="$2"
    local what="$3"
    local held

    held=$(cd "$sandbox/volume" && find . -mindepth 1 -maxdepth 1 ! -name .lock -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
    [ "$held" = "$expected" ] || fail "$what: the volume holds '$held', expected '$expected'"
}

test_the_update_installs_only_a_checked_newer_release() {
    local sandbox="$TEST_DIR/update"

    make_sandbox "$sandbox"
    fake_curl "$sandbox"

    publish_release "$sandbox" 2026.10.01
    run_update "$sandbox" || fail "the update of an empty volume failed: $(cat "$sandbox/out")"
    grep -Fq 'installed yt-dlp 2026.10.01 (yt-dlp_linux.zip, sha256 ' "$sandbox/out" ||
        fail "the update must say what it installed: $(cat "$sandbox/out")"
    assert_volume_runs "$sandbox" 2026.10.01 "a first update"
    [ -f "$sandbox/volume/2026.10.01/_internal/lib.txt" ] || fail "the whole directory build must be unpacked"
    [ ! -e "$sandbox/volume/2026.10.01/yt-dlp_linux" ] || fail "the command of the release must be renamed yt-dlp"
    [ "$(stat -c %a "$sandbox/volume/2026.10.01")" = 755 ] || fail "www-data must be able to run the release"
    [ -z "$(find "$sandbox/volume/2026.10.01" ! -perm -o+r -o -type d ! -perm -o+x)" ] ||
        fail "www-data must be able to read the whole release: $(find "$sandbox/volume/2026.10.01" -printf '%m %p\n')"
    assert_volume_holds "$sandbox" '2026.10.01 current ' "a first update"

    run_update "$sandbox" || fail "a second run failed: $(cat "$sandbox/out")"
    grep -Fq 'nothing to do: the latest release is 2026.10.01' "$sandbox/out" ||
        fail "a volume that runs the latest release has nothing to do: $(cat "$sandbox/out")"

    # The release replaced stays for the runs that started with it; the one
    # before goes, and so does what an interrupted run left.
    publish_release "$sandbox" 2026.11.01
    run_update "$sandbox" || fail "the update to 2026.11.01 failed: $(cat "$sandbox/out")"
    assert_volume_holds "$sandbox" '2026.10.01 2026.11.01 current ' "the second release"
    mkdir -p "$sandbox/volume/.new.leftover" "$sandbox/volume/2026.12.01"
    publish_release "$sandbox" 2026.12.01
    run_update "$sandbox" || fail "the update to 2026.12.01 failed: $(cat "$sandbox/out")"
    assert_volume_runs "$sandbox" 2026.12.01 "the third release"
    assert_volume_holds "$sandbox" '2026.11.01 2026.12.01 current ' "the third release"

    # Nothing that fails a check is installed, and the volume keeps running
    # what it ran.
    publish_release "$sandbox" 2027.01.01 2027.01.01 "$(printf 'b%.0s' {1..64})"
    if run_update "$sandbox"; then
        fail "a release whose sha256 is not the published one was installed"
    fi
    grep -Fq 'checksum mismatch for yt-dlp_linux.zip of 2027.01.01' "$sandbox/out" ||
        fail "a checksum mismatch must be reported: $(cat "$sandbox/out")"
    publish_release "$sandbox" 2027.01.02
    sed -i '/yt-dlp_linux.zip$/d' "$sandbox/releases/download/2027.01.02/SHA2-256SUMS"
    if run_update "$sandbox"; then
        fail "a release whose asset has no published sha256 was installed"
    fi
    grep -Fq 'has no entry for yt-dlp_linux.zip' "$sandbox/out" || fail "a missing checksum must be reported: $(cat "$sandbox/out")"
    publish_release "$sandbox" 2027.01.03 2026.01.01
    if run_update "$sandbox"; then
        fail "a release whose command names another version was installed"
    fi
    grep -Fq 'the yt-dlp of 2027.01.03 says it is 2026.01.01' "$sandbox/out" ||
        fail "a release that is not what its tag says must be reported: $(cat "$sandbox/out")"
    echo nightly > "$sandbox/releases/latest-tag"
    if run_update "$sandbox"; then
        fail "a tag that is not a version was followed"
    fi
    grep -Fq 'has a tag that is not a version: nightly' "$sandbox/out" || fail "a bad tag must be reported: $(cat "$sandbox/out")"
    rm "$sandbox/releases/latest-tag"
    if run_update "$sandbox"; then
        fail "an unreachable release page went unreported"
    fi
    grep -Fq "could not reach ${RELEASES}/latest" "$sandbox/out" || fail "an unreachable release page must be reported"
    assert_volume_runs "$sandbox" 2026.12.01 "after the failed updates"
    assert_volume_holds "$sandbox" '2026.11.01 2026.12.01 current ' "after the failed updates"

    # A release that is not newer than the one of the image is never
    # downloaded: the yt-dlp command would not run it.
    make_sandbox "$sandbox"
    fake_curl "$sandbox"
    publish_release "$sandbox" "$PINNED"
    run_update "$sandbox" || fail "a run with nothing to do failed: $(cat "$sandbox/out")"
    grep -Fq "nothing to do: the latest release is ${PINNED}, the image has ${PINNED} and the volume none" "$sandbox/out" ||
        fail "the release of the image must not be installed again: $(cat "$sandbox/out")"
    assert_volume_holds "$sandbox" '' "the release of the image"

    # A volume whose release cannot run is repaired with the latest one.
    publish_release "$sandbox" 2026.10.01
    run_update "$sandbox" || fail "the update failed: $(cat "$sandbox/out")"
    chmod 0644 "$sandbox/volume/2026.10.01/yt-dlp"
    run_update "$sandbox" || fail "the repair failed: $(cat "$sandbox/out")"
    assert_volume_runs "$sandbox" 2026.10.01 "a repaired volume"

    # One update at a time: the weekly one can meet the one of a start. This
    # shell holds the lock the way a running update does.
    publish_release "$sandbox" 2026.11.01
    exec 8> "$sandbox/volume/.lock"
    flock -n 8 || fail "the lock of the volume could not be taken"
    run_update "$sandbox" || fail "a run that met another one failed: $(cat "$sandbox/out")"
    exec 8>&-
    grep -Fq 'another update is running' "$sandbox/out" || fail "a second update must leave and say so"
    assert_volume_runs "$sandbox" 2026.10.01 "a run that met another one"
    run_update "$sandbox" || fail "the update after the lock was released failed: $(cat "$sandbox/out")"
    assert_volume_runs "$sandbox" 2026.11.01 "the update after the lock was released"
    pass "yt-dlp-update installs a newer release only once its sha256 and its version are checked"
}

# yt-dlp-update runs as root, from the weekly job and at the start of the
# container. A release it downloads runs as www-data from its very first
# run, the check of its version, as PHP-FPM and the KVS task run it: its
# sha256 comes from the same release page, which proves the download is the
# file the page lists, not what that file does. The run here plays root
# through the stand-ins of fake_root, as every update of this suite does.
test_a_new_release_first_runs_as_www_data() {
    local sandbox="$TEST_DIR/unprivileged"
    local RUN_LOG="$sandbox/runs"

    make_sandbox "$sandbox"
    fake_curl "$sandbox"
    publish_release "$sandbox" 2026.10.01
    run_update "$sandbox" || fail "an update run as root failed: $(cat "$sandbox/out")"
    [ "$(cat "$RUN_LOG")" = 'run as www-data: --version' ] ||
        fail "the release must first run as www-data, and only for its version: $(cat "$RUN_LOG")"
    grep -Eq "^setpriv --reuid=www-data --regid=www-data --clear-groups --no-new-privs -- ${sandbox}/volume/\.new\.[A-Za-z0-9]+/tree/yt-dlp --version\$" \
        "$sandbox/setpriv.log" || fail "setpriv must drop root for www-data: $(cat "$sandbox/setpriv.log")"
    assert_volume_runs "$sandbox" 2026.10.01 "an update run as root"
    pass "yt-dlp-update runs a release it downloaded as www-data, never as root"
}

# The image names the build it carries in its asset file, the one of the
# architecture it was built for, and the update fetches that build: an arm64
# server updates from yt-dlp_linux_aarch64.zip, while the x86-64 build of the
# same release does not even start there.
test_the_update_fetches_the_build_the_image_names() {
    local sandbox="$TEST_DIR/aarch64"

    make_sandbox "$sandbox"
    fake_curl "$sandbox"
    echo yt-dlp_linux_aarch64.zip > "$sandbox/lib/yt-dlp/asset"
    publish_release "$sandbox" 2026.10.01 foreign '' yt-dlp_linux.zip
    publish_release "$sandbox" 2026.10.01 2026.10.01 '' yt-dlp_linux_aarch64.zip
    grep -Eq '^[0-9a-f]{64}  yt-dlp_linux\.zip$' "$sandbox/releases/download/2026.10.01/SHA2-256SUMS" ||
        fail "the release must list the x86-64 build too, as yt-dlp publishes it"
    run_update "$sandbox" || fail "the update of an arm64 image failed: $(cat "$sandbox/out")"
    grep -Fq 'installed yt-dlp 2026.10.01 (yt-dlp_linux_aarch64.zip, sha256 ' "$sandbox/out" ||
        fail "an arm64 image must update from yt-dlp_linux_aarch64.zip: $(cat "$sandbox/out")"
    assert_volume_runs "$sandbox" 2026.10.01 "an arm64 update"
    [ -f "$sandbox/volume/2026.10.01/_internal/lib.txt" ] || fail "the whole aarch64 directory build must be unpacked"
    [ ! -e "$sandbox/volume/2026.10.01/yt-dlp_linux_aarch64" ] || fail "the command of the aarch64 build must be renamed yt-dlp"
    assert_volume_holds "$sandbox" '2026.10.01 current ' "an arm64 update"

    # The amd64 image of the same release gets the x86-64 build.
    make_sandbox "$sandbox"
    fake_curl "$sandbox"
    publish_release "$sandbox" 2026.10.01 2026.10.01 '' yt-dlp_linux.zip
    publish_release "$sandbox" 2026.10.01 foreign '' yt-dlp_linux_aarch64.zip
    run_update "$sandbox" || fail "the update of an amd64 image failed: $(cat "$sandbox/out")"
    grep -Fq 'installed yt-dlp 2026.10.01 (yt-dlp_linux.zip, sha256 ' "$sandbox/out" ||
        fail "an amd64 image must update from yt-dlp_linux.zip: $(cat "$sandbox/out")"
    assert_volume_runs "$sandbox" 2026.10.01 "an amd64 update"
    pass "yt-dlp-update fetches the build of the architecture the image was built for"
}

# Puts mv, ln, rm and sync of a sandbox in front of the real ones. Each call
# is written to $sandbox/events before it runs; sync also writes the inode of
# each file it is given, or "sync all" when it is given none; and an mv onto
# the current link of the volume writes what current and the link replacing
# it name at that moment, and whether the release it names is whole.
trace_commands() {
    local sandbox="$1"
    local command

    cat > "$sandbox/trace" << EOF
#!/bin/sh
events="$sandbox/events"
current="$sandbox/volume/current"
command=\${0##*/}
echo "\$command \$*" >> "\$events"
case "\$command" in
    sync)
        [ "\$#" -gt 0 ] || echo 'sync all' >> "\$events"
        for file; do
            case "\$file" in
                -*) ;;
                *) echo "sync inode \$(stat -c %i -- "\$file")" >> "\$events" ;;
            esac
        done
        ;;
    mv)
        source=
        target=
        for argument; do
            source=\$target
            target=\$argument
        done
        if [ "\$target" = "\$current" ]; then
            new=\$(readlink -- "\$source")
            whole=no
            [ -x "$sandbox/volume/\$new/yt-dlp" ] && whole=yes
            echo "switch from \$(readlink -- "\$current" || echo none) to \$new, whole: \$whole" >> "\$events"
        fi
        ;;
esac
PATH=/usr/bin:/bin exec "\$command" "\$@"
EOF
    chmod 0755 "$sandbox/trace"
    for command in mv ln rm sync; do
        ln -s ../trace "$sandbox/bin/$command"
    done
}

# Checks the events of one traced update that installed $2 in place of $3
# (none in an empty volume): the current link of the volume changed once, by
# one mv onto it, so neither a yt-dlp that starts meanwhile nor a crash can
# find it half done (ln -f need not replace a link atomically, and removing
# the link first leaves a moment without one); it moved to the release once
# that release was whole, and after every file of it was synced to disk.
assert_one_switch_after_sync() {
    local sandbox="$1"
    local version="$2"
    local previous="$3"
    local events="$sandbox/events"
    local writers
    local before
    local inode

    writers=$(awk -v current="$sandbox/volume/current" '
        $1 == "mv" || $1 == "ln" || $1 == "rm" {
            for (i = 2; i <= NF; i++) if ($i == current) { print $1; next }
        }' "$events" | tr '\n' ' ')
    [ "$writers" = 'mv ' ] ||
        fail "the current link must change by one mv onto it and nothing else, not by: ${writers:-nothing at all}"
    grep -Fxq "switch from $previous to $version, whole: yes" "$events" ||
        fail "current must go from $previous to the whole release $version in one step: $(grep '^switch ' "$events" || true)"
    before=$(sed -n '/^switch /q; p' "$events")
    if ! grep -Fxq 'sync all' <<< "$before"; then
        while read -r inode; do
            grep -Fxq "sync inode $inode" <<< "$before" ||
                fail "every file of $version must be on disk before current names it, and this one was not synced: $(find "$sandbox/volume/$version" -inum "$inode")"
        done < <(find "$sandbox/volume/$version" -printf '%i\n')
    fi
}

test_the_switch_is_one_rename_of_a_release_on_disk() {
    local sandbox="$TEST_DIR/switch"

    make_sandbox "$sandbox"
    fake_curl "$sandbox"
    trace_commands "$sandbox"

    publish_release "$sandbox" 2026.10.01
    run_update "$sandbox" || fail "the traced update of an empty volume failed: $(cat "$sandbox/out")"
    assert_volume_runs "$sandbox" 2026.10.01 "a traced first update"
    assert_one_switch_after_sync "$sandbox" 2026.10.01 none

    : > "$sandbox/events"
    publish_release "$sandbox" 2026.11.01
    run_update "$sandbox" || fail "the traced update to 2026.11.01 failed: $(cat "$sandbox/out")"
    assert_volume_runs "$sandbox" 2026.11.01 "a traced second update"
    assert_one_switch_after_sync "$sandbox" 2026.11.01 2026.10.01
    pass "the volume moves to a new release in one rename, once that release is whole and on disk"
}

test_the_cron_job_runs_the_update() {
    grep -Eq '^0 4 \* \* 0 root /usr/local/bin/yt-dlp-update >> /var/log/yt-dlp-update.log 2>&1$' \
        "$ROOT_DIR/docker/cron/yt-dlp-update.cron" || fail "the weekly job does not run yt-dlp-update"
    grep -Fxq 'COPY yt-dlp-update.sh /usr/local/bin/yt-dlp-update' "$ROOT_DIR/docker/cron/Dockerfile" ||
        fail "the cron image does not install yt-dlp-update"
    pass "the cron image runs yt-dlp-update every Sunday"
}

# Renders a Compose file with an env file into JSON.
render() {
    local env_file="$1"
    local compose_file="$2"
    local output="$3"

    docker compose --env-file "$env_file" -f "$compose_file" config --format json > "$output" ||
        fail "docker compose rejected $compose_file"
}

test_compose_shares_the_volume_and_passes_the_setting() {
    local case_dir="$TEST_DIR/compose"
    local compose_file
    local value
    local expected
    local json

    command -v docker > /dev/null 2>&1 || fail "docker compose is required"
    command -v jq > /dev/null 2>&1 || fail "jq is required"
    grep -Fxq 'YT_DLP_AUTO_UPDATE=yes' "$ROOT_DIR/docker/.env.example" ||
        fail "docker/.env.example does not carry YT_DLP_AUTO_UPDATE"

    mkdir -p "$case_dir/site"
    cp "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template" "$case_dir/site/docker-compose.yml"
    for value in default yes no; do
        sed -e 's/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=root-password/' \
            -e 's/^MARIADB_PASSWORD=.*/MARIADB_PASSWORD=kvs-password/' \
            "$ROOT_DIR/docker/.env.example" > "$case_dir/env-$value"
        case "$value" in
            default)
                sed -i '/^YT_DLP_AUTO_UPDATE=/d' "$case_dir/env-$value"
                expected=yes
                ;;
            *)
                sed -i "s/^YT_DLP_AUTO_UPDATE=.*/YT_DLP_AUTO_UPDATE=${value}/" "$case_dir/env-$value"
                expected=$value
                ;;
        esac
        for compose_file in "$ROOT_DIR/docker/docker-compose.yml" "$case_dir/site/docker-compose.yml"; do
            json="$case_dir/$value-$(basename "$(dirname "$compose_file")").json"
            render "$case_dir/env-$value" "$compose_file" "$json"
            jq -e --arg expected "$expected" '
                .services["php-fpm"].environment.YT_DLP_AUTO_UPDATE == $expected and
                .services.cron.environment.YT_DLP_AUTO_UPDATE == $expected' "$json" > /dev/null ||
                fail "$compose_file must pass YT_DLP_AUTO_UPDATE=${expected} to php-fpm and cron (.env: ${value})"
        done
    done

    for json in "$case_dir/default-docker.json" "$case_dir/default-site.json"; do
        # One named volume, written by cron and read by php-fpm: an update
        # reaches both containers, and outlives a recreated container.
        jq -e '
            .volumes["yt-dlp"] != null and (.volumes["yt-dlp"].external // false) == false and
            ([.services.cron.volumes[] | select(.target == "/var/lib/yt-dlp")] ==
                [{"type": "volume", "source": "yt-dlp", "target": "/var/lib/yt-dlp", "volume": {}}]) and
            ([.services["php-fpm"].volumes[] | select(.target == "/var/lib/yt-dlp")] ==
                [{"type": "volume", "source": "yt-dlp", "target": "/var/lib/yt-dlp", "read_only": true, "volume": {}}])' \
            "$json" > /dev/null || fail "${json##*/}: cron must write the yt-dlp volume and php-fpm read it"
    done
    pass "both Compose files share the yt-dlp volume and pass YT_DLP_AUTO_UPDATE from .env to both containers"
}

test_the_command_runs_the_newer_checked_copy
test_the_update_installs_only_a_checked_newer_release
test_a_new_release_first_runs_as_www_data
test_the_update_fetches_the_build_the_image_names
test_the_switch_is_one_rename_of_a_release_on_disk
test_the_cron_job_runs_the_update
test_compose_shares_the_volume_and_passes_the_setting

echo "1..$TESTS_RUN"
