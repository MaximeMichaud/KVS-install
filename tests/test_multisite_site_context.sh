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
