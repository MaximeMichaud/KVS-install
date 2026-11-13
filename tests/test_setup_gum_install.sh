#!/bin/bash
# install_gum of docker/setup.sh downloaded the "latest" gum release and
# piped it from curl straight into tar in /usr/local/bin, unverified. An
# interrupted download left a truncated, executable gum there; the next run
# found it with command -v, kept it, and every step it drew crashed the
# setup (the partial binary segfaults). The release is now pinned with the
# sha256 of each tarball, the download is bounded in time and checked, its
# gum runs next to its final place (never from TMPDIR, which may be mounted
# noexec) before it is renamed into place, and a gum that does not run in
# the install directory is replaced. The progress helpers draw with gum only
# when GUM_BIN names one that runs, so a broken gum elsewhere on the PATH
# gets plain text instead of crashing the setup.
set -uo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kvs-gum-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# The pinned release and install_gum, as the script defines them.
awk '
    /^GUM_VERSION=/ { capture = 1 }
    capture { print }
    capture && /^install_gum\(\) \{/ { in_function = 1 }
    in_function && /^}$/ { exit }
' "$ROOT_DIR/docker/setup.sh" > "$WORK/gum.sh"
grep -q '^install_gum() {' "$WORK/gum.sh" || fail "install_gum is not defined after the gum pins in docker/setup.sh"

# The pins themselves: a version and one sha256 per architecture.
# shellcheck source=/dev/null
pins=$(source "$WORK/gum.sh"; printf '%s %s %s' "$GUM_VERSION" "$GUM_SHA256_X86_64" "$GUM_SHA256_ARM64")
read -r pinned_version pinned_x86 pinned_arm <<< "$pins"
[[ "$pinned_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "GUM_VERSION must be a pinned release, got: $pinned_version"
[[ "$pinned_x86" =~ ^[0-9a-f]{64}$ ]] || fail "GUM_SHA256_X86_64 must be a sha256, got: $pinned_x86"
[[ "$pinned_arm" =~ ^[0-9a-f]{64}$ ]] || fail "GUM_SHA256_ARM64 must be a sha256, got: $pinned_arm"
[ "$pinned_x86" != "$pinned_arm" ] || fail "each architecture needs its own sha256"
pass "the gum release and the sha256 of each tarball are pinned"

# Only the tools install_gum may use, so that no gum of the host is found.
mkdir -p "$WORK/min" "$WORK/stub"
for tool in bash sh mktemp sha256sum tar gzip install mv rm printf cat head chmod mkdir ls sleep date grep tail sed awk; do
    path=$(command -v "$tool") || fail "the test needs $tool"
    ln -s "$path" "$WORK/min/$tool"
done
TIMEOUT=$(command -v timeout) || fail "the test needs timeout"

# A gum that runs: what the pinned tarball holds, for this test. It stands
# for a TMPDIR mounted noexec: started from under NOEXEC_DIR (the TMPDIR of
# each case), it is refused like a binary there would be. gum spin runs its
# command; anything else prints the version.
mkdir -p "$WORK/pkg/gum_${pinned_version}_Linux_x86_64" "$WORK/pkg/gum_${pinned_version}_Linux_arm64"
for dir in "$WORK/pkg"/gum_*; do
    cat > "$dir/gum" <<STUB
#!/bin/sh
if [ -n "\${NOEXEC_DIR:-}" ]; then
    case "\$0" in "\$NOEXEC_DIR"/*) echo "\$0: Permission denied" >&2; exit 126 ;; esac
fi
if [ "\$1" = spin ]; then
    while [ "\$#" -gt 0 ] && [ "\$1" != -- ]; do shift; done
    shift
    exec "\$@"
fi
echo "gum version v${pinned_version} (test)"
STUB
    chmod 755 "$dir/gum"
done
tar -czf "$WORK/x86_64.tar.gz" -C "$WORK/pkg" "gum_${pinned_version}_Linux_x86_64"
tar -czf "$WORK/arm64.tar.gz" -C "$WORK/pkg" "gum_${pinned_version}_Linux_arm64"
head -c 100 "$WORK/x86_64.tar.gz" > "$WORK/truncated.tar.gz"
fixture_x86=$(sha256sum < "$WORK/x86_64.tar.gz" | cut -d' ' -f1)
fixture_arm=$(sha256sum < "$WORK/arm64.tar.gz" | cut -d' ' -f1)

# curl writes the tarball STUB_TARBALL names to its -o path and logs the URL.
# STUB_STALL=connect or transfer stands for a server that accepts nothing,
# or stops sending: curl gives up (exit 28) when it was given the matching
# limit, and otherwise waits for ever.
cat > "$WORK/stub/curl" <<'STUB'
#!/bin/bash
out=''
url=''
connect_timeout=''
max_time=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift ;;
        --connect-timeout) connect_timeout=$2; shift ;;
        --max-time|-m) max_time=$2; shift ;;
        http*) url=$1 ;;
    esac
    shift
done
printf '%s\n' "$url" >> "$CURL_LOG"
printf 'connect-timeout=%s max-time=%s\n' "$connect_timeout" "$max_time" >> "$CURL_LOG.limits"
case ${STUB_STALL:-} in
    connect) [ -n "$connect_timeout" ] && exit 28; exec sleep 3600 ;;
    transfer) [ -n "$max_time" ] && exit 28; exec sleep 3600 ;;
esac
[ -n "${STUB_TARBALL:-}" ] || exit 22
cat "$STUB_TARBALL" > "$out"
STUB
# shellcheck disable=SC2016  # Expanded by the stub.
printf '#!/bin/sh\necho "${STUB_ARCH:-x86_64}"\n' > "$WORK/stub/uname"
chmod 755 "$WORK/stub/curl" "$WORK/stub/uname"

# run_install <case> [extra PATH dir]: install_gum with the fixture's
# sha256, into the install directory of the case, with a TMPDIR of its own
# where nothing may run; prints rc=<status> and the GUM_BIN it leaves (a
# value set beforehand must not survive).
run_install() {
    local name=$1 extra=${2:-}
    mkdir -p "$WORK/$name/bin" "$WORK/$name/tmp"
    : > "$WORK/$name/curl.log"
    # shellcheck disable=SC2016
    PATH="$WORK/stub:${extra:+$extra:}$WORK/$name/bin:$WORK/min" \
        TMPDIR="$WORK/$name/tmp" NOEXEC_DIR="$WORK/$name/tmp" CURL_LOG="$WORK/$name/curl.log" \
        "$TIMEOUT" 20 "$WORK/min/bash" -c '
            source "$1"
            GUM_SHA256_X86_64=$2
            GUM_SHA256_ARM64=$3
            GUM_BIN=/set/before
            install_gum "$4"
            echo "rc=$?"
            echo "gum_bin=$GUM_BIN"
        ' _ "$WORK/gum.sh" "$fixture_x86" "$fixture_arm" "$WORK/$name/bin" 2>&1
    echo "exit=$?"
}

# gum_bin_is <case output> <expected>: the GUM_BIN install_gum left.
gum_bin_is() {
    grep -qxF "gum_bin=$2" <<< "$1"
}

no_leftovers() {
    [ -z "$(ls -A "$WORK/$1/tmp")" ] || fail "$1: the download directory was left behind: $(ls -A "$WORK/$1/tmp")"
    [ ! -e "$WORK/$1/bin/.gum.partial" ] || fail "$1: a partial gum was left in the install directory"
}

# A truncated download installs nothing.
out=$(STUB_TARBALL="$WORK/truncated.tar.gz" run_install truncated)
grep -qx 'rc=1' <<< "$out" || fail "a truncated download must fail install_gum, got: $out"
[ ! -e "$WORK/truncated/bin/gum" ] || fail "a truncated download must not leave a gum in the install directory"
gum_bin_is "$out" '' || fail "a failed install must leave GUM_BIN empty, got: $out"
no_leftovers truncated
pass "a truncated download leaves no gum behind"

# A complete tarball that is not the pinned one installs nothing.
out=$(STUB_TARBALL="$WORK/arm64.tar.gz" run_install mismatch)
grep -qx 'rc=1' <<< "$out" || fail "a tarball with another sha256 must be refused, got: $out"
[ ! -e "$WORK/mismatch/bin/gum" ] || fail "a tarball with another sha256 must not be installed"
no_leftovers mismatch
pass "a tarball that does not match its pinned sha256 is refused"

# Every case has a TMPDIR where nothing may run, like one mounted noexec:
# the downloaded gum must run from the install directory, where it ends up.
# It used to run from the download directory, and on such a host gum was
# never installed.
out=$(STUB_TARBALL="$WORK/x86_64.tar.gz" run_install noexec)
grep -qx 'rc=0' <<< "$out" || fail "a TMPDIR mounted noexec must not keep gum from installing, got: $out"
"$WORK/noexec/bin/gum" --version | grep -q "v$pinned_version" || fail "the gum installed past a noexec TMPDIR must run"
no_leftovers noexec
pass "nothing runs from TMPDIR, so a noexec one does not keep gum away"

# The pinned tarball is installed, executable, from the pinned release URL.
out=$(STUB_TARBALL="$WORK/x86_64.tar.gz" run_install verified)
grep -qx 'rc=0' <<< "$out" || fail "the pinned tarball must install, got: $out"
gum_bin_is "$out" "$WORK/verified/bin/gum" || fail "the installed gum must be the one GUM_BIN names, got: $out"
[ "$(stat -c %a "$WORK/verified/bin/gum")" = 755 ] || fail "the installed gum must be mode 755"
"$WORK/verified/bin/gum" --version | grep -q "v$pinned_version" || fail "the installed gum must run"
grep -qx "https://github.com/charmbracelet/gum/releases/download/v${pinned_version}/gum_${pinned_version}_Linux_x86_64.tar.gz" \
    "$WORK/verified/curl.log" || fail "the pinned release must be downloaded, got: $(cat "$WORK/verified/curl.log")"
no_leftovers verified
pass "the pinned tarball is checked, run and installed"

# A tarball whose gum does not run, even with a matching sha256, is not
# installed.
mkdir -p "$WORK/pkg-broken/gum_${pinned_version}_Linux_x86_64"
printf '#!/bin/sh\nexit 139\n' > "$WORK/pkg-broken/gum_${pinned_version}_Linux_x86_64/gum"
chmod 755 "$WORK/pkg-broken/gum_${pinned_version}_Linux_x86_64/gum"
tar -czf "$WORK/broken.tar.gz" -C "$WORK/pkg-broken" "gum_${pinned_version}_Linux_x86_64"
out=$(fixture_x86=$(sha256sum < "$WORK/broken.tar.gz" | cut -d' ' -f1) STUB_TARBALL="$WORK/broken.tar.gz" run_install broken)
grep -qx 'rc=1' <<< "$out" || fail "a gum that does not run must not be installed, got: $out"
[ ! -e "$WORK/broken/bin/gum" ] || fail "a gum that does not run must not reach the install directory"
no_leftovers broken
pass "a downloaded gum must run before it is installed"

# An install interrupted while it writes (a full disk): the copy goes to a
# temporary name and only a complete one is renamed to gum.
mkdir -p "$WORK/interrupted-stub"
cat > "$WORK/interrupted-stub/install" <<'STUB'
#!/bin/bash
destination=${*: -1}
head -c 10 "${*: -2:1}" > "$destination"
exit 1
STUB
chmod 755 "$WORK/interrupted-stub/install"
out=$(STUB_TARBALL="$WORK/x86_64.tar.gz" run_install interrupted "$WORK/interrupted-stub")
grep -qx 'rc=1' <<< "$out" || fail "an interrupted install must fail, got: $out"
[ ! -e "$WORK/interrupted/bin/gum" ] || fail "an interrupted install must not leave a partial gum"
no_leftovers interrupted
pass "an interrupted install leaves no partial gum"

out=$(STUB_ARCH=aarch64 STUB_TARBALL="$WORK/arm64.tar.gz" run_install arm)
grep -qx 'rc=0' <<< "$out" || fail "the arm64 tarball must install with its own sha256, got: $out"
grep -q '_Linux_arm64\.tar\.gz$' "$WORK/arm/curl.log" || fail "aarch64 must download the arm64 tarball"
out=$(STUB_ARCH=riscv64 STUB_TARBALL="$WORK/x86_64.tar.gz" run_install other-arch)
grep -qx 'rc=1' <<< "$out" || fail "an architecture without a release must fail, got: $out"
[ ! -s "$WORK/other-arch/curl.log" ] || fail "an architecture without a release must download nothing"
pass "each architecture gets its own tarball, and an unknown one none"

# The truncated gum an older release left in the install directory: it is
# replaced, not trusted.
mkdir -p "$WORK/left/bin"
printf '#!/bin/sh\nkill -SEGV $$\n' > "$WORK/left/bin/gum"
chmod 755 "$WORK/left/bin/gum"
out=$(STUB_TARBALL="$WORK/x86_64.tar.gz" run_install left)
grep -qx 'rc=0' <<< "$out" || fail "a gum that does not run must be replaced, got: $out"
"$WORK/left/bin/gum" --version | grep -q "v$pinned_version" || fail "the broken gum must be replaced by the pinned one"
pass "a gum that does not run in the install directory is replaced"

# When the replacement cannot be downloaded, the broken one is gone, so the
# plain-text output is used instead of a crash.
mkdir -p "$WORK/left-offline/bin"
printf '#!/bin/sh\nkill -SEGV $$\n' > "$WORK/left-offline/bin/gum"
chmod 755 "$WORK/left-offline/bin/gum"
out=$(run_install left-offline)
grep -qx 'rc=1' <<< "$out" || fail "an offline replacement must fail install_gum, got: $out"
[ ! -e "$WORK/left-offline/bin/gum" ] || fail "a gum that does not run must not stay in the install directory"
pass "a broken gum is removed even when no replacement can be downloaded"

# A gum that runs is kept, and nothing is downloaded.
mkdir -p "$WORK/working/bin"
cp -p "$WORK/left/bin/gum" "$WORK/working/bin/gum"
out=$(STUB_TARBALL="$WORK/x86_64.tar.gz" run_install working)
grep -qx 'rc=0' <<< "$out" || fail "a working gum must be kept, got: $out"
[ ! -s "$WORK/working/curl.log" ] || fail "a working gum must not be downloaded again"
gum_bin_is "$out" "$WORK/working/bin/gum" || fail "a working gum must be the one GUM_BIN names, got: $out"

# A gum that does not run outside the install directory is not touched.
mkdir -p "$WORK/foreign-gum"
printf '#!/bin/sh\nexit 139\n' > "$WORK/foreign-gum/gum"
chmod 755 "$WORK/foreign-gum/gum"
out=$(STUB_TARBALL="$WORK/x86_64.tar.gz" run_install foreign "$WORK/foreign-gum")
grep -qx 'rc=1' <<< "$out" || fail "a broken gum elsewhere must be reported, got: $out"
[ -e "$WORK/foreign-gum/gum" ] || fail "a gum outside the install directory must not be removed"
[ ! -s "$WORK/foreign/curl.log" ] || fail "nothing must be downloaded over a gum of another installation"
gum_bin_is "$out" '' || fail "a broken gum elsewhere must leave GUM_BIN empty, got: $out"
pass "a working gum is kept, and one outside the install directory is left alone"

# Where the setup installs: /usr/local/bin, which no environment variable
# changes (a GUM_INSTALL_DIR once decided where this root script wrote and
# what it removed). Only the argument the tests pass names another place.
# install and rm are stand-ins here that log and touch nothing.
mkdir -p "$WORK/default-dir/stub" "$WORK/default-dir/tmp" "$WORK/elsewhere"
for tool in install rm; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$tool" "$WORK/default-dir/calls" > "$WORK/default-dir/stub/$tool"
    chmod 755 "$WORK/default-dir/stub/$tool"
done
# shellcheck disable=SC2016
PATH="$WORK/default-dir/stub:$WORK/stub:$WORK/min" TMPDIR="$WORK/default-dir/tmp" CURL_LOG="$WORK/default-dir/curl.log" \
    STUB_TARBALL="$WORK/x86_64.tar.gz" GUM_INSTALL_DIR="$WORK/elsewhere" \
    "$TIMEOUT" 20 "$WORK/min/bash" -c 'source "$1"; GUM_SHA256_X86_64=$2; install_gum; echo "rc=$?"' \
    _ "$WORK/gum.sh" "$fixture_x86" > "$WORK/default-dir/out" 2>&1
grep -qx 'rc=1' "$WORK/default-dir/out" || fail "the stand-in install must fail the default install, got: $(cat "$WORK/default-dir/out")"
grep -q "^install .* /usr/local/bin/\.gum\.partial\$" "$WORK/default-dir/calls" ||
    fail "install_gum must install into /usr/local/bin by default, got: $(cat "$WORK/default-dir/calls")"
{ ! grep -q "$WORK/elsewhere" "$WORK/default-dir/calls" && [ -z "$(ls -A "$WORK/elsewhere")" ]; } ||
    fail "no environment variable may move the install directory, got: $(cat "$WORK/default-dir/calls")"
pass "gum goes to /usr/local/bin, and only an argument names another directory"

# A download that stalls, while connecting or once started, gives up after
# a bounded time instead of holding the setup in silence (install_gum runs
# with its output hidden, before the first question).
for stall in connect transfer; do
    out=$(STUB_STALL=$stall STUB_TARBALL="$WORK/x86_64.tar.gz" run_install "stall-$stall")
    grep -qx 'exit=124' <<< "$out" && fail "a download that stalls while it ${stall}s must not hang install_gum"
    grep -qx 'rc=1' <<< "$out" || fail "a stalled download ($stall) must fail install_gum, got: $out"
    [ ! -e "$WORK/stall-$stall/bin/gum" ] || fail "a stalled download ($stall) must install nothing"
    no_leftovers "stall-$stall"
done
read -r connect_limit transfer_limit < <(sed -E 's/connect-timeout=([0-9]*) max-time=([0-9]*)/\1 \2/' "$WORK/verified/curl.log.limits")
{ [[ "$connect_limit" =~ ^[0-9]+$ ]] && (( connect_limit <= 30 )); } ||
    fail "the connection must give up within 30 seconds, got: $(cat "$WORK/verified/curl.log.limits")"
{ [[ "$transfer_limit" =~ ^[0-9]+$ ]] && (( transfer_limit <= 300 )); } ||
    fail "the download must give up within 5 minutes, got: $(cat "$WORK/verified/curl.log.limits")"
pass "a stalled download gives up after a bounded time"

# The helpers that draw with gum (run_step and the progress boxes), and the
# check at the top of the script that sets GUM_BIN for runs that install
# nothing (--resume-import). They used to take any gum command -v found: a
# broken one outside the install directory, which install_gum leaves alone,
# failed every step and ended the setup at the first progress box.
{
    awk '/^# The gum run_step and the progress boxes draw with/ { capture = 1 } capture { print } capture && /^fi$/ { exit }' \
        "$ROOT_DIR/docker/setup.sh" > "$WORK/gum-check.sh"
    for helper in report_step_failure run_step progress_bar progress_header progress_success; do
        awk -v name="$helper" '$0 == name "() {" { capture = 1 } capture { print } capture && /^}$/ { exit }' \
            "$ROOT_DIR/docker/setup.sh"
    done
} > "$WORK/helpers.sh"
grep -q '^GUM_BIN=' "$WORK/gum-check.sh" || fail "the GUM_BIN check is not where the test expects it in docker/setup.sh"
for helper in report_step_failure run_step progress_bar progress_header progress_success; do
    grep -q "^${helper}() {" "$WORK/helpers.sh" || fail "$helper is not defined in docker/setup.sh"
done

# A gum that logs every call; broken, it fails each one like a truncated one.
mkdir -p "$WORK/gum-broken" "$WORK/gum-working"
cat > "$WORK/gum-broken/gum" <<'STUB'
#!/bin/sh
echo "$*" >> "$GUM_LOG"
exit 2
STUB
cat > "$WORK/gum-working/gum" <<'STUB'
#!/bin/sh
echo "$*" >> "$GUM_LOG"
[ "$1" = spin ] || exit 0
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
STUB
chmod 755 "$WORK/gum-broken/gum" "$WORK/gum-working/gum"

# run_helpers <case> <how GUM_BIN is set: install|check> [gum dir]: the
# helpers under set -e, as the setup calls them, once GUM_BIN is set by
# install_gum (offline here) or by the check at the top of the script.
run_helpers() {
    local name=$1 how=$2 gum_dir=${3:-}
    mkdir -p "$WORK/$name/bin" "$WORK/$name/tmp"
    : > "$WORK/$name/gum.log"
    # shellcheck disable=SC2016
    PATH="$WORK/stub:${gum_dir:+$gum_dir:}$WORK/min" GUM_LOG="$WORK/$name/gum.log" \
        TMPDIR="$WORK/$name/tmp" CURL_LOG="$WORK/$name/curl.log" STEP_MARK="$WORK/$name/step-ran" \
        "$TIMEOUT" 20 "$WORK/min/bash" -c '
            set -e
            GREEN= RED= CYAN= NC= DEBUG_LOG=/dev/null PROGRESS_TOTAL=2 PROGRESS_CURRENT=0
            GUM_BIN=/set/before
            source "$1"
            source "$2"
            if [ "$4" = install ]; then
                source "$3"
                GUM_SHA256_X86_64=$7
                install_gum "$5" >/dev/null 2>&1 || true
            else
                source "$6"
            fi
            echo "gum_bin=$GUM_BIN"
            progress_header "Setup" "Subtitle"
            progress_bar "First step"
            run_step "A step" sh -c ": > \"\$STEP_MARK\""
            progress_success "Done"
            echo "reached the end"
        ' _ "$WORK/helpers.sh" /dev/null "$WORK/gum.sh" "$how" "$WORK/$name/bin" "$WORK/gum-check.sh" "$fixture_x86" 2>&1
    echo "exit=$?"
}

# plain_text_only <case> <output>: the run went through on plain text, ran
# its step, and never called gum past the --version that tried it.
plain_text_only() {
    grep -qx 'exit=0' <<< "$2" || fail "$1: the setup must go on with plain text, got: $2"
    grep -qx 'reached the end' <<< "$2" || fail "$1: the setup must reach its end, got: $2"
    [ -e "$WORK/$1/step-ran" ] || fail "$1: the step must run without gum"
    grep -q 'A step\.\.\. ✓' <<< "$2" || fail "$1: the step must be reported in plain text, got: $2"
    ! grep -vqx -- '--version' "$WORK/$1/gum.log" || fail "$1: a gum that does not run must not draw, got: $(cat "$WORK/$1/gum.log")"
}

out=$(run_helpers broken-elsewhere install "$WORK/gum-broken")
gum_bin_is "$out" '' || fail "a broken gum elsewhere must leave GUM_BIN empty, got: $out"
plain_text_only broken-elsewhere "$out"
pass "a broken gum that install_gum cannot replace gets plain text, not a crash"

out=$(run_helpers check-broken check "$WORK/gum-broken")
gum_bin_is "$out" '' || fail "the check must not keep a gum that does not run, got: $out"
plain_text_only check-broken "$out"
out=$(run_helpers check-none check)
gum_bin_is "$out" '' || fail "the check must leave GUM_BIN empty without gum, got: $out"
plain_text_only check-none "$out"
pass "a run that installs nothing draws with gum only when it runs"

# The gum install_gum has just installed draws the run even when its
# directory is not on the PATH: the helpers call the one GUM_BIN names.
out=$(STUB_TARBALL="$WORK/x86_64.tar.gz" run_helpers installed install)
gum_bin_is "$out" "$WORK/installed/bin/gum" || fail "the installed gum must be the one GUM_BIN names, got: $out"
{ grep -qx 'exit=0' <<< "$out" && grep -qx 'reached the end' <<< "$out"; } ||
    fail "the gum install_gum installed must draw the run, wherever the PATH looks, got: $out"
[ -e "$WORK/installed/step-ran" ] || fail "the step must run through the installed gum"
grep -q '  ✓ A step$' <<< "$out" || fail "the step must be drawn by gum spin, got: $out"
pass "the helpers draw with the gum install_gum installed, by its path"

out=$(run_helpers check-working check "$WORK/gum-working")
gum_bin_is "$out" "$WORK/gum-working/gum" || fail "the check must keep a gum that runs, got: $out"
{ grep -qx 'exit=0' <<< "$out" && grep -qx 'reached the end' <<< "$out"; } || fail "a working gum must draw the run, got: $out"
[ -e "$WORK/check-working/step-ran" ] || fail "the step must run through gum spin"
{ grep -q '^spin ' "$WORK/check-working/gum.log" && grep -q '^style ' "$WORK/check-working/gum.log"; } ||
    fail "a gum that runs must draw the steps and boxes, got: $(cat "$WORK/check-working/gum.log")"
pass "a gum that runs draws the steps and the progress boxes"
