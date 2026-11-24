#!/bin/bash
# Installation, scripts and nested manager locks, using real file descriptions.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/an installation"
multi=$root/docker/multi-site
manager=$multi/site-manager.sh
lock=$root/kvsctl/lock
scripts=$root/docker/.kvs-scripts.lock
mkdir -p "$multi" "$root/docker/lib" "$work/bin"
cp "$repo/docker/lib/host-validation.sh" "$root/docker/lib/"
cp "$repo/docker/multi-site/site-manager.sh" "$manager"
ln -s "$manager" "$work/manager"
export lock scripts work PATH="$work/bin:$PATH"
cat > "$work/bin/docker" <<'DOCKER'
#!/bin/bash
set -eu
for file in /dev/fd/*; do
    if [[ $file -ef $lock || $file -ef $scripts ]]; then echo 'Docker inherited an installation lock' >&2; exit 71; fi
done
case "$*" in
    'network inspect kvs-proxy')
        if [[ ${PAUSE:-} == yes ]]; then echo ready > "$work/ready"; read -r _ < "$work/release"; fi ;;
    'inspect --format '*ACME_EMAIL*' kvs-caddy') echo ACME_EMAIL=admin@example.com ;;
    'compose -p multi-site -f docker-compose.caddy.yml up -d'|'exec kvs-caddy wget '*|'exec kvs-caddy caddy reload --force '*) ;;
    'network create kvs-proxy'|'ps --format {{.Names}}'|'compose down') ;;
    *) echo "unexpected docker command: $*" >&2; exit 99 ;;
esac
echo "$*" >> "$work/calls"
DOCKER
chmod +x "$work/bin/docker"
fail() { cat "$work/out" >&2; echo "FAIL: $*" >&2; exit 1; }
refused() {
    local why=$1
    shift
    if bash "$manager" "$@" > "$work/out" 2>&1; then fail "$*: expected refusal"; fi
    grep -Fq "$why" "$work/out" || fail "$*: wrong diagnostic"
}
commands=(add remove start stop proxy-config primary-config primary-remove proxy-network caddy-start caddy-stop)
refused 'Usage:' add
[[ ! -e $root/kvsctl && ! -e $scripts && ! -e $multi/.locks ]] || fail 'missing domain created locks'
for cmd in primary-config primary-remove; do
    refused 'Site prefix required' "$cmd" site.example
    [[ ! -e $root/kvsctl && ! -e $scripts && ! -e $multi/.locks ]] || fail "$cmd without a prefix created locks"
done
mkdir -m 0750 "$root/kvsctl"
exec 5>"$lock"
flock -xn 5
for cmd in "${commands[@]}"; do
    refused 'kvsctl is running' "$cmd" site.example primary internal
done
[[ ! -e $multi/.locks && ! -e $scripts && ! -e $multi/sites && ! -e $multi/caddy && ! -e $work/calls ]] ||
    fail 'a refused writer changed manager state'
for cmd in list status caddy-acme-check caddy-live-check help --help -h; do
    args=("$cmd")
    if [[ $cmd == caddy-live-check ]]; then args+=(site.example internal); fi
    bash "$manager" "${args[@]}" > "$work/out" || fail "$cmd refused during kvsctl"
done
[[ ! -e $multi/.locks && ! -e $scripts ]] || fail 'read-only command created locks'
exec 5>&-
# Keep an I/O failure distinct from ordinary contention on either lock.
check_lock_error() (
    export failing_lock=$1
    # shellcheck disable=SC2329  # The manager invokes the exported function.
    flock() { [[ $1 != "$failing_lock" ]] || return 66; command flock "$@"; }
    export -f flock
    refused 'failed with status 66' proxy-network
)
check_lock_error --shared
rm -r "$root/kvsctl"
mkdir -p "$root.kvsctl.Ab1234/kvsctl"
for state in absent empty; do
    refused 'set aside' proxy-network
    [[ ! -e $lock && ! -e $scripts ]] || fail 'created state beside a set-aside directory'
    if [[ $state == absent ]]; then [[ ! -e $root/kvsctl ]] || fail 'created kvsctl directory'; mkdir "$root/kvsctl"; fi
done
rmdir "$root/kvsctl" "$root.kvsctl.Ab1234/kvsctl" "$root.kvsctl.Ab1234"
# Test both sibling paths from a logical cwd inside the linked installation.
ln -s "$root" "$work/alias"
for path in "$work/alias" "$root"; do
    mkdir -p "$path.kvsctl.Ab1234/kvsctl/logs"
    (
        cd "$work/alias/docker"
        manager=./multi-site/site-manager.sh refused 'set aside' proxy-network
    )
    [[ ! -e $root/kvsctl && ! -e $scripts ]] || fail 'created locks during a set-aside update'
    rmdir "$path.kvsctl.Ab1234/kvsctl/logs" "$path.kvsctl.Ab1234/kvsctl" "$path.kvsctl.Ab1234"
done
mkfifo "$work/release"
PAUSE=yes bash "$work/manager" proxy-network > "$work/out" 2>&1 & holder=$!
for ((i=0;i<200;i++)); do [[ ! -e $work/ready ]] || break; sleep 0.05; done
[[ -e $work/ready ]] || fail 'first manager never reached the stubbed engine'
release() { echo release > "$work/release"; wait "$holder"; }
trap 'release; rm -rf "$work"' EXIT
[[ $(stat -c %a "$root/kvsctl") == 750 && $(stat -c %a "$lock") == 600 && $(stat -c %a "$scripts") == 600 ]] ||
    fail 'first-use permissions'
python3 - "$lock" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
fcntl.flock(fd, fcntl.LOCK_UN)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    pass
else:
    raise SystemExit("first kvsctl writer acquired the manager's lock")
PY
# An inheritance flag and an unrelated open descriptor cannot bypass the lock.
for cmd in "${commands[@]}"; do
    if [[ $cmd == stop ]]; then
        mkdir -p "$multi/sites/secondary.example"
        printf 'COMPOSE_PROJECT_NAME=secondary\n' > "$multi/sites/secondary.example/.env"
        printf 'services: {}\n' > "$multi/sites/secondary.example/docker-compose.yml"
        bash "$manager" stop secondary.example > "$work/out" || fail 'secondary stop took the scripts lock'
        grep -Fxq 'compose down' "$work/calls" || fail 'secondary stop missed Compose'
    else
        KVS_SITE_LOCKS_INHERITED=1 refused 'site-manager.sh run is changing' "$cmd" site.example primary internal 4</dev/null
    fi
done
check_lock_error --exclusive
[[ ! -e $multi/.locks/site.example ]] || fail 'domain lock taken before a scripts-lock refusal'
# Even a descriptor for the right inode must be flocked: it may name a
# separate open file description from the current writer's.
exec {candidate}< "$scripts"
KVS_SITE_LOCKS_INHERITED=1 refused 'site-manager.sh run is changing' proxy-network
exec {candidate}<&-
release
trap 'rm -rf "$work"' EXIT
flock -xn "$lock" true || fail 'kvsctl lock retained'
flock -xn "$scripts" true || fail 'scripts lock retained'
# Only installer children opt in to using an open scripts descriptor.
(
    exec 8< "$scripts"
    flock -xn 8
    refused 'site-manager.sh run is changing' proxy-network
    KVS_SITE_LOCKS_INHERITED=1 bash "$manager" proxy-config site.example internal
    if flock -xn "$scripts" true; then fail 'manager unlocked the inherited descriptor'; fi
)
# If the inherited scripts descriptor is 8, opening the route directory on
# that slot must keep the scripts lock alive until the command finishes.
exec 6< "$multi/.locks/.routes"
flock -xn 6
KVS_SITE_LOCKS_INHERITED=1 bash "$manager" proxy-config site.example internal 8< "$scripts" 6<&- > "$work/waiting" & writer=$!
for ((i=0;i<200;i++)); do grep -Fq 'Waiting for another route' "$work/waiting" && break; sleep 0.05; done
contended=no
flock -xn "$scripts" true || contended=yes
exec 6<&-
wait "$writer"
grep -Fq 'Waiting for another route' "$work/waiting" || fail 'route lock did not reuse descriptor 8'
[[ $contended == yes ]] || fail 'opening the routes directory dropped the scripts lock'
touch "$root/kvsctl/journal.json"
for cmd in "${commands[@]}"; do refused 'kvsctl recover' "$cmd" site.example primary internal; done
rm "$root/kvsctl/journal.json"
# Use each caller's real acquisition functions and manager invocation.
for caller in setup reconfigure; do
    (
        cd "$root/docker"
        for name in refuse_during_kvsctl_run hold_scripts_lock; do
            eval "$(sed -n "/^${name}() {/,/^}/p" "$repo/docker/$caller.sh")"
        done
        refuse_during_kvsctl_run "$root"
        hold_scripts_lock
        case $caller in
            setup)
                eval "$(sed -n '/^prepare_multi_site_proxy() {/,/^}/p' "$repo/docker/setup.sh")"
                DOMAIN=primary.example SITE_PREFIX=primary SSL_PROVIDER=selfsigned USE_WWW=false prepare_multi_site_proxy ;;
            reconfigure)
                # The primary-config invocation in the route transaction.
                DOMAIN=primary.example SITE_PREFIX=primary tls_mode=internal USE_WWW=false
                # shellcheck disable=SC2034  # Variables used by the extracted call.
                export DOMAIN SITE_PREFIX tls_mode USE_WWW
                eval "$(sed -n '/if ! .*site-manager.sh primary-config /,+1p' "$repo/docker/reconfigure.sh" |
                    sed '1s/.*if ! //; 2s/; then$//')" ;;
        esac
        [[ -s $multi/caddy/sites/primary.example.caddy ]] || fail "$caller did not configure the primary"
        if [[ $caller == setup ]]; then
            for name in run_step report_step_failure; do
                eval "$(sed -n "/^${name}() {/,/^}/p" "$repo/docker/setup.sh")"
            done
            # Exercise setup's actual commands so dropping either inherited
            # flag forces a second, conflicting acquisition of the scripts lock.
            export GREEN='' RED='' NC='' GUM_BIN='' DEBUG_LOG="$work/setup.log"
            eval "$(sed -n '/^        run_step "Starting Caddy reverse proxy"/,+2p' "$repo/docker/setup.sh")"
            grep -Fxq 'compose -p multi-site -f docker-compose.caddy.yml up -d' "$work/calls" || fail 'setup did not start the proxy'
            export DOMAIN=primary.example SITE_PREFIX=primary
            eval "$(sed -n '/if ! .*site-manager.sh primary-remove /,+1p' "$repo/docker/setup.sh" |
                sed '1s/.*if ! //; 2s/; then$//')"
            [[ ! -e $multi/caddy/sites/primary.example.caddy && ! -e $multi/sites/.primary.env ]] || fail 'setup did not remove the primary'
        fi
        if flock -xn "$scripts" true || flock -xn "$lock" true; then fail "$caller lost its lock"; fi
    )
    rm -f "$multi/caddy/sites/primary.example.caddy"
done
echo 'PASS: manager locks exclude installation writers and accept verified caller holds'
