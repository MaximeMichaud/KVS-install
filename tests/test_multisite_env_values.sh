#!/bin/bash
# Exercise the site identities used by the manager with hand-edited .env files.
# shellcheck disable=SC2016  # Compose expands these literal fixture settings.
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
# shellcheck disable=SC2329  # Used by child managers.
docker() {
    case "$*" in
        'compose config')
            if [[ -f $work/model ]]; then cat "$work/model"; else command docker "$@"; fi ;;
        'ps --format {{.Names}}') echo live-nginx ;;
        'ps '*) return 0 ;;
        'volume ls '*)
            if [[ "$*" == *"label=com.docker.compose.project=held "* && ! -e $work/volume-removed ]]; then echo held_data; fi ;;
        'compose -p held down -v --remove-orphans') touch "$work/volume-removed" ;;
        'compose -p true down -v --remove-orphans') touch "$work/quoted-down" ;;
        'compose -p live down -v --remove-orphans') touch "$work/down" ;;
        *) echo "Unexpected Docker command: $*" >&2; return 91 ;;
    esac
}
export -f docker

write_value() {
    printf '%s=stale\r\n  export %s = "%s" # comment\r\n' "$1" "$1" "$2"
}
write_value SITE_PREFIX live > "$site/.env"
bash "$manager" list > "$work/out"
grep -Fq 'media.example (running)' "$work/out"
if bash "$manager" primary-config primary.example live internal > "$work/out"; then exit 1; fi
grep -Fq 'already used by media.example' "$work/out"

printf 'SITE_PREFIX=live  # active\r\n' > "$site/.env"
bash "$manager" list > "$work/out"
grep -Fq 'media.example (running)' "$work/out"

# A reservation still has exactly one DOMAIN and one SITE_PREFIX.
printf "  export DOMAIN='primary.example' # reserved\r\nexport SITE_PREFIX=\"primary\"\r\n" > "$multi/sites/.primary.env"
chmod 600 "$multi/sites/.primary.env"
bash "$manager" primary-config primary.example primary internal > "$work/out"
bash "$manager" primary-remove primary.example primary > "$work/out"

printf 'services: {}\n' > "$site/docker-compose.yml"
write_value COMPOSE_PROJECT_NAME live >> "$site/.env"
for key in COMPOSE_PROJECT_NAME SITE_PREFIX; do
    write_value "$key" live > "$work/docker/.env"
    if bash "$manager" remove media.example <<< yes > "$work/out"; then exit 1; fi
    grep -Fq 'primary site uses that project name' "$work/out"
done
rm "$work/docker/.env"
bash "$manager" remove media.example <<< yes > "$work/out"
[[ -e $work/down && ! -d $site ]]

# With no Compose file, a volume under either name still holds the site.
for key in COMPOSE_PROJECT_NAME SITE_PREFIX; do
    mkdir -p "$site"
    write_value "$key" held > "$site/.env"
    if bash "$manager" remove media.example > "$work/out"; then exit 1; fi
    grep -Fq 'volumes of held: held_data' "$work/out"
done
# With a Compose file but no project setting, infer the owner from volumes.
printf 'services: {}\n' > "$site/docker-compose.yml"
bash "$manager" remove media.example <<< yes > "$work/out"
[[ -e $work/volume-removed && ! -d $site ]]

# Compose resolves interpolated and top-level project names with local overrides.
mkdir -p "$site"
printf 'services: {}\n' > "$site/docker-compose.yml"
printf 'BASE=live\nCOMPOSE_PROJECT_NAME=${BASE}\n' > "$site/.env"
bash "$manager" remove media.example <<< yes > "$work/out"
[[ ! -d $site ]]
mkdir -p "$site"
printf 'name: live\nservices: {}\n' > "$site/docker-compose.yml"
printf 'SITE_PREFIX=old\n' > "$site/.env"
bash "$manager" remove media.example <<< yes > "$work/out"
[[ ! -d $site ]]

# Without a model to render, an ambiguous identity must never yield an rm instruction.
mkdir -p "$site"
unsupported=(
    'COMPOSE_PROJECT_NAME=${BASE}'
    'SITE_PREFIX: held'
    'COMPOSE_PROJECT_NAME=-held'
    'COMPOSE_FILE=custom.yml'
    'COMPOSE_PROJECT_NAME="held"junk'
    "COMPOSE_PROJECT_NAME='held"
)
# An escaped quote on the end of a line can hide the following assignment
# inside an unrelated multiline value.
for quote in '"' "'"; do
    unsupported+=("$(printf 'NOTE=%scontinued\\%s\nCOMPOSE_PROJECT_NAME=hidden\nTAIL=end%s\n' "$quote" "$quote" "$quote")")
done
for assignment in "${unsupported[@]}"; do
    printf '%s\n' "$assignment" > "$site/.env"
    if bash "$manager" remove media.example > "$work/out" 2>&1; then exit 1; fi
    grep -Fq 'Cannot verify' "$work/out"
    if grep -Fq 'rm -r --' "$work/out"; then exit 1; fi
done

rm "$site/.env"
mkdir "$site/.env"
if bash "$manager" remove media.example > "$work/out" 2>&1; then exit 1; fi
grep -Fq 'is not a regular file' "$work/out"
rmdir "$site/.env"

# Real Compose quotes a YAML boolean used as a project name.
printf 'services: {}\n' > "$site/docker-compose.yml"
write_value COMPOSE_PROJECT_NAME true > "$site/.env"
bash "$manager" remove media.example <<< yes > "$work/out"
[[ -e $work/quoted-down && ! -d $site ]]
mkdir -p "$site"
printf 'services: {}\n' > "$site/docker-compose.yml"
write_value COMPOSE_PROJECT_NAME live > "$site/.env"
for output in '  name: nested' 'name: "bad name"'; do
    printf '%s\n' "$output" > "$work/model"
    if bash "$manager" remove media.example <<< yes > "$work/out" 2>&1; then exit 1; fi
    grep -Fq 'No valid top-level project name' "$work/out"
    [[ -d $site ]]
done
rm "$work/model"

# An effective primary project also protects a stopped primary's volumes.
printf 'services: {}\n' > "$site/docker-compose.yml"
write_value COMPOSE_PROJECT_NAME live > "$site/.env"
printf 'name: ${BASE}\nservices: {}\n' > "$work/docker/docker-compose.yml"
printf 'BASE=live\n' > "$work/docker/.env"
if bash "$manager" remove media.example <<< yes > "$work/out"; then exit 1; fi
grep -Fq 'primary site uses that project name' "$work/out"
for model in "$work/docker/docker-compose.yml" "$site/docker-compose.yml"; do
    printf 'invalid: [\n' > "$model"
    if bash "$manager" remove media.example <<< yes > "$work/out" 2>&1; then exit 1; fi
    [[ -s $site/.env ]]
    rm "$model"
done
