#!/bin/bash
# Pause the real admin step between its fingerprint and database writes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
export work
first=
cleanup() {
    touch "$work/release"
    [ -z "$first" ] || wait "$first" || true
    rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
await_marker() {
    for ((i=0; i<200; i++)); do
        [ ! -f "$1" ] || return 0
        sleep 0.05
    done
    fail "first run did not reach $1"
}
refused() {
    local status=0
    timeout 5 "$@" > "$work/second.log" 2>&1 || status=$?
    [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "concurrent $* was not refused immediately"
    grep -Fq 'Could not lock' "$work/second.log" || fail "missing lock diagnostic for $*"
}
mkdir -p "$work/steps" "$work/other" "$work/site/admin/data/system"
printf '{"admins":[]}\n' > "$work/site/admin/data/system/ap.dat"
cat > "$work/common" <<'SH'
log_info() { :; }
log_step() { :; }
log_warn() { :; }
log_error() { echo "$*" >&2; }
get_tables_prefix() { echo ktvs_; }
db_query() {
    case "$1" in
        *"SELECT login "*) echo admin ;;
        *"SELECT COUNT("*) echo 0 ;;
        *) return 1 ;;
    esac
}
db_exec() {
    if [ "${PAUSE:-}" = yes ]; then
        touch "$work/entered"
        while [ ! -e "$work/release" ]; do sleep 0.05; done
    fi
    sed -n "s/.*SET pass='\([^']*\)'.*/\1/p" <<< "$1" > "$work/hash"
}
SH
sed -e "s|/init/lib/common.sh|$work/common|g" -e "s|/init/docker-entrypoint.d/|$work/steps/|g" \
    "$root/docker/init/init-kvs.sh" > "$work/runner"
sed "s|/init/lib/common.sh|$work/common|" "$root/docker/init/docker-entrypoint.d/35-harden-admin-users.sh" \
    > "$work/steps/35-harden-admin-users.sh"
# shellcheck disable=SC2016  # Expanded by the fixture step.
echo 'touch "$KVS_PATH/search-step"' > "$work/steps/80-manticore.sh"
export DOMAIN=site.test MARIADB_PASSWORD=fixture KVS_INIT_RUN_DIR="$work/first-run" KVS_PATH="$work/site"
export KVS_ADMIN_PASSWORD=first-password-for-fixture
PAUSE=yes bash "$work/runner" > "$work/first.log" 2>&1 &
first=$!
await_marker "$work/entered"
export KVS_ADMIN_PASSWORD=second-password-for-fixture KVS_INIT_RUN_DIR="$work/second-run"
mkdir "$KVS_INIT_RUN_DIR"
refused bash "$work/runner"
[ -d "$KVS_INIT_RUN_DIR" ] || fail "the other run cleared its work directory before locking"

# Run the plugin helper with only the Compose boundary replaced. Execute its
# actual entrypoint and arguments on fixture paths that represent the mounts.
mkdir -p "$work/plugin-bin"
cat > "$work/plugin-bin/docker" <<'SH'
#!/bin/bash
if [ "$2" = exec ]; then exit 0; fi
while [ "$#" -gt 0 ] && [ "$1" != --entrypoint ]; do shift; done
entry=$2
[ "$3" = kvs-init ] || exit 1
shift 3
args=()
for arg in "$@"; do
    case "$arg" in
        /var/www/kvs) arg=$KVS_PATH ;;
        /init/docker-entrypoint.d/80-manticore.sh) arg=$work/steps/80-manticore.sh ;;
    esac
    args+=("$arg")
done
exec "$entry" "${args[@]}"
SH
chmod +x "$work/plugin-bin/docker"
cat > "$work/search" <<'SH'
source "$1"
manticore_configure_plugin true
SH
run_search() {
    PATH="$work/plugin-bin:$PATH" timeout 5 bash "$work/search" "$root/docker/lib/manticore.sh"
}
status=0
run_search > "$work/search.log" 2>&1 || status=$?
[ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "search did not refuse the occupied site immediately"
grep -Fq 'Retry after the current init finishes' "$work/search.log" || fail "missing retry diagnostic"
[ ! -e "$KVS_PATH/search-step" ] || fail "search changed the occupied site"
KVS_PATH="$work/other" run_search > "$work/other.log"
[ -e "$work/other/search-step" ] && [ ! -e "$work/hash" ] || fail "search did not run independently"
touch "$work/release"
wait "$first"
first=
# shellcheck disable=SC2016
php -r '
    [$file, $hashFile] = array_slice($argv, 1);
    $hash = trim(file_get_contents($hashFile));
    $actual = json_decode(file_get_contents($file), true)["admins"][0]["hash"];
    exit($hash === md5("pass:" . md5("first-password-for-fixture"))
        && $actual === substr(md5("admin" . $hash), 0, 20) ? 0 : 1);
' "$KVS_PATH/admin/data/system/ap.dat" "$work/hash" || fail "first login and fingerprint disagree"
run_search > "$work/retry.log"
printf '%s\n' 'echo "plugin failed" >&2' 'exit 75' > "$work/steps/80-manticore.sh"
if run_search > "$work/plugin-error.log" 2>&1; then fail "plugin failure was accepted"; fi
grep -Fxq 'plugin failed' "$work/plugin-error.log" || fail "missing plugin error"
if grep -Fq 'Retry after' "$work/plugin-error.log"; then fail "plugin failure reported as contention"; fi

# A start must own the site before inspecting its admin or stopping cron.
mkdir -p "$work/docker/manager/sites/site.test" "$work/bin"
cp "$root/docker/multi-site/site-manager.sh" "$work/docker/manager/"
# shellcheck source=tests/fixtures/manager-scripts-lock.sh
source "$root/tests/fixtures/manager-scripts-lock.sh" "$work/docker"
site=$work/docker/manager/sites/site.test
mkdir -p "$work/docker/manager/caddy/sites"
echo route > "$work/docker/manager/caddy/sites/site.test.caddy"
echo 'COMPOSE_PROJECT_NAME=kvs-site-test' > "$site/.env"
echo 'services: {}' > "$site/docker-compose.yml"
cat > "$work/bin/docker" <<'SH'
#!/bin/sh
if [ "${PAUSE:-}" = yes ]; then
    touch "$work/entered"
    while [ ! -e "$work/release" ]; do sleep 0.05; done
else
    touch "$work/second-docker"
fi
exit 1
SH
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"
rm "$work/entered" "$work/release"
PAUSE=yes bash "$work/docker/manager/site-manager.sh" start site.test > "$work/manager.log" 2>&1 &
first=$!
await_marker "$work/entered"
# Even a malformed primary reservation must not mask contention on add.
touch "$work/docker/manager/sites/.primary.env"
for action in add start stop remove proxy-config; do
    refused bash "$work/docker/manager/site-manager.sh" "$action" site.test < /dev/null
done
rm "$work/docker/manager/sites/.primary.env"
[ ! -e "$work/second-docker" ] || fail "second manager command reached Docker"
touch "$work/release"
wait "$first" && fail "the fixture has no running Caddy"
first=
bash "$work/docker/manager/site-manager.sh" stop site.test >/dev/null 2>&1 || true
[ -e "$work/second-docker" ] || fail "failed start retained the site lock"
# Hold remove at its webroot prompt, after its project directory is gone.
# remove runs its last Docker check from the directory it just unlinked.
# shellcheck disable=SC2329  # Exported to the manager subprocess.
docker() {
    if [[ "$*" == 'compose config' ]]; then echo 'name: kvs-site-test'; fi
    return 0
}
export -f docker
export KVS_WEBROOT_BASE=$work/webroots
mkdir -p "$KVS_WEBROOT_BASE/site.test"
mkfifo "$work/answer"
exec 7<>"$work/answer"
bash "$work/docker/manager/site-manager.sh" remove site.test 7>&- < "$work/answer" > "$work/remove.log" &
first=$!
trap 'printf "n\n" >&7; cleanup' EXIT
printf 'yes\n' >&7
for ((i=0; i<200; i++)); do
    [ -d "$site" ] || break
    sleep 0.05
done
[ ! -d "$site" ] || fail "remove did not remove its project directory"
kill -0 "$first" || fail "remove did not reach its last prompt"
for action in add start stop remove proxy-config; do
    refused bash "$work/docker/manager/site-manager.sh" "$action" site.test < /dev/null
done
bash "$work/docker/manager/site-manager.sh" list | grep -Fq 'No sites configured yet' || fail "lock directory listed as a site"
bash "$work/docker/manager/site-manager.sh" proxy-config other.test >/dev/null
printf 'y\n' >&7
wait "$first"
first=
trap cleanup EXIT
exec 7>&-
[ ! -e "$KVS_WEBROOT_BASE/site.test" ] || fail "confirmed webroot deletion did not finish"
bash "$work/docker/manager/site-manager.sh" proxy-config site.test >/dev/null
echo "PASS: competing initializers and site operations refuse the occupied site"
