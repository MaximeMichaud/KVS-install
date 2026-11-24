#!/bin/bash
# The installer and init must open the same licensed file as the host.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/install/.git" "$work/install/docker/kvs-archive"
touch "$work/install/kvs-install.sh"
cd "$work/install/docker"
(cd "$root/docker" && cp --parents images.lock bin/resolve-bases.sh lib/kvs-php.sh init/lib/kvs-archive.sh \
    multi-site/site-manager.sh multi-site/docker-compose.site.yml.template "$work/install/docker")
printf 'DOMAIN=a.example\n' > .env
cp .env .env.example
cat > setup.sh <<'SETUP'
#!/bin/bash
printf '%s\n' "${DOMAIN:-saved}" > setup-domain
SETUP
archive() {
    mkdir -p "$work/content/admin/include"
    printf "<?php\n\x24config['tables_prefix']=\"%s\";\n" "$2" > "$work/content/admin/include/setup.php"
    (cd "$work/content" && zip -q "$1" admin/include/setup.php)
}
for domain in a.example b.example; do
    archive "$PWD/kvs-archive/KVS_7.0.3_[$domain].zip" local_
done
# shellcheck disable=SC2034,SC2329  # dockerInstall uses these callbacks and settings.
install() (
    # shellcheck source=/dev/null
    source "$root/kvs-install.sh"
    refuse_during_kvsctl_run() { :; }
    recover_kvsctl_data() { :; }
    refuse_kvsctl_managed_install() { :; }
    ensure_docker_prerequisites() { :; }
    update_kvs_install() { :; }
    docker() { [[ "$*" == 'compose version' ]]; }
    archive_is_valid() {
        printf '%s\n' "$1" > checked
        unzip -tq "$1" >/dev/null
    }
    archive_domain_from_name() { printf '%s\n' "$1" > named; }
    export KVS_INSTALL_DIR="$work/install" HEADLESS=y
    unset DOMAIN
    if [ -n "$1" ]; then export DOMAIN="$1"; fi
    dockerInstall
)
for domain in b.example a.example; do
    explicit=$domain
    [ "$domain" != a.example ] || explicit=''
    install "$explicit" > "$work/install.log" 2>&1 || { cat "$work/install.log"; exit 1; }
    file="KVS_7.0.3_[$domain].zip"
    [[ $(cat checked) == "kvs-archive/$file" && $(cat named) == "$file" &&
        $(cat setup-domain) == "${explicit:-saved}" ]] || { echo "Incorrect installer selection for $domain"; exit 1; }
done
rm setup-domain
if install missing.example > "$work/install.log" 2>&1 || [ -e setup-domain ]; then
    echo "The installer accepted a directory without the requested licence"
    exit 1
fi

custom="$work/owner's archive \$dir"
mkdir "$custom"
ln -s "$custom" archive-link
for domain in a.example b.example; do
    archive "$custom/KVS_7.0.3_[$domain].zip" "${domain%%.*}_"
done
real_docker=$(type -P docker)
# shellcheck disable=SC2329  # Exported to the manager.
docker() { [[ "$1" == ps || "$1" == volume ]]; }
# shellcheck disable=SC2329  # Exported to the manager.
chown() { :; }
export -f docker chown
for domain in b.example a.example; do
    KVS_ARCHIVE_DIR=archive-link KVS_WEBROOT_BASE="$work/www" bash multi-site/site-manager.sh add "$domain" > "$work/add.log"
    site="$PWD/multi-site/sites/$domain"
    chosen="$custom/KVS_7.0.3_[$domain].zip"
    grep -Fxq "TABLES_PREFIX=${domain%%.*}_" "$site/.env"
    config=$(cd "$site" && "$real_docker" compose --profile setup config --format json)
    bind=$(jq -er '[.services["kvs-init"].volumes[] | select(.target | startswith("/kvs-archive"))]
        | select(length == 1) | .[0] | select(.type == "bind" and .read_only and (.bind.create_host_path == false)
        and (.target | test("^/kvs-archive/KVS_[^/]+\\.zip$"))) | .source' <<< "$config") ||
        { echo "Init can see more than the selected archive for $domain"; exit 1; }
    [[ -f "$bind" && $(realpath "$bind") == "$chosen" ]] || { echo "Init mounted the wrong licence for $domain"; exit 1; }
done
# Retargeting the host's archive directory alias must not redirect an existing site.
ln -sfn "$PWD/kvs-archive" archive-link
[[ $(realpath "$bind") == "$chosen" ]] || { echo "The configured archive path was not resolved"; exit 1; }
# A licence link can resolve on the host and still be dangling in the init.
file='KVS_7.0.3_[b.example].zip'
mv "kvs-archive/$file" "$work/b.zip"
ln -s "$work/b.zip" "kvs-archive/$file"
for neighbors in present absent; do
    if [ "$neighbors" = absent ]; then rm 'kvs-archive/KVS_7.0.3_[a.example].zip'; fi
    if install b.example > "$work/install.log" 2>&1; then echo "Installer accepted a licence link"; exit 1; fi
    grep -Fq "kvs-archive/$file is a symbolic link" "$work/install.log"
    if KVS_WEBROOT_BASE="$work/other" bash multi-site/site-manager.sh add link.example > "$work/add.log" 2>&1; then
        echo "Add accepted a licence link"; exit 1
    fi
    grep -Fq "$file is a symbolic link" "$work/add.log"
done

export real_docker work
# shellcheck disable=SC2329  # Called by the manager.
docker() {
    case "$*" in
        'ps --format {{.Names}}') echo kvs-caddy ;;
        'compose --profile setup config --format json kvs-init') "$real_docker" "$@" ;;
        'compose ps --status running --quiet cron') return 0 ;;
        'compose stop cron') touch "$work/cron"; return 26 ;;
        *) return 99 ;;
    esac
}
export -f docker
start() {
    rm -f "$work/cron"
    start_status=0
    bash multi-site/site-manager.sh start b.example > "$work/start.log" 2>&1 || start_status=$?
}
site="$PWD/multi-site/sites/b.example"
mv "$custom/$file" "$work/moved.zip"
start
[[ $start_status != 0 && ! -e "$work/cron" ]] || { echo "Stopped cron with a missing archive"; exit 1; }
grep -Fq "$site/archive.zip" "$work/start.log" ||
    { echo "Missing archive was not diagnosed before stopping cron"; exit 1; }
mv "$work/moved.zip" "$custom/$file"
start
[[ $start_status == 26 && -e "$work/cron" ]]

# A legacy compose and a refreshed template without the new setting both
# expose the directory. Use the effective bind even if .env suggests a file.
rm "$site/archive.zip" "kvs-archive/$file"
cp "$custom"/*.zip kvs-archive/
cat > "$site/docker-compose.yml" <<'LEGACY'
services:
  kvs-init:
    image: fixture
    volumes:
      - ../../../kvs-archive:/kvs-archive:ro
LEGACY
for layout in original refreshed; do
    if [ "$layout" = refreshed ]; then
        cp multi-site/docker-compose.site.yml.template "$site/docker-compose.yml"
        sed -i '/^KVS_SITE_ARCHIVE=/d' "$site/.env"
    fi
    before=$(sha256sum "$site/docker-compose.yml" "$site/.env")
    start
    [[ $start_status != 0 && ! -e "$work/cron" && "$before" == "$(sha256sum "$site/docker-compose.yml" "$site/.env")" ]]
    for expected in "$PWD/kvs-archive/$file" 'ln -sT --' "$site/archive.zip" "$site/docker-compose.yml" \
        'source: ./archive.zip' 'target: /kvs-archive/KVS_site.zip' 'create_host_path: false'; do
        grep -Fq "$expected" "$work/start.log" || { echo "Missing migration step: $expected"; exit 1; }
    done
done
# Apply the instructions to the original service's volume and retry.
ln -sT -- "$PWD/kvs-archive/$file" "$site/archive.zip"
{ printf 'services:\n  kvs-init:\n    image: fixture\n    volumes:\n'; sed -n '/^      - type:/,/create_host_path: false/p' "$work/start.log"; } > "$site/docker-compose.yml"
start
[[ $start_status == 26 && -e "$work/cron" ]]
cp multi-site/docker-compose.site.yml.template "$site/docker-compose.yml"
rm 'kvs-archive/KVS_7.0.3_[a.example].zip'
start
[[ $start_status == 26 && -e "$work/cron" ]] || { echo "Legacy single archive refused"; exit 1; }
echo "PASS: the installer validates and names the selected file, and each new site's init sees only its archive"
