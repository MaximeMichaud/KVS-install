#!/bin/bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/install/docker/sites/fixture" "$work/links"
cp "$root/docker/reconfigure.sh" "$work/install/docker/"
site=$work/install/docker/sites/fixture
touch "$site/docker-compose.yml" "$work/install/docker/docker-compose.yml"
ln -s "$work/install/docker/reconfigure.sh" "$site/reconfigure.sh"
if (cd "$site" && ./reconfigure.sh) > "$work/log" 2>&1; then exit 1; fi
grep -q 'Run from docker directory' "$work/log"
[ ! -e "$site/.kvs-scripts.lock" ] && [ ! -e "$site/../kvsctl" ] || exit 1
ln -s "$work/install/docker" "$work/links/current"
if (cd "$work/links/current" && "$site/reconfigure.sh") > "$work/log" 2>&1; then exit 1; fi
grep -q '.env not found' "$work/log"
[ -f "$work/install/kvsctl/lock" ] && [ ! -e "$work/links/kvsctl" ]
