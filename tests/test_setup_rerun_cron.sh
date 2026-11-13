#!/bin/bash
# A re-run of docker/setup.sh on an installed site keeps the database and
# recreates MariaDB, then kvs-init clears KVS's cron locks and its cron
# registration (40-configure-database.sh). cron must be stopped before
# either: a cron.php in progress would otherwise lose its lock while it
# runs, and a second one could process the same tasks. The setup stops this
# project only when it sees one of its published ports listening, which it
# does not with Docker's userland proxy off; ss sees nothing here, as there.
#
# The real setup.sh runs, headless, in a copy of docker/ with strict stubs:
# the volume of the earlier run is found and kept (VOLUME_CHOICE=2), and
# database_wait_ready ends the run once MariaDB was recreated. The order of
# the Docker calls must hold with and without gum, and a cron that cannot
# be stopped must stop the setup before MariaDB is touched. A run that ends
# once cron is stopped says so on its way out: cron stays stopped, after a
# reboot too, until it is started again. The exit trap that says it runs
# before the one an import over SSH sets, and the setup clears it once
# cron is started again; its functions are tested on their own below.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/kvs-setup-rerun-cron.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin" "$fixture/gum"
cat > "$fixture/bin/docker" <<'SH'
#!/bin/bash
printf 'docker %s\n' "$*" >> "$CALLS"
case "$*" in
    --version) echo 'Docker version 29.1.0, build stub' ;;
    'compose version') echo 'Docker Compose version v2.40.3' ;;
    # The pre-flight requires the buildx plugin to build the images.
    'buildx version') echo 'github.com/docker/buildx v0.29.1 stub' ;;
    # The MariaDB volume of the earlier run, and the version it holds,
    # which is the series the run selects (DB_CHOICE=1).
    'compose config') printf 'volumes:\n  mariadb-data:\n    name: kvs-rerun_mariadb-data\n' ;;
    'volume ls -q') echo kvs-rerun_mariadb-data ;;
    'run --rm -v kvs-rerun_mariadb-data:/data:ro '*) echo 12.3.3-MariaDB ;;
    info*|ps*|'volume ls'*|'compose config --quiet'|stop*|rm*) exit 0 ;;
    # A checkout: Compose builds every service the setup names.
    'compose config '*)
        echo services:
        printf '  %s:\n    build:\n      context: .\n' "${@:3}"
        ;;
    'compose build'*) ;;
    'compose stop cron')
        echo stop-cron >> "$CALLS"
        exit "${CRON_STOP_STATUS:-0}"
        ;;
    'compose up -d --force-recreate mariadb') echo mariadb-start >> "$CALLS" ;;
    *) echo "unexpected:docker $*" >> "$CALLS"; exit 97 ;;
esac
SH
# gum spin runs its command through sh -c, as run_step calls it.
cat > "$fixture/gum/gum" <<'SH'
#!/bin/bash
case "$1" in
    --version) echo 'gum version v0.17.0' ;;
    style) exit 0 ;;
    spin)
        while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
        [ "$#" -gt 0 ] || exit 97
        shift
        exec "$@"
        ;;
    *) echo "unexpected:gum $*" >> "$CALLS"; exit 97 ;;
esac
SH
cat > "$fixture/bin/blocked" <<'SH'
#!/bin/bash
printf 'unexpected:%s %s\n' "$(basename "$0")" "$*" >> "$CALLS"
exit 97
SH
# The DH parameters of the earlier run are complete and kept.
cat > "$fixture/bin/openssl" <<'SH'
#!/bin/bash
if [ "$1" = dhparam ] && [ "$2" = -check ]; then
    grep -q '^VALID-DHPARAM' "$5" 2>/dev/null
    exit
fi
[ "$1" != dhparam ] || { echo "unexpected:openssl $*" >> "$CALLS"; exit 97; }
exec /usr/bin/openssl "$@"
SH
printf '#!/bin/bash\nexit 7\n' > "$fixture/bin/curl"
# Docker without its userland proxy: no listener for a published port.
printf '#!/bin/bash\nexit 0\n' > "$fixture/bin/ss"
printf '#!/bin/bash\nexit 2\n' > "$fixture/bin/getent"
printf '#!/bin/bash\nexit 1\n' > "$fixture/bin/ufw"
chmod +x "$fixture/bin/"* "$fixture/gum/gum"
for tool in sudo apt apt-get systemctl ssh scp; do
    ln -s blocked "$fixture/bin/$tool"
done

# run_case <name> <with gum: yes|no> [CRON_STOP_STATUS]: a re-run of an
# installed site, the site in place and its database volume kept.
run_case() {
    local dir=$fixture/$1 path=$fixture/bin:/usr/bin:/bin
    [ "$2" = no ] || path=$fixture/gum:$path
    mkdir -p "$dir/logs" "$dir/www/rerun.example.com/admin/include"
    cp -a "$root/docker" "$dir/docker"
    python3 - "$dir/docker/setup.sh" "$dir" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
assert t.count('if [ "$EUID" -ne 0 ]; then') == 1
t = t.replace('if [ "$EUID" -ne 0 ]; then', 'if false; then')
t = t.replace('/opt/kvs/logs', sys.argv[2] + '/logs').replace('/var/www/', sys.argv[2] + '/www/')
p.write_text(t)
PY
    cat >> "$dir/docker/lib/database.sh" <<'SH'
database_configure_resources() { :; }
database_wait_ready() { echo wait >> "$CALLS"; exit 42; }
SH
    printf 'VALID-DHPARAM kept\n' > "$dir/docker/nginx/dhparam.pem"
    cat > "$dir/www/rerun.example.com/admin/include/setup.php" <<'PHP'
<?php
$config['project_path']="/var/www/kvs";
$config['tables_prefix']="ktvs_";
PHP
    printf "<?php\n\$config['project_version']='7.0.2';\n" > "$dir/www/rerun.example.com/admin/include/version.php"
    (
        cd "$dir/docker" || exit 1
        export CALLS="$dir/calls" PATH="$path"
        export HEADLESS=y PREFLIGHT_BYPASS=y SSL_CHOICE=3 GEOIP_CHOICE=2 MANTICORE_CHOICE=2
        export DNS_CHOICE=2 CACHE_CHOICE=1 DB_CHOICE=1 IONCUBE_CHOICE=1 VOLUME_CHOICE=2
        export DOMAIN=rerun.example.com EMAIL=admin@rerun.example.com
        [ -z "${3:-}" ] || export CRON_STOP_STATUS="$3"
        timeout 300 bash ./setup.sh
    ) > "$dir/output.log" 2>&1
    echo $? > "$dir/status"
}

# order <name>: the steps this test follows, in the order they ran.
order() {
    grep -Fx -e stop-cron -e mariadb-start -e wait "$fixture/$1/calls" 2>/dev/null | paste -sd ' '
}

report() {
    { sed 's/\x1b\[[0-9;]*m//g' "$fixture/$1/output.log" | tail -n 15; grep '^unexpected:' "$fixture/$1/calls"; } >&2
    echo "FAIL: $2" >&2
    status=1
}

readonly notice='cron is stopped: docker compose start cron, or re-run setup.sh'

# stopped_notices <name>: how many times the run said cron is stopped.
stopped_notices() {
    sed 's/\x1b\[[0-9;]*m//g' "$fixture/$1/output.log" | grep -Fxc "$notice"
}

status=0
for gum in no yes; do
    name=keep-gum-$gum
    run_case "$name" "$gum"
    if [ "$(cat "$fixture/$name/status")" = 42 ] && [ "$(order "$name")" = 'stop-cron mariadb-start wait' ] &&
        grep -Fq 'Keeping existing database' "$fixture/$name/output.log" &&
        ! grep -q '^unexpected:' "$fixture/$name/calls"; then
        echo "PASS: a re-run that keeps the database stops cron before MariaDB is recreated (gum: $gum)"
    else
        report "$name" "a re-run must stop cron before MariaDB and kvs-init (gum: $gum); steps: $(order "$name")"
    fi
    # The run ended after the stop: its last words say cron is stopped.
    if [ "$(stopped_notices "$name")" = 1 ] &&
        [ "$(sed 's/\x1b\[[0-9;]*m//g' "$fixture/$name/output.log" | grep -v '^[[:space:]]*$' | tail -n 1)" = "$notice" ]; then
        echo "PASS: a run that fails once cron is stopped says so on its way out (gum: $gum)"
    else
        report "$name" "a run that failed after the cron stop did not end with: $notice (gum: $gum)"
    fi
done

name=cron-stop-fails
run_case "$name" no 1
if [ "$(cat "$fixture/$name/status")" != 0 ] && [ "$(order "$name")" = stop-cron ] &&
    ! grep -q '^unexpected:' "$fixture/$name/calls"; then
    echo "PASS: a cron that cannot be stopped stops the setup before MariaDB is touched"
else
    report "$name" "a failed cron stop must end the setup before MariaDB; status $(cat "$fixture/$name/status"), steps: $(order "$name")"
fi
if [ "$(stopped_notices "$name")" = 0 ]; then
    echo "PASS: a cron that could not be stopped is not reported stopped"
else
    report "$name" "a failed cron stop was reported as a stopped cron"
fi

# The functions behind the notice, from setup.sh, with run_step stubbed:
# the trap runs before the one already set and keeps it, a cron started
# again clears it, a start that fails keeps it.
extract_function() {
    awk -v signature="$1() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$root/docker/setup.sh"
}
{
    cat <<'SH'
YELLOW=
NC=
SETUP_RUNTIME_FLAGS=(-d)
run_step() { shift; "$@"; }
docker() { echo "docker $*"; return "${START_STATUS:-0}"; }
SH
    for function in setup_start_cron setup_cron_stopped_notice setup_add_exit_trap; do
        extract_function "$function"
    done
} > "$fixture/notice.sh"
# notice_case <start: none|ok|fail>: a run that set an earlier exit trap,
# stopped cron, then started it again or not, and failed.
notice_case() {
    bash -c '
        source "$1"
        trap "echo earlier exit trap" EXIT
        SETUP_CRON_STOPPED=true
        setup_add_exit_trap setup_cron_stopped_notice
        SETUP_CRON_PENDING=true
        case "$2" in
            ok) setup_start_cron ;;
            fail) START_STATUS=1 setup_start_cron || true ;;
        esac
        exit 3
    ' _ "$fixture/notice.sh" "$1" 2>&1
}
expected=$(printf '%s\nearlier exit trap' "$notice")
if [ "$(notice_case none)" = "$expected" ] &&
    [ "$(notice_case ok)" = "$(printf 'docker compose up -d cron\nearlier exit trap')" ] &&
    [ "$(notice_case fail)" = "$(printf 'docker compose up -d cron\n%s' "$expected")" ]; then
    echo "PASS: the notice runs before the earlier exit trap, and only while cron is not started again"
else
    printf '%s\n---\n' "$(notice_case none)" "$(notice_case ok)" "$(notice_case fail)" >&2
    echo "FAIL: the exit notice does not follow the state of cron, or dropped the earlier exit trap" >&2
    status=1
fi

exit "$status"
