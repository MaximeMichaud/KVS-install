#!/bin/bash
# The look at the kernel after the last pass of an import: a kernel worker
# moving the inodes of a removed cgroup (inode_switch_wbs) in at least
# half of the looks, or at least half of the CPU time in the kernel, gets
# a warning with the commands of the recovery, run from the docker
# directory; anything less gets one line. The kernel is a fixture here:
# IMPORT_PROC_ROOT and IMPORT_CGROUP_ROOT point at files the test writes,
# and sleep moves the fixture on by one second. Before all that, the
# preflight of the setup says whether the running kernel has the two
# writeback fixes of 7.2.9, from its release string, without a question:
# a warning for an import, a plain line for any other run.
# shellcheck disable=SC2016,SC2329  # Literal code of setup.sh; sleep is called by the code under test.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-writeback-check.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

export IMPORT_PROC_ROOT="$TEST_DIR/proc" IMPORT_CGROUP_ROOT="$TEST_DIR/cgroup"
mkdir -p "$IMPORT_PROC_ROOT/1" "$IMPORT_PROC_ROOT/2" "$IMPORT_PROC_ROOT/3" "$IMPORT_PROC_ROOT/77" "$IMPORT_CGROUP_ROOT"
echo systemd > "$IMPORT_PROC_ROOT/1/comm"
echo 'kworker/u24:0+events_unbound' > "$IMPORT_PROC_ROOT/2/comm"
# A process that only carries the name is no kernel worker.
echo inode_switch_wbs > "$IMPORT_PROC_ROOT/3/comm"
echo '17.25 12.50 8.75 3/456 7890' > "$IMPORT_PROC_ROOT/loadavg"

# The fixture of one second: 1000 ticks, KERNEL_SHARE percent of them in
# the kernel (system, irq and softirq), and the worker of pid 77 running
# an inode switch when the character of PATTERN for this look is 1.
PATTERN=00000
KERNEL_SHARE=10
look=0
user=1000 system=60 idle=8900 irq=20 softirq=20
write_stat() {
    printf 'cpu  %s 0 %s %s 0 %s %s 0 0 0\ncpu0 1 0 1 1 0 0 0 0 0 0\n' "$user" "$system" "$idle" "$irq" "$softirq" \
        > "$IMPORT_PROC_ROOT/stat"
}
sleep() {
    look=$((look + 1))
    system=$((system + KERNEL_SHARE * 10))
    user=$((user + 100))
    idle=$((idle + 900 - KERNEL_SHARE * 10))
    [ -n "${NO_STAT:-}" ] || write_stat
    if [ "${PATTERN:look-1:1}" = 1 ]; then
        echo 'kworker/u24:3+inode_switch_wbs' > "$IMPORT_PROC_ROOT/77/comm"
    else
        echo 'kworker/u24:3-inode_switch_wbs' > "$IMPORT_PROC_ROOT/77/comm"
    fi
}
# check <pattern> <kernel share> <dying before> [directory]: runs the look
# into $TEST_DIR/out and leaves its status in $status.
check() {
    PATTERN=$1 KERNEL_SHARE=$2 look=0
    write_stat
    echo 'kworker/u24:3-inode_switch_wbs' > "$IMPORT_PROC_ROOT/77/comm"
    status=0
    import_writeback_check "$3" 5 "${4:-/opt/kvs/docker}" > "$TEST_DIR/out" || status=$?
}

printf 'nr_descendants 40\nnr_dying_descendants 12\nnr_dying_subsys_memory 9\n' > "$IMPORT_CGROUP_ROOT/cgroup.stat"
[ "$(import_writeback_dying)" = 9 ] || fail "the removed cgroups must count their memory controllers when the kernel shows them, got '$(import_writeback_dying)'"
printf 'nr_descendants 40\nnr_dying_descendants 12\n' > "$IMPORT_CGROUP_ROOT/cgroup.stat"
[ "$(import_writeback_dying)" = 12 ] || fail "an older kernel must give the removed cgroups, got '$(import_writeback_dying)'"
rm "$IMPORT_CGROUP_ROOT/cgroup.stat"
if import_writeback_dying > "$TEST_DIR/out"; then fail 'a host without cgroup v2 must report no count'; fi
[ ! -s "$TEST_DIR/out" ] || fail 'a host without cgroup v2 must print nothing'
echo 'PASS: the removed cgroups come from cgroup.stat, per memory controller when the kernel counts them'

echo 'kworker/u24:3+inode_switch_wbs' > "$IMPORT_PROC_ROOT/77/comm"
[ "$(import_writeback_switching)" = 1 ] || fail 'a kworker running an inode switch must count'
echo 'kworker/u24:3-inode_switch_wbs' > "$IMPORT_PROC_ROOT/77/comm"
[ "$(import_writeback_switching)" = 0 ] || fail 'a kworker done with its inode switch, another workqueue or a plain process must not count'
write_stat
[ "$(import_cpu_ticks)" = '100 10000' ] || fail "the kernel ticks are system, irq and softirq, got '$(import_cpu_ticks)'"
# A host with very many processes: their comm paths together exceed what
# one exec takes (ARG_MAX, at most 6 MiB), so they must reach cat in
# batches. Long paths make a few thousand entries enough here.
many=$TEST_DIR
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    many="$many/$(printf 'p%.0s' {1..250})"
done
mapfile -t pids < <(seq 100000 $((100000 + 6 * 1048576 / (${#many} + 12) + 50)))
printf '%s\0' "${pids[@]/#/$many/}" | xargs -0 mkdir -p
for pid in "${pids[@]}"; do
    echo bash > "$many/$pid/comm"
done
echo 'kworker/u24:3+inode_switch_wbs' > "$many/${pids[-1]}/comm"
[ "$(IMPORT_PROC_ROOT=$many import_writeback_switching)" = 1 ] ||
    fail "the workers of ${#pids[@]} processes must be counted, got '$(IMPORT_PROC_ROOT=$many import_writeback_switching)'"
echo 'PASS: the switching workers and the kernel time are read from /proc, for any number of processes'

printf 'nr_dying_descendants 12\nnr_dying_subsys_memory 9\n' > "$IMPORT_CGROUP_ROOT/cgroup.stat"
check 00000 10 4
[ "$status" -eq 0 ] || fail 'a quiet kernel must not warn'
grep -Fxq '  Kernel after the import: inodes moving between cgroups (inode_switch_wbs) in 0 of 5 looks, 10% of the CPU time in the kernel, 9 removed cgroups wait to be freed (4 when the KVS init started).' "$TEST_DIR/out" ||
    fail "a quiet kernel must be one line: $(cat "$TEST_DIR/out")"
[ "$look" -eq 5 ] || fail "five seconds must give five looks, got $look"
check 11000 20 4
[ "$status" -eq 0 ] || fail 'a move seen in two looks of five is short and must not warn'
grep -Fq 'in 2 of 5 looks, 20% of the CPU time in the kernel' "$TEST_DIR/out" || fail 'a short move must still be reported'
echo 'PASS: a quiet kernel and a short move get one line'

check 11100 20 4
[ "$status" -eq 1 ] || fail 'a move seen in three looks of five must warn'
grep -Fxq 'WARNING: the kernel is still busy after the import: inodes moving between cgroups (inode_switch_wbs) in 3 of 5 looks, 20% of the CPU time in the kernel, load 17.25 on '"$(nproc)"' CPUs, 9 removed cgroups wait to be freed (4 when the KVS init started).' "$TEST_DIR/out" ||
    fail "the warning must say what was seen: $(head -n 1 "$TEST_DIR/out")"
for line in \
    '    cd /opt/kvs/docker && ./reconfigure.sh --writeback-status' \
    '    cd /opt/kvs/docker' \
    '    docker compose stop cron manticore nginx php-fpm' \
    '    docker compose stop -t 600 mariadb' \
    '    systemctl reboot' \
    '    cd /opt/kvs/docker && docker compose start'; do
    grep -Fxq -- "$line" "$TEST_DIR/out" || fail "the warning must give the command '$line'"
done
[ "$(grep -n 'stop cron manticore nginx php-fpm' "$TEST_DIR/out" | cut -d: -f1)" -lt "$(grep -n 'stop -t 600 mariadb' "$TEST_DIR/out" | cut -d: -f1)" ] ||
    fail 'the services that use the database must stop before MariaDB'
grep -Fq 'Never write 2 or 3 to /proc/sys/vm/drop_caches meanwhile' "$TEST_DIR/out" ||
    fail 'the warning must keep drop_caches 2 and 3, which add to the contention, out of the recovery'
section=$(sed -n 's/.*README.md, "\([^"]*\)".*/\1/p' "$TEST_DIR/out")
if [ -z "$section" ] || ! grep -Fq "#### $section" "$ROOT_DIR/README.md"; then
    fail "the warning must name a section of README.md, got '$section'"
fi
check 00000 60 ''
[ "$status" -eq 1 ] || fail 'most of the CPU time in the kernel must warn without a worker seen'
grep -Fq 'in 0 of 5 looks, 60% of the CPU time in the kernel, load 17.25 on' "$TEST_DIR/out" || fail 'the kernel time must be reported'
grep -Fq '9 removed cgroups wait to be freed.' "$TEST_DIR/out" || fail 'no count before the look gives the count alone'
echo 'PASS: a lasting move or a kernel that takes the CPUs gets the warning and the recovery in order'

check 11111 10 4 '/srv/kvs install/docker'
grep -Fxq '    cd /srv/kvs\ install/docker' "$TEST_DIR/out" || fail 'a docker directory with a space must be quoted for the shell'
rm "$IMPORT_CGROUP_ROOT/cgroup.stat" "$IMPORT_PROC_ROOT/stat"
PATTERN=00000 look=0 NO_STAT=yes
status=0
import_writeback_check '' 5 /opt/kvs/docker > "$TEST_DIR/out" || status=$?
NO_STAT=''
[ "$status" -eq 0 ] || fail 'without cgroup.stat and /proc/stat a quiet look must not warn'
grep -Fxq '  Kernel after the import: inodes moving between cgroups (inode_switch_wbs) in 0 of 5 looks.' "$TEST_DIR/out" ||
    fail "what cannot be read must be left out: $(cat "$TEST_DIR/out")"
echo 'PASS: the commands are quoted for the shell and what cannot be read is left out'

# The setup takes the count before the init, the step that walks every
# file in a container removed at its end, and looks once the site runs.
SETUP="$ROOT_DIR/docker/setup.sh"
baseline=$(grep -n 'IMPORT_WRITEBACK_DYING=$(import_writeback_dying)' "$SETUP" | cut -d: -f1) || true
init=$(grep -n 'run --rm --no-deps "${SETUP_RUN_FLAGS\[@\]}" kvs-init$' "$SETUP" | cut -d: -f1) || true
cron=$(grep -n '^setup_start_cron$' "$SETUP" | cut -d: -f1) || true
look_at=$(grep -n 'import_writeback_check "$IMPORT_WRITEBACK_DYING" 5 "$PWD"' "$SETUP" | cut -d: -f1) || true
for line in "$baseline" "$init" "$cron" "$look_at"; do
    [[ "$line" =~ ^[0-9]+$ ]] || fail "the setup must count once before the init and look once at the end ($baseline $init $cron $look_at)"
done
if [ "$baseline" -gt "$init" ] || [ "$init" -gt "$cron" ] || [ "$cron" -gt "$look_at" ]; then
    fail "the count must precede the init and the look must follow the start of cron ($baseline $init $cron $look_at)"
fi
grep -B 1 'IMPORT_WRITEBACK_DYING=$(import_writeback_dying)' "$SETUP" | grep -Fq 'if [ "$IMPORT_MODE" = true ]' ||
    fail 'the count is for an import only'
grep -Fq 'if [ "$IMPORT_MODE" = true ] && declare -F import_writeback_check >/dev/null; then' "$SETUP" ||
    fail 'the look is for an import only'
echo 'PASS: the setup counts the removed cgroups before the init and looks once cron runs'

# reconfigure.sh looks again at any time, from the docker directory.
mkdir -p "$TEST_DIR/docker/lib"
cp "$ROOT_DIR/docker/reconfigure.sh" "$TEST_DIR/docker/"
cp "$ROOT_DIR/docker/lib/import.sh" "$TEST_DIR/docker/lib/"
touch "$TEST_DIR/docker/docker-compose.yml"
printf 'DOMAIN=example.com\nMARIADB_PASSWORD=test-only\n' > "$TEST_DIR/docker/.env"
printf 'nr_dying_subsys_memory 3\n' > "$IMPORT_CGROUP_ROOT/cgroup.stat"
printf 'cpu  1000 0 100 8900 0 0 0 0 0 0\n' > "$IMPORT_PROC_ROOT/stat"
echo 'kworker/u24:3+inode_switch_wbs' > "$IMPORT_PROC_ROOT/77/comm"
# The look of a fresh process: its own sleep, one that does not wait.
reconfigure() (
    cd "$TEST_DIR/docker"
    sleep() { :; }
    export -f sleep
    bash reconfigure.sh "$@"
)
status=0
reconfigure --writeback-status > "$TEST_DIR/out" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "a busy kernel must make reconfigure.sh exit 1, got $status: $(cat "$TEST_DIR/out")"
grep -Fq "    cd $TEST_DIR/docker && docker compose start" "$TEST_DIR/out" || fail 'reconfigure.sh must name its own directory'
grep -Fq '3 removed cgroups wait to be freed.' "$TEST_DIR/out" || fail 'reconfigure.sh has no count from before'
echo 'kworker/u24:3-inode_switch_wbs' > "$IMPORT_PROC_ROOT/77/comm"
reconfigure --writeback-status > "$TEST_DIR/out" 2>&1 || fail "a quiet kernel must make reconfigure.sh exit 0: $(cat "$TEST_DIR/out")"
grep -Fq 'in 0 of 5 looks' "$TEST_DIR/out" || fail 'reconfigure.sh must report the look'
if reconfigure --writeback-status --import-status > /dev/null 2>&1; then fail 'reconfigure.sh must take one operation'; fi
reconfigure --help > "$TEST_DIR/out"
grep -Fq -- '--writeback-status' "$TEST_DIR/out" || fail 'the help of reconfigure.sh must list --writeback-status'
echo 'PASS: reconfigure.sh --writeback-status looks again from the docker directory'

# The preflight of the setup reads the release of the running kernel: the
# two writeback fixes of 7.2.9 came with 7.3-rc5, 7.2.9, 6.18.55, 6.12.112
# and 6.6.158, the move they fix with 5.14, and a release numbered by its
# distribution (X.Y.0 and a build number) says nothing of its updates nor
# of its backports: RHEL 8 has the move in 4.18.0. A 7.3 release candidate
# can show its number anywhere in the suffix.
awk '
    $0 == "preflight_kernel_writeback_status() {" || $0 == "preflight_kernel_writeback_warning() {" ||
        $0 == "preflight_checks() {" || $0 == "select_import_source() {" { capture = 1 }
    capture { print }
    capture && /^}$/ { capture = 0 }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/preflight.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/preflight.sh"
declare -F preflight_kernel_writeback_status preflight_kernel_writeback_warning preflight_checks select_import_source > /dev/null ||
    fail 'setup.sh must define preflight_kernel_writeback_status, preflight_kernel_writeback_warning, preflight_checks and select_import_source'
while read -r release expected; do
    [ "$release" != - ] || release=''
    got=$(preflight_kernel_writeback_status "$release")
    [ "$got" = "$expected" ] || fail "kernel '$release' must be $expected, got $got"
done << 'EOF'
7.2.8-x64v2-xanmod1 vulnerable
7.2.9-x64v2-xanmod1 fixed
7.2.8-1-custom vulnerable
7.2.10 fixed
7.2.0-arch1-1 vulnerable
6.12.48+deb13-amd64 vulnerable
6.12.112+deb13-amd64 fixed
6.18.54 vulnerable
6.18.55 fixed
6.6.157 vulnerable
6.6.158 fixed
7.3.0-rc4 vulnerable
7.3.0-rc5 fixed
7.3-rc4-amd64 vulnerable
7.3.0-rc4-1-custom-rc vulnerable
7.3.0-rc5-1-custom-rc fixed
7.3.0-1-custom-rc fixed
7.3.0-0.rc4.38.fc44.x86_64 vulnerable
7.3.0-0.rc5.43.fc44.x86_64 fixed
7.3.0-070300rc4-generic vulnerable
7.3.0-070300rc5-generic fixed
7.3.0 fixed
7.3.0-10-generic fixed
7.4.1-arch1-1 fixed
8.0.0 fixed
6.8.0-85-generic unknown
6.18.0-12-generic unknown
6.1.150 unknown
7.1.12 unknown
5.14.0-570.el9.x86_64 unknown
5.10.0-32-amd64 unknown
4.18.0-553.el8_10.x86_64 unknown
5.13.19 unaffected
4.19.0 unaffected
- unknown
not-a-version unknown
EOF
echo 'PASS: the preflight tells a kernel with the writeback fixes of 7.2.9 from one without them'

# The kernel item informs, like the RAM: a run without PREFLIGHT_BYPASS
# and with nothing to read on its input goes on, whatever the kernel. Only
# an import gets the warning; any other run gets a plain line.
preflight() (
    KERNEL=$1
    # shellcheck disable=SC2034  # Read by the extracted preflight_checks.
    CYAN='' GREEN='' RED='' YELLOW='' NC='' DEV_MODE='' PREFLIGHT_BYPASS='' IMPORT_MODE=${2:-false}
    docker() {
        case "$1" in
            --version) echo 'Docker version 29.0.0, build test' ;;
            compose) echo 'Docker Compose version v2.40.0' ;;
        esac
    }
    preflight_free_disk_gb() { echo '40 /'; }
    free() {
        echo '               total        used        free      shared  buff/cache   available'
        echo 'Mem:            8000        1000        5000           0        2000        7000'
    }
    check_internet() { return 0; }
    uname() { echo "$KERNEL"; }
    curl() { :; }
    unzip() { :; }
    ss() { :; }
    preflight_checks < /dev/null
)
preflight 7.2.8-x64v2-xanmod1 true > "$TEST_DIR/out" 2>&1 || fail "a kernel without the fixes must not stop the setup: $(cat "$TEST_DIR/out")"
grep -Fxq '⚠ Kernel: 7.2.8-x64v2-xanmod1 lacks two writeback fixes of 7.2.9 (also in 6.18.55, 6.12.112 and 6.6.158)' "$TEST_DIR/out" ||
    fail "a kernel without the fixes must be named: $(cat "$TEST_DIR/out")"
grep -Fq 'After the last pass of a large site' "$TEST_DIR/out" || fail 'the kernel warning must point at the README section'
grep -Fq '✓ All pre-flight checks passed' "$TEST_DIR/out" || fail 'the kernel warning must not count as a warning that asks to go on'
if grep -Fq 'Continue anyway' "$TEST_DIR/out"; then fail 'the kernel warning must not ask a question'; fi
preflight 7.2.8-x64v2-xanmod1 false > "$TEST_DIR/out" 2>&1 || fail "a kernel without the fixes must not stop the setup: $(cat "$TEST_DIR/out")"
grep -Fxq '  Kernel: 7.2.8-x64v2-xanmod1 (lacks the writeback fixes of 7.2.9, which matter after an import of millions of files)' "$TEST_DIR/out" ||
    fail "a run that imports nothing must get a plain line: $(cat "$TEST_DIR/out")"
if grep -Fq '⚠ Kernel' "$TEST_DIR/out"; then fail 'a run that imports nothing must not get the kernel warning'; fi
preflight 7.2.9-x64v2-xanmod1 > "$TEST_DIR/out" 2>&1 || fail "a kernel with the fixes must pass: $(cat "$TEST_DIR/out")"
grep -Fxq '✓ Kernel: 7.2.9-x64v2-xanmod1' "$TEST_DIR/out" || fail "a kernel with the fixes must pass: $(cat "$TEST_DIR/out")"
preflight 6.1.150 > "$TEST_DIR/out" 2>&1 || fail "an unknown kernel must not stop the setup: $(cat "$TEST_DIR/out")"
grep -Fxq '  Kernel: 6.1.150 (whether it has the writeback fixes of 7.2.9 is not known)' "$TEST_DIR/out" ||
    fail "an unknown kernel must be said to be unknown: $(cat "$TEST_DIR/out")"
echo 'PASS: the kernel item of the preflight warns an import without a question, and informs any other run'

# An import chosen in the questionnaire, after the preflight, gets the
# warning when it is chosen; one the environment chose had it already.
choose() (
    KERNEL=$1
    # shellcheck disable=SC2034  # Read by the extracted select_import_source.
    CYAN='' GREEN='' RED='' YELLOW='' NC='' HEADLESS=$2 IMPORT_SOURCE=$3 IMPORT_MODE=$4
    # shellcheck disable=SC2034  # Read by the extracted select_import_source.
    IMPORT_CHOICE=2 IMPORT_ARCHIVE=/srv/old-site.zip
    uname() { echo "$KERNEL"; }
    import_check_completed() { :; }
    import_validate_site() { :; }
    import_inspect_archive() { echo 'archive inspected'; }
    import_check_kvs_archive_version() { :; }
    refuse_unbuildable_kvs_php() { :; }
    import_record_source_domain() { :; }
    import_check_domain() { :; }
    import_confirm() { :; }
    select_import_source < /dev/null
)
choose 7.2.8-x64v2-xanmod1 '' '' false > "$TEST_DIR/out" 2>&1 || fail "the questionnaire must go on: $(cat "$TEST_DIR/out")"
[ "$(grep -c '^⚠ Kernel: 7.2.8-x64v2-xanmod1 lacks two writeback fixes of 7.2.9' "$TEST_DIR/out")" -eq 1 ] ||
    fail "an import chosen in the questionnaire must get the kernel warning once: $(cat "$TEST_DIR/out")"
grep -Fxq 'archive inspected' "$TEST_DIR/out" || fail "the import must go on after the warning: $(cat "$TEST_DIR/out")"
choose 7.2.9-x64v2-xanmod1 '' '' false > "$TEST_DIR/out" 2>&1 || fail "the questionnaire must go on: $(cat "$TEST_DIR/out")"
if grep -Fq 'Kernel' "$TEST_DIR/out"; then fail "a kernel with the fixes needs no word after the choice: $(cat "$TEST_DIR/out")"; fi
choose 7.2.8-x64v2-xanmod1 y archive true > "$TEST_DIR/out" 2>&1 || fail "a headless import must go on: $(cat "$TEST_DIR/out")"
if grep -Fq 'Kernel' "$TEST_DIR/out"; then fail "an import the environment chose had the warning in the preflight: $(cat "$TEST_DIR/out")"; fi
echo 'PASS: an import chosen in the questionnaire gets the kernel warning once'
