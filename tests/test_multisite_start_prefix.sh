#!/bin/bash
# Drive the full start command with an installed site and a database
# containing an already hardened admin account under a non-stock prefix.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
site=$work/docker/multi-site/sites/fixture.test
kept=$work/effective-bind
mkdir -p "$site" "$work/docker/multi-site/caddy/sites" "$kept/admin/include"
mkdir -p "$work/docker/multi-site" "$work/docker/init/lib" "$work/docker/lib"
cp "$root/docker/init/lib/kvs-archive.sh" "$work/docker/init/lib/"
cp "$root/docker/lib/host-validation.sh" "$work/docker/lib/"
cp "$root/docker/multi-site/site-manager.sh" "$work/docker/multi-site/"
echo fixture > "$site/docker-compose.yml"
echo fixture > "$work/docker/multi-site/caddy/sites/fixture.test.caddy"
export work kept
unset KVS_ADMIN_PASSWORD
# shellcheck disable=SC2329  # Used by the manager subprocess.
docker() {
    printf '%s\n' "$*" >> "$work/calls"
    case "$*" in
        'ps --format {{.Names}}') echo kvs-caddy ;;
        'compose --profile setup config --format json kvs-init')
            jq -n --arg root "$kept" --arg kind "${mount_type:-bind}" '{services:{"kvs-init":{volumes:(if $kind == "absent" then [] else [{type:$kind,target:"/var/www/kvs",source:$root}] end)}}}' ;;
        *'information_schema.tables'*)
            case "$*" in *'TABLES_PREFIX=real_ '*) echo 1 ;; *) echo 0 ;; esac ;;
        *'MD5(CONCAT('*)
            [[ "$*" == *'TABLES_PREFIX=real_ '* ]] || return 1 ;;
        'compose --profile setup run --rm --no-deps kvs-init')
            if [[ ${KVS_ADMIN_PASSWORD:-} == operator-chosen ]]; then
                echo supplied > "$work/init"
            else
                printf '%s\n' "${KVS_ADMIN_PASSWORD:+generated}" > "$work/init"
            fi ;;
    esac
    return 0
}
export -f docker
start() {
    : > "$work/calls"
    rm -f "$work/init"
    bash "$work/docker/multi-site/site-manager.sh" start fixture.test > "$work/output" 2>&1
}
refused() {
    if start; then
        echo "FAIL: start accepted $1; init password state: $(cat "$work/init")"; exit 1
    fi
    if ! grep -Fq "$2" "$work/output" || [ -e "$work/init" ] || grep -Fq 'compose stop cron' "$work/calls"; then
        cat "$work/output"
        exit 1
    fi
}
# An installed site: the manager refuses an unmarked webroot before it
# reads the prefix.
printf '%s\n' "\$config['tables_prefix']='real_';" > "$kept/admin/include/setup.php"
# shellcheck disable=SC2016  # The fixture contains a Compose interpolation.
echo 'TABLES_PREFIX=${ACTUAL_PREFIX}' > "$site/.env"
refused 'an interpolated prefix' "$site/.env"
echo 'TABLES_PREFIX=ktvs_' > "$site/.env"
refused 'a stale saved prefix' "$kept/admin/include/setup.php"
echo 'TABLES_PREFIX=real_' > "$site/.env"
printf '%s\n' "\$config['tables_prefix']='r' . 'eal_';" > "$kept/admin/include/setup.php"
refused 'a computed installed prefix' "$kept/admin/include/setup.php"
echo 'TABLES_PREFIX=ktvs_' > "$site/.env"
printf '%s\n' "\$config['tables_prefix']='bad-prefix';" > "$kept/admin/include/setup.php"
refused 'an unusable installed prefix' "$kept/admin/include/setup.php"
echo 'TABLES_PREFIX=real_' > "$site/.env"
printf '%s\n' "\$config['tables_prefix']='real_';" > "$kept/admin/include/setup.php"
mount_type=volume refused 'an uninspectable init mount' "$site/docker-compose.yml"
mount_type=volume KVS_ADMIN_PASSWORD=operator-chosen start || { cat "$work/output"; exit 1; }
[ "$(cat "$work/init")" = supplied ] || { echo 'FAIL: init did not receive the supplied password'; exit 1; }
if grep -Eq 'information_schema.tables|MD5\(CONCAT\(' "$work/calls"; then
    echo 'FAIL: start queried the admin tables despite the supplied password'
    exit 1
fi
echo 'PASS: a supplied password starts a named-volume webroot without admin queries'
mount_type=absent start || { cat "$work/output"; exit 1; }
echo 'DOMAIN=fixture.test' > "$site/.env"
start || { cat "$work/output"; exit 1; }
if [ ! -f "$work/init" ] || [ -n "$(cat "$work/init")" ]; then
    echo 'FAIL: unexpected init credential'
    exit 1
fi
grep -Fq 'information_schema.tables' "$work/calls"
grep -Fq 'MD5(CONCAT(' "$work/calls"
echo 'PASS: uncertain prefixes stop before cron or password generation; a hardened admin keeps its credential'
