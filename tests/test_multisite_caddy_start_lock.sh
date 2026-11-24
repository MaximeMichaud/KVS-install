#!/bin/bash
# caddy-start shares the route lock with the commands that publish and
# remove routes. Docker is a stub that pauses at the step under test.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/docker"
(cd "$root/docker" && cp --parents .gitignore images.lock bin/resolve-bases.sh lib/host-validation.sh lib/kvs-php.sh \
    init/lib/kvs-archive.sh multi-site/site-manager.sh multi-site/docker-compose.caddy.yml \
    multi-site/docker-compose.site.yml.template "$work/docker")
multi="$work/docker/multi-site"
# shellcheck source=tests/fixtures/manager-scripts-lock.sh
source "$root/tests/fixtures/manager-scripts-lock.sh" "$work/docker"
manager="$multi/site-manager.sh"
routes="$multi/caddy/sites"
locks="$multi/.locks"
export work routes locks phase=none KVS_WEBROOT_BASE="$work/www"
unset ACME_EMAIL CADDY_TLS_MODE
mkdir -p "$work/docker/kvs-archive" "$routes" "$locks/.routes"
touch "$work/docker/kvs-archive/KVS_test.zip"
fail() { echo "FAIL: $*" >&2; exit 1; }
# await_file <path> <tenths of a second>: wait for a file another command writes.
await_file() {
    local n
    for ((n = 0; n < $2; n++)); do
        [[ ! -e $1 ]] || return 0
        sleep 0.1
    done
    return 1
}
# The lock is held when an independent open file description cannot take it.
route_lock_held() { ! flock -n "$locks/.routes" true; }
# Docker must not inherit the descriptor of the lock: a Compose that
# outlives a killed caddy-start would keep the lock.
# shellcheck disable=SC2329  # Used by child managers.
lock_not_inherited() { ! { true <&8; } 2> /dev/null; }
# shellcheck disable=SC2329  # Used by child managers.
chown() { :; }
# shellcheck disable=SC2329  # Used by child managers.
docker() {
    case "$*" in
        'ps --format {{.Names}}')
            if [[ -e $work/running ]]; then echo kvs-caddy; fi ;;
        'network inspect kvs-proxy')
            # The first Docker call of caddy-start, right after its ACME check.
            if [[ ${actor:-} == start ]]; then
                route_lock_held || return 23
                lock_not_inherited || return 24
                if [[ $phase == email ]]; then
                    touch "$work/email-checked"
                    await_file "$work/add-done" 20 || true
                fi
            fi ;;
        'compose -p multi-site -f docker-compose.caddy.yml up -d')
            route_lock_held || return 23
            lock_not_inherited || return 24
            if [[ $phase == email && -e $routes/public.example.caddy ]]; then touch "$work/unchecked-route"; fi
            if [[ $phase == primary && -e $routes/primary.example.caddy ]]; then touch "$work/started-with-primary"; fi
            touch "$work/running"
            if [[ $phase == reload ]]; then
                # The container is being replaced: a reload fails until the
                # new proxy answers.
                touch "$work/replacing"
                await_file "$work/reload-failed" 20 || true
            fi ;;
        'exec kvs-caddy wget '*)
            route_lock_held || return 23
            lock_not_inherited || return 24
            if [[ $phase == reload ]]; then
                await_file "$work/reload-failed" 10 || true
                touch "$work/ready"
            fi ;;
        'exec kvs-caddy caddy reload '*)
            route_lock_held || return 23
            lock_not_inherited || return 24
            if [[ $phase == reload && ! -e $work/ready ]]; then
                touch "$work/reload-failed"
                return 1
            fi ;;
        'compose config') command docker "$@" ;;
        'ps '*|'volume '*|*' down -v --remove-orphans') return 0 ;;
        *) echo "Unexpected Docker call: $*" >&2; return 90 ;;
    esac
}
# shellcheck disable=SC2329  # Used by child managers.
rm() {
    if [[ $phase == primary && ${*: -1} == "$routes/primary.example.caddy" ]]; then
        # primary-remove has seen Caddy stopped and is about to delete.
        touch "$work/checked-stopped"
        await_file "$work/running" 20 || true
    fi
    command rm "$@"
}
# The ACME check reads each route with awk.
# shellcheck disable=SC2329  # Used by child managers.
awk() {
    if [[ ${actor:-} == start && ${*: -1} == "$routes/seed.example.caddy" ]] && ! route_lock_held; then
        touch "$work/unlocked-check"
    fi
    command awk "$@"
}
export -f docker chown rm awk await_file route_lock_held lock_not_inherited
bash "$manager" proxy-config seed.example internal false false > "$work/out" 2>&1 || fail 'proxy-config failed'
if command grep -Fq 'Waiting for another route operation' "$work/out"; then
    fail 'a command that found the route lock free said it waited'
fi

# A public route published while caddy-start runs lands before its ACME
# check or after Compose has started, never between the two.
phase=email
actor=start timeout 30 bash "$manager" caddy-start > "$work/start" 2>&1 & starter=$!
await_file "$work/email-checked" 100 || fail "caddy-start did not reach Compose: $(cat "$work/start")"
ACME_EMAIL=ops@sub.example.com timeout 30 bash "$manager" add public.example > "$work/add" 2>&1 || fail "add failed: $(cat "$work/add")"
touch "$work/add-done"
command grep -Fq 'Waiting for another route operation to finish' "$work/add" ||
    fail 'add waited for caddy-start without saying so'
wait "$starter" || fail "caddy-start failed: $(cat "$work/start")"
[[ ! -e $work/unlocked-check ]] || fail 'caddy-start read the routes for its ACME check without the route lock'
[[ ! -e $work/unchecked-route ]] || fail 'Compose started with a public route the ACME check had not seen'
[[ -e $work/running && -s $routes/public.example.caddy ]] || fail 'caddy-start or add did not finish'

# primary-remove requires a stopped Caddy: caddy-start waits for it instead
# of starting between its check and the deletion of the route.
command rm "$work/running"
phase=primary
export ACME_EMAIL=ops@sub.example.com
bash "$manager" primary-config primary.example primary internal false > "$work/out" 2>&1 || fail 'primary-config failed'
timeout 30 bash "$manager" primary-remove primary.example primary > "$work/remove" 2>&1 & remover=$!
await_file "$work/checked-stopped" 100 || fail "primary-remove did not reach the deletion: $(cat "$work/remove")"
actor=start timeout 30 bash "$manager" caddy-start > "$work/start" 2>&1 || fail "caddy-start failed: $(cat "$work/start")"
wait "$remover" || fail "primary-remove failed: $(cat "$work/remove")"
[[ ! -e $work/started-with-primary ]] || fail 'Compose started Caddy with the primary route while primary-remove was deleting it'
[[ -e $work/running && ! -e $routes/primary.example.caddy && ! -e $multi/sites/.primary.env ]] ||
    fail 'primary-remove or caddy-start did not finish'

# A remove that reaches its reload while caddy-start replaces the proxy
# waits for the new one instead of failing after the site is gone.
phase=reload
actor=start timeout 30 bash "$manager" caddy-start > "$work/start" 2>&1 & starter=$!
await_file "$work/replacing" 100 || fail "caddy-start did not reach Compose: $(cat "$work/start")"
printf 'yes\nn\n' | timeout 30 bash "$manager" remove public.example > "$work/remove" 2>&1 ||
    fail "remove failed during the replacement of the proxy: $(cat "$work/remove")"
wait "$starter" || fail "caddy-start failed: $(cat "$work/start")"
[[ ! -e $work/reload-failed ]] || fail 'a reload ran while the proxy was being replaced'
command grep -Fq 'Site public.example removed completely' "$work/remove" || fail 'remove did not finish'
[[ ! -e $routes/public.example.caddy && ! -e $multi/sites/public.example ]] || fail 'remove left the site'

echo "PASS: caddy-start holds the route lock from its ACME check until the new proxy has loaded the routes"
