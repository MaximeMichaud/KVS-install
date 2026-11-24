#!/bin/bash
# Exercise remove against a concurrent proxy shutdown, with a stubbed engine.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
manager=$work/docker/multi-site/site-manager.sh
multi=${manager%/*}
export work multi KVS_WEBROOT_BASE=$work/www
mkdir -p "$multi/.locks/.routes" "$multi/caddy/sites"
cp "$root/docker/multi-site/site-manager.sh" "$manager"
wait_file() {
    local n
    for ((n=0; n<100; n++)); do
        [[ ! -e $1 ]] || return 0
        sleep 0.05
    done
    return 1
}
# shellcheck disable=SC2329  # Run in the child managers.
flock() {
    if [[ ${actor:-} == second && $* == '-n 8' ]]; then touch "$work/attempt"; fi
    command flock "$@"
}
# Both operations must hold the route lock, without giving it to Docker.
locked() { ! command flock -n "$multi/.locks/.routes" true && [[ ! /dev/fd/8 -ef $multi/.locks/.routes ]]; }
# shellcheck disable=SC2329
docker() {
    case "$*" in
        'compose -p multi-site -f docker-compose.caddy.yml down')
            locked || return 31
            if [[ $phase == stop-first ]]; then touch "$work/entered"; wait_file "$work/attempt" || return 33; fi
            rm "$work/running" ;;
        'ps --format {{.Names}}')
            locked || return 32
            if [[ $phase == remove-first ]]; then touch "$work/entered"; wait_file "$work/attempt" || return 34; fi
            [[ $phase != query-error ]] || return 35
            if [[ -e $work/running ]]; then echo kvs-caddy; fi ;;
        'exec kvs-caddy caddy reload '*)
            locked && [[ -e $work/running ]] || return 36
            touch "$work/reload"
            [[ $phase != reload-error ]] ;;
        'compose config') echo 'name: kvs-site' ;;
        'ps '*|'volume '*|'compose -p kvs-site down -v --remove-orphans') return 0 ;;
        *) return 90 ;;
    esac
}
export -f docker wait_file flock locked
export phase
remove_site() { bash "$manager" remove site.example <<<yes; }
for phase in stop-first remove-first query-error reload-error; do
    mkdir -p "$multi/sites/site.example"
    echo COMPOSE_PROJECT_NAME=kvs-site > "$multi/sites/site.example/.env"
    echo 'services: {}' > "$multi/sites/site.example/docker-compose.yml"
    touch "$multi/caddy/sites/site.example.caddy" "$work/running"
    rm -f "$work/entered" "$work/attempt" "$work/reload"
    case $phase in
        stop-first)
            bash "$manager" caddy-stop > "$work/stop" & first=$!
            wait_file "$work/entered" || { cat "$work/stop"; exit 1; }
            actor=second remove_site > "$work/remove"
            wait "$first"
            [[ ! -e $work/reload ]] ;;
        remove-first)
            remove_site > "$work/remove" & first=$!
            wait_file "$work/entered" || { cat "$work/remove"; exit 1; }
            actor=second bash "$manager" caddy-stop > "$work/stop"
            wait "$first"
            [[ -e $work/reload ]] ;;
        *)
            if remove_site > "$work/remove"; then echo "Unexpected success: $phase"; exit 1; fi
            if [[ $phase == query-error ]]; then
                grep -Fq 'Could not query' "$work/remove"
                [[ ! -e $work/reload ]]
            else
                grep -Fq 'Failed to reload' "$work/remove"
                [[ -e $work/reload ]]
            fi ;;
    esac
    [[ ! -e $multi/sites/site.example && ! -e $multi/caddy/sites/site.example.caddy ]]
done
echo 'PASS: remove and caddy-stop serialize their Docker operations and report daemon failures'
