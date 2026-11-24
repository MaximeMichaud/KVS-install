#!/bin/bash
# Site commands use the configuration in the selected directory.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
multi=$work/docker/multi-site
site=$multi/sites/media.example
manager=$multi/site-manager.sh
mkdir -p "$site" "$multi/caddy/sites"
cp "$root/docker/multi-site/site-manager.sh" "$manager"
export work
# shellcheck disable=SC2329  # Used by the manager.
docker() {
    printf '%s\n' "$*" >> "$work/docker.log"
    case "$1" in
        compose)
            if [[ -v COMPOSE_FILE || -v COMPOSE_PROFILES || -v COMPOSE_PROJECT_NAME ]]; then
                echo "Unexpected Compose environment" >&2
                return 91
            fi
            if [[ -e $work/check-services && ( $* == 'compose up -d' || $* == 'compose down' ) ]]; then
                command docker compose config --services | grep -Fxq extra || return 94
                command docker compose config | grep -Fxq "name: site" || return 95
                echo "$*" >> "$work/rendered"
            fi
            if [[ "$*" == 'compose config' ]]; then command docker "$@"; fi
            if [[ $* == *' config --format json kvs-init' ]]; then echo '{"services":{"kvs-init":{}}}'; fi ;;
        ps)
            if [[ "$*" == *'{{.Names}}'* ]]; then echo kvs-caddy; fi
            if [[ "$*" == *'project.working_dir'* && -e $work/filtered-error && "$*" == *'--filter'* ]]; then return 93; fi
            if [[ "$*" == *'project.working_dir'* && "$*" != *'--filter'* ]]; then
                [[ ! -e $work/ps-error ]] || return 92
                if [[ -f $work/labels ]]; then cat "$work/labels"; fi
            fi ;;
    esac
}
export -f docker
printf 'services: {}\n' > "$work/docker/docker-compose.yml"
printf 'SITE_PREFIX=kvs-media\n' > "$site/.env"
printf 'services: {}\n' > "$site/docker-compose.yml"

for file in docker-compose.yml .env; do
    mv "$site/$file" "$work/save"
    for state in missing empty directory; do
        case "$state" in
            empty) touch "$site/$file" ;;
            directory) rm "$site/$file"; mkdir "$site/$file" ;;
        esac
        : > "$work/docker.log"
        if bash "$manager" stop media.example > "$work/out" 2>&1 || [[ -s $work/docker.log ]]; then
            echo "stop reached Docker or succeeded with $state $file"; exit 1
        fi
        grep -Fq "$site/$file" "$work/out"
    done
    rmdir "$site/$file"
    mv "$work/save" "$site/$file"
done
bash "$manager" stop media.example > "$work/out"
grep -Fxq 'compose down' "$work/docker.log"

printf 'COMPOSE_PROJECT_NAME=site\n' >> "$site/.env"
printf 'route\n' > "$multi/caddy/sites/media.example.caddy"
printf 'COMPOSE_PROFILES=local\n' >> "$site/.env"
printf 'services:\n  extra:\n    image: fixture\n    profiles: [local]\n' > "$site/docker-compose.override.yml"
printf 'COMPOSE_PROJECT_NAME=other\nCOMPOSE_PROFILES=local\n' > "$work/other.env"
touch "$work/check-services"
for action in start stop; do
    COMPOSE_PROJECT_NAME=elsewhere COMPOSE_PROFILES=extra COMPOSE_FILE=other.yml \
    COMPOSE_ENV_FILES="$work/other.env" COMPOSE_DISABLE_ENV_FILE=1 KVS_ADMIN_PASSWORD=fixture \
        bash "$manager" "$action" media.example > "$work/out" || { cat "$work/out"; exit 1; }
done

grep -Fxq 'compose up -d' "$work/rendered"
grep -Fxq 'compose down' "$work/rendered"

# Existing containers can have been created under a shell override.
ln -s "$site" "$work/linked"
for state in foreign mixed unavailable filtered; do
    printf 'other\t%s\n' "$work/linked" > "$work/labels"
    case "$state" in
        mixed) printf 'site\t%s\n' "$site" >> "$work/labels" ;;
        unavailable) rm "$work/labels"; touch "$work/ps-error" ;;
        filtered) rm "$work/ps-error" "$work/labels"; touch "$work/filtered-error" ;;
    esac
    : > "$work/docker.log"
    if bash "$manager" remove media.example <<< yes > "$work/out"; then
        echo "remove accepted $state project labels"; exit 1
    fi
    [[ -s $site/.env && -s $multi/caddy/sites/media.example.caddy ]]
    if grep -Fq 'down -v' "$work/docker.log"; then echo "remove tore down $state"; exit 1; fi
done
rm "$work/filtered-error"
printf 'site\t%s\nother\t%s\n' "$work/linked" "$work" > "$work/labels"
COMPOSE_PROJECT_NAME=elsewhere COMPOSE_PROFILES=extra COMPOSE_FILE=other.yml \
COMPOSE_ENV_FILES="$work/other.env" COMPOSE_DISABLE_ENV_FILE=1 \
    bash "$manager" remove media.example <<< yes > "$work/out"
[[ ! -d $site ]]

# A relative invocation must find the script beside its own sites even when
# cd can find a directory of the same name through the operator's CDPATH.
mkdir -p "$site" "$work/decoy/multi-site/sites/wrong.example"
(
    cd "$work/docker"
    for search in "$work/decoy" ".:$work/decoy"; do
        CDPATH="$search" bash multi-site/site-manager.sh list > "$work/out"
        grep -Fq 'media.example (stopped)' "$work/out"
        if grep -Fq wrong.example "$work/out"; then exit 1; fi
    done
)

rmdir "$site"
bash "$manager" list > "$work/out"
grep -Fq 'No sites configured yet' "$work/out"
printf 'DOMAIN=primary.example\nSITE_PREFIX=primary\n' > "$multi/sites/.primary.env"
chmod 600 "$multi/sites/.primary.env"
for action in list status; do
    bash "$manager" "$action" > "$work/out"
    grep -Fq 'No additional sites configured' "$work/out"
    if grep -Fq 'No sites configured yet' "$work/out"; then exit 1; fi
done
