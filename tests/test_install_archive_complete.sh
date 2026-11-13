#!/bin/bash
# kvs-install.sh stages a KVS upload by copying it out of /root. scp and sftp
# create the file at its final name and then grow it, so the old copy, taken
# as soon as the name appeared, could capture a half-written archive. The init
# container's 00-extract.sh then refuses it, and every re-run, which prefers
# the staged copy over /root, fails the same way until the file is deleted by
# hand. The archive is now copied only once its upload is complete. This drives
# the extracted helpers with real zip and unzip and a background writer that
# finishes a truncated file mid-wait. A file that stops growing and still does
# not unzip is broken, not uploading, and must end the wait; two archives are
# refused, as the Docker setup refuses them; a copy that fails part way leaves
# nothing under an archive name; and without unzip the wait stops at once
# instead of waiting for ever.
set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$TEST_DIR/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v unzip > /dev/null 2>&1 ||
    { echo "ok - unzip is not installed here, the case is left to the CI runner"; exit 0; }
command -v zip > /dev/null 2>&1 ||
    { echo "ok - zip is not installed here, the case is left to the CI runner"; exit 0; }

# The archive helpers, as kvs-install.sh defines them (each closes with a
# column-zero brace; the nested blocks are indented).
awk '
    /^archive_is_valid\(\) \{/,/^}/
    /^wait_for_complete_kvs_archive\(\) \{/,/^}/
    /^copy_complete_archive\(\) \{/,/^}/
' "$ROOT_DIR/kvs-install.sh" > "$WORK/arch.sh"
for fn in archive_is_valid wait_for_complete_kvs_archive copy_complete_archive; do
    grep -q "^$fn() {" "$WORK/arch.sh" || fail "$fn is not defined in kvs-install.sh"
done
# shellcheck disable=SC1091
source "$WORK/arch.sh"

# A complete archive and some broken stand-ins.
make_archive() {
    local target=$1 stage
    stage=$(mktemp -d "$WORK/stage.XXXXXX")
    printf 'index\n' > "$stage/index.php"
    printf 'more\n' > "$stage/readme.txt"
    (cd "$stage" && zip -q -r "$target" .)
    rm -rf "$stage"
}
make_archive "$WORK/good.zip"

archive_is_valid "$WORK/good.zip" || fail "a complete archive must be valid"
: > "$WORK/empty.zip"
archive_is_valid "$WORK/empty.zip" && fail "an empty file must not be valid"
head -c 24 "$WORK/good.zip" > "$WORK/trunc.zip"
archive_is_valid "$WORK/trunc.zip" && fail "a truncated archive must not be valid"
archive_is_valid "$WORK/missing.zip" && fail "a missing file must not be valid"

# A complete archive already in place is copied straight through.
name="KVS_7.0.2_[example.com].zip"
mkdir -p "$WORK/src1" "$WORK/dest1"
cp "$WORK/good.zip" "$WORK/src1/$name"
copy_complete_archive "$WORK/src1" "$WORK/dest1" || fail "a complete archive must be copied"
[ -f "$WORK/dest1/$name" ] || fail "the archive must land in the destination"
cmp -s "$WORK/good.zip" "$WORK/dest1/$name" || fail "the copy must be the whole archive"

# An upload still in progress is waited out: the staged copy is the finished
# file, never the truncated one that is present first.
mkdir -p "$WORK/src2" "$WORK/dest2"
head -c 24 "$WORK/good.zip" > "$WORK/src2/$name"
(
    sleep 3
    cp "$WORK/good.zip" "$WORK/src2/$name"
) &
writer=$!
copy_complete_archive "$WORK/src2" "$WORK/dest2" || { wait "$writer"; fail "a finished upload must be copied"; }
wait "$writer"
archive_is_valid "$WORK/dest2/$name" || fail "the staged copy must be a complete archive"
cmp -s "$WORK/good.zip" "$WORK/dest2/$name" ||
    fail "the staged copy must match the finished upload, not the partial one"

# Each case below must end on its own: a wait that never stops is the defect.
export KVS_ARCHIVE_SETTLE_SECONDS=3 KVS_ARCHIVE_POLL_SECONDS=1
export -f archive_is_valid wait_for_complete_kvs_archive copy_complete_archive
bounded() {
    timeout 30 bash -c '"$@"' _ "$@"
}
staged_archives() {
    find "$1" -maxdepth 1 -name 'KVS_*.zip' | wc -l
}

# A file that holds still but is not a zip (an error page saved under the
# archive name) is reported, not waited on for ever.
mkdir -p "$WORK/src3" "$WORK/dest3"
printf '<html>404 Not Found</html>\n' > "$WORK/src3/$name"
status=0
bounded copy_complete_archive "$WORK/src3" "$WORK/dest3" 2> "$WORK/err3" || status=$?
[ "$status" -ne 0 ] || fail "a broken archive must not be staged"
[ "$status" -ne 124 ] || fail "a broken archive must end the wait, not hold it for ever"
grep -q 'not a complete zip archive' "$WORK/err3" || fail "a broken archive must be named as such"
[ "$(staged_archives "$WORK/dest3")" -eq 0 ] || fail "nothing must be staged from a broken archive"

# Two archives: the Docker setup refuses them in kvs-archive/, and staging one
# of them would install whichever sorts first.
mkdir -p "$WORK/src4" "$WORK/dest4"
cp "$WORK/good.zip" "$WORK/src4/KVS_6.3.2_[example.com].zip"
cp "$WORK/good.zip" "$WORK/src4/KVS_7.0.3_[example.com].zip"
status=0
bounded copy_complete_archive "$WORK/src4" "$WORK/dest4" 2> "$WORK/err4" || status=$?
[ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "two archives must be refused (status $status)"
grep -q 'Multiple KVS archives' "$WORK/err4" || fail "two archives must be reported"
[ "$(staged_archives "$WORK/dest4")" -eq 0 ] || fail "nothing must be staged from two archives"

# A copy that fails part way (a full disk) leaves no truncated file under an
# archive name, where the next run would take it.
mkdir -p "$WORK/src5" "$WORK/dest5"
cp "$WORK/good.zip" "$WORK/src5/$name"
status=0
(
    # shellcheck disable=SC2329 # called by copy_complete_archive
    cp() {
        local to=$2
        [ -d "$to" ] && to=$to/${1##*/}
        head -c 40 "$1" > "$to"
        echo "cp: error writing: No space left on device" >&2
        return 1
    }
    copy_complete_archive "$WORK/src5" "$WORK/dest5"
) 2> /dev/null || status=$?
[ "$status" -ne 0 ] || fail "a failed copy must fail the staging"
[ -z "$(ls -A "$WORK/dest5")" ] || fail "a failed copy must leave nothing in the destination: $(ls -A "$WORK/dest5")"

# Without unzip nothing can say the archive is complete: stop, do not wait.
mkdir -p "$WORK/src6"
cp "$WORK/good.zip" "$WORK/src6/$name"
status=0
# shellcheck disable=SC2016 # expanded by the inner shell
timeout 30 bash -c 'PATH=/nonexistent; wait_for_complete_kvs_archive "$1"' _ "$WORK/src6" \
    > /dev/null 2> "$WORK/err6" || status=$?
[ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "the wait must fail at once without unzip (status $status)"
grep -q 'unzip is required' "$WORK/err6" || fail "the missing unzip must be named"

# On a minimal Debian unzip is missing until the base packages, which come
# after the questions: the attended upload wait installs it first instead of
# waiting for ever for an archive it cannot check. The whole installer runs
# here, with every command of the system but unzip and a stub apt.
mkdir -p "$WORK/bin" "$WORK/archives"
for tool in /usr/bin/* /bin/*; do
    case ${tool##*/} in unzip | unzipsfx | zipinfo | funzip | apt-get) continue ;; esac
    [ -e "$WORK/bin/${tool##*/}" ] || [ -L "$WORK/bin/${tool##*/}" ] ||
        ln -s "$tool" "$WORK/bin/${tool##*/}"
done
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/apt-get"
chmod +x "$WORK/bin/apt-get"
cp "$WORK/good.zip" "$WORK/archives/KVS_7.0.3_[example.com].zip"
cat > "$WORK/driver.sh" << 'EOF'
work=$2 real_unzip=$3
# shellcheck disable=SC1090
source "$1"
apt_get() { echo "apt_get $*" >> "$work/apt"; }
apt_install() { echo "apt_install $*" >> "$work/apt"; ln -s "$real_unzip" "$work/bin/unzip"; }
PATH="$work/bin"
HEADLESS= AUTOPACKAGEUPDATE=1 IONCUBE=1 DATABASE_VER=1 SSL_CHOICE=3 WWW_CHOICE=1 APPROVE_INSTALL=y
KVS_ARCHIVE_DIR="$work/archives"
installQuestions < /dev/null || exit $?
echo "PHP=$PHP"
EOF
status=0
timeout 60 bash "$WORK/driver.sh" "$ROOT_DIR/kvs-install.sh" "$WORK" "$(command -v unzip)" > "$WORK/out7" 2>&1 || status=$?
[ "$status" -ne 124 ] || fail "the attended upload wait must not hold for ever without unzip"
[ "$status" -eq 0 ] || fail "the attended questions must succeed once unzip is installed: $(tail -n 3 "$WORK/out7")"
grep -q 'apt_install -qq unzip' "$WORK/apt" || fail "unzip must be installed before the wait"
grep -q 'PHP=8.3' "$WORK/out7" || fail "the archive must be read once it is checked"

echo "ok - a KVS archive is staged only once its upload is complete"
