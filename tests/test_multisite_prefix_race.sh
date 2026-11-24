#!/bin/bash
# add and primary-config must not both reserve one Compose project.
set -euo pipefail
export CADDY_TLS_MODE=internal
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/docker"
(cd "$root/docker" && command cp --parents images.lock bin/resolve-bases.sh lib/host-validation.sh lib/kvs-php.sh \
    init/lib/kvs-archive.sh multi-site/site-manager.sh multi-site/docker-compose.site.yml.template "$work/docker")
multi="$work/docker/multi-site"
manager="$multi/site-manager.sh"
sites="$multi/sites"
routes="$multi/caddy/sites"
locks="$multi/.locks"
export work manager sites locks KVS_WEBROOT_BASE="$work/www"
command mkdir -p "$work/docker/kvs-archive"
touch "$work/docker/kvs-archive/KVS_test.zip"
# shellcheck disable=SC2329  # Used by child managers.
chown() { :; }
# shellcheck disable=SC2329  # Used by child managers.
docker() {
    if [[ "$1" == "${FAIL_LISTING:-none}" ]]; then
        [[ $* == *"label=com.docker.compose.project=kvs-unavailable-example"* ]] || return 95
        return 42
    fi
    if [[ -e $work/$1 && $* == *"label=com.docker.compose.project=kvs-late-example "* ]]; then
        echo fixture-owner
    fi
    [[ "$1" == ps || "$1" == volume ]]
}
# The primary site reserves the project of the site being added at the given
# step of that add: after its unlocked check, or once its .env is in place.
# shellcheck disable=SC2329  # Used by child managers.
reserve_primary() {
    [[ ! -e "$work/reserved" ]] || return 0
    touch "$work/reserved"
    bash "$manager" primary-config primary.example kvs-media-example internal false > "$work/primary.log" 2>&1 ||
        echo "$?" > "$work/primary-refused"
}
# shellcheck disable=SC2329  # Used by child managers.
mkdir() {
    if [[ ${RACE_AT:-} == claim && ${*: -1} == "$sites/media.example" ]]; then reserve_primary; fi
    command mkdir "$@"
}
# shellcheck disable=SC2329  # Used by child managers.
cp() {
    if [[ ${RACE_AT:-} == dotenv && $* == *docker-compose.site.yml.template* ]]; then reserve_primary; fi
    command cp "$@"
}
# add reads its own .env only in the final prefix check: note whether the
# route lock is held then, and that the route is not published yet.
# shellcheck disable=SC2329  # Used by child managers.
sed() {
    if [[ ${*: -1} == "$sites/${WATCH_DOMAIN:-none}/.env" && ! -e "$routes/${WATCH_DOMAIN:-none}.caddy" ]]; then
        if flock -n "$locks/.routes" true; then echo unlocked; else echo locked; fi >> "$work/final-check"
    fi
    command sed "$@"
}
export -f chown docker reserve_primary mkdir cp sed
export routes

# 1. The reservation lands between the unlocked check of add and its site
# directory. It wins: add must refuse, and leave nothing of the site behind.
status=0
RACE_AT=claim bash "$manager" add media.example > "$work/add.log" 2>&1 || status=$?
[[ -e "$work/reserved" && ! -e "$work/primary-refused" ]] || { cat "$work/primary.log"; echo "The reservation did not run"; exit 1; }
if [[ $status == 0 ]]; then
    grep -hE '^SITE_PREFIX=' "$sites/media.example/.env" "$sites/.primary.env"
    echo "add and primary-config both reserved the project kvs-media-example"; exit 1
fi
grep -Fq 'Site prefix kvs-media-example is reserved by primary site primary.example' "$work/add.log" ||
    { cat "$work/add.log"; echo "add did not name the reservation"; exit 1; }
[[ ! -e "$sites/media.example" && ! -e "$routes/media.example.caddy" && ! -e "$KVS_WEBROOT_BASE/media.example" ]] ||
    { echo "The refused add left part of the site"; exit 1; }
[[ -z $(find "$routes" -name '.media.example.caddy.*') ]] || { echo "The refused add left a temporary route"; exit 1; }
grep -Fxq 'SITE_PREFIX=kvs-media-example' "$sites/.primary.env"
grep -Fq 'n.primary.example:80' "$routes/primary.example.caddy"
bash "$manager" primary-remove primary.example kvs-media-example > "$work/out"

# 2. The reservation arrives once the .env of add is in place: primary-config
# must refuse, and the add completes.
rm "$work/reserved"
RACE_AT=dotenv bash "$manager" add media.example > "$work/add.log" 2>&1 || { cat "$work/add.log"; exit 1; }
[[ -e "$work/reserved" && -e "$work/primary-refused" ]] || { echo "primary-config took the project of a site being added"; exit 1; }
grep -Fq 'Site prefix kvs-media-example is already used by media.example' "$work/primary.log"
[[ ! -e "$sites/.primary.env" && ! -e "$routes/primary.example.caddy" ]]
grep -Fxq 'SITE_PREFIX=kvs-media-example' "$sites/media.example/.env"
grep -Fxq 'media.example {' "$routes/media.example.caddy"

# 3. The final check of add runs while it holds the route lock, the lock
# primary-config reserves under, and before the route is published.
WATCH_DOMAIN=other.example bash "$manager" add other.example > "$work/add.log" 2>&1 || { cat "$work/add.log"; exit 1; }
[[ -f "$work/final-check" && $(sort -u "$work/final-check") == locked ]] ||
    { echo "add published without checking its prefix under the route lock"; exit 1; }
echo "PASS: add and primary-config cannot reserve the same Compose project"

# Empty output from Docker is meaningful only after a successful listing.
for listing in ps volume; do
    if FAIL_LISTING=$listing bash "$manager" add unavailable.example > "$work/add.log" 2>&1; then
        echo "add accepted a failed $listing listing"; exit 1
    fi
    grep -Fq 'Could not list' "$work/add.log"
    grep -Fq 'kvs-unavailable-example' "$work/add.log"
    [[ ! -e $sites/unavailable.example && ! -e $routes/unavailable.example.caddy && ! -e $KVS_WEBROOT_BASE/unavailable.example ]]
done

# Inject an owner just as the route lock is acquired, after the first check.
# shellcheck disable=SC2329  # Used by the manager.
flock() {
    command flock "$@" || return $?
    if [[ -n ${LATE_OWNER:-} && $* == '-n 8' ]]; then
        case "$LATE_OWNER" in
            primary) echo 'COMPOSE_PROJECT_NAME=kvs-late-example' > "$work/docker/.env" ;;
            *) touch "$work/$LATE_OWNER" ;;
        esac
    fi
}
export -f flock
for owner in primary ps volume; do
    if LATE_OWNER=$owner bash "$manager" add late.example > "$work/add.log" 2>&1; then
        echo "add accepted a late $owner"; exit 1
    fi
    case "$owner" in
        primary) grep -Fq 'used by the primary site' "$work/add.log" ;;
        *) grep -Fq 'project named kvs-late-example already exists' "$work/add.log" ;;
    esac
    [[ ! -e $sites/late.example && ! -e $routes/late.example.caddy && ! -e $KVS_WEBROOT_BASE/late.example ]]
    [[ -z $(find "$routes" -name '.late.example.caddy.*') ]]
    rm -f "$work/docker/.env" "$work/$owner"
done
