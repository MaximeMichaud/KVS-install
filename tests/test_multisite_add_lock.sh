#!/bin/bash
set -euo pipefail
export CADDY_TLS_MODE=internal
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/docker"
(cd "$root/docker" && cp --parents images.lock bin/resolve-bases.sh lib/host-validation.sh lib/kvs-php.sh init/lib/kvs-archive.sh \
    multi-site/site-manager.sh multi-site/docker-compose.site.yml.template "$work/docker")
manager="$work/docker/multi-site/site-manager.sh"
domain=media.example
site="$work/docker/multi-site/sites/$domain"
route="$work/docker/multi-site/caddy/sites/$domain.caddy"
mkdir -p "$work/docker/kvs-archive"
touch "$work/docker/kvs-archive/KVS_test.zip"
export work manager domain site route KVS_WEBROOT_BASE="$work/www"
# shellcheck disable=SC2329  # Child managers use these functions.
docker() { [[ "$1" == ps || "$1" == volume ]]; }
export -f docker
# A file already occupying any destination belongs to the independent writer.
for occupied in archive.zip .env docker-compose.yml; do
    export occupied
    # shellcheck disable=SC2329  # Called after add has created the site directory.
    chown() { printf 'operator file\n' > "$site/$occupied"; }
    export -f chown
    if bash "$manager" add "$domain" > "$work/occupied" 2>&1; then echo "Replaced $occupied"; exit 1; fi
    [[ $(cat "$site/$occupied") == 'operator file' && ! -e "$route" ]] || { echo "Lost $occupied"; exit 1; }
    rm "$site/$occupied"
    rmdir "$site"
done
# Even replacement links with the same target have different inodes.
# shellcheck disable=SC2329
chown() { :; }
# shellcheck disable=SC2329
mv() {
    if [[ ${*: -1} == "$route" ]]; then
        local target
        target=$(readlink "$site/archive.zip")
        rm "$site/archive.zip"
        ln -s "$target" "$site/archive.zip"
        return 17
    fi
    command mv "$@"
}
export -f chown mv
if bash "$manager" add "$domain" > "$work/replaced" 2>&1; then exit 1; fi
[[ -L "$site/archive.zip" && ! -e "$site/.env" && ! -e "$route" ]] || { echo "Lost a replacement link"; exit 1; }
rm "$site/archive.zip"
rmdir "$site"
unset -f mv
# Pause the first add while its site directory is empty. Even after another
# process unlinks that directory, its lock must belong to the same domain.
# shellcheck disable=SC2329
chown() {
    if [[ "$2" != "$KVS_WEBROOT_BASE/$domain" || -e "$work/nested" ]]; then return 0; fi
    touch "$work/nested"
    for action in remove add start stop proxy-config; do
        if bash "$manager" "$action" "$domain" </dev/null > "$work/$action" 2>&1; then return 1; fi
        grep -q 'Could not lock' "$work/$action" || return 1
    done
    rmdir "$site" || return 1
    if bash "$manager" add "$domain" > "$work/removed" 2>&1; then return 1; fi
    grep -q 'Could not lock' "$work/removed" || return 1
    mkdir "$site" || return 1
    bash "$manager" add other.example > "$work/other" || return 1
    kill -TERM "$BASHPID"
}
export -f chown
status=0
env --default-signal=TERM bash "$manager" add "$domain" > "$work/first" 2>&1 || status=$?
[[ $status == 143 && -d "$site" && ! -e "$site/.env" && ! -e "$route" && -s "${site%/*}/other.example/.env" ]] ||
    { echo "Same-domain contention, independent add or interrupted cleanup failed (status $status)"; exit 1; }

rmdir "$site"
# An operator can write a route directly. A failed rename then removes its
# temporary file, but the operator's inode must never commit the failed add.
# shellcheck disable=SC2329
mv() {
    if [[ ${*: -1} == "$route" ]]; then
        printf 'operator route\n' > "$route"
        return 17
    fi
    command mv "$@"
}
export -f mv
if bash "$manager" add "$domain" > "$work/rename" 2>&1; then echo "Failed rename accepted"; exit 1; fi
[[ $(cat "$route") == 'operator route' && ! -e "$site" && ! -e "$KVS_WEBROOT_BASE/$domain" ]] ||
    { echo "The foreign route committed the failed add or was removed"; exit 1; }
unset -f mv
rm "$route"
# Replace the published route before add can record success. Its open
# descriptor still identifies the original inode when TERM runs the EXIT trap.
# shellcheck disable=SC2329
mv() {
    command mv "$@" || return 1
    if [[ ${*: -1} == "$route" ]]; then
        command mv "$work/operator" "$route" || return 1
        kill -TERM "$BASHPID"
    fi
}
printf 'operator replacement\n' > "$work/operator"
export -f mv
status=0
env --default-signal=TERM bash "$manager" add "$domain" > "$work/interrupted" 2>&1 || status=$?
[[ $status == 143 && $(cat "$route") == 'operator replacement' && ! -e "$site" && ! -e "$KVS_WEBROOT_BASE/$domain" ]] ||
    { echo "The replacement route committed the interrupted add or was lost (status $status)"; exit 1; }
unset -f mv
rm "$route"
# Do not report a site just because a previous operation left its lock.
mv "${site%/*}/other.example" "$work/other-site"
bash "$manager" list > "$work/sites"
grep -Fq 'No sites configured yet' "$work/sites"
bash "$manager" add "$domain" > "$work/retry"
[[ -s "$site/.env" && -s "$site/docker-compose.yml" && -s "$route" ]]
echo "PASS: site commands share a persistent domain lock and only add's own route commits its files"
