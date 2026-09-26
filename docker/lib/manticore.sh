#!/bin/bash
# shellcheck disable=SC1091
# Manage only the search service and its KVS plugin on an installed site.

manticore_indexes_ready() {
    local indexes kind prefix="${DOMAIN//[.-]/_}"
    indexes=$(timeout 8 docker compose --profile manticore exec -T manticore \
        mysql --connect-timeout=3 -h 127.0.0.1 -P 9306 --batch --skip-column-names -e 'SHOW TABLES' 2>/dev/null) || return 1
    for kind in videos albums searches; do
        printf '%s\n' "$indexes" | cut -f1 | grep -Fxq "${prefix}_${kind}" || return 1
    done
}

manticore_wait_ready() {
    local budget="${MANTICORE_WAIT_SECONDS:-3600}" start=$SECONDS shown=-10 elapsed container state
    [[ "$budget" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: MANTICORE_WAIT_SECONDS must be a positive number of seconds" >&2
        return 1
    }
    while ! manticore_indexes_ready; do
        elapsed=$((SECONDS - start))
        container=$(docker compose --profile manticore ps -a -q manticore)
        state=$(docker inspect --format '{{.RestartCount}} {{.State.Status}}' "$container" 2>/dev/null) || state=missing
        if [ "$state" != '0 running' ] || [ "$elapsed" -ge "$budget" ]; then
            echo "ERROR: Manticore indexes are not ready after ${elapsed}s ($state). KVS search configuration has not been switched." >&2
            echo "Check: docker compose --profile manticore logs manticore" >&2
            return 1
        fi
        if [ "$((elapsed - shown))" -ge 10 ]; then
            echo "  Waiting for videos, albums and searches indexes (${elapsed}s elapsed)..."
            docker compose --profile manticore logs --tail 3 manticore
            shown=$elapsed
        fi
        sleep 2
    done
}

# Verify the serialized file from the running PHP container, not the init
# command's exit status. A missing file is KVS's built-in search default.
manticore_verify_plugin() {
    docker compose exec -T php-fpm php -r '
        $file = "/var/www/kvs/admin/data/plugins/external_search/data.dat";
        if ($argv[1] === "false") exit(file_exists($file) ? 1 : 0);
        $data = @unserialize(@file_get_contents($file), ["allowed_classes" => false]);
        if (!is_array($data)) exit(1);
        foreach (["videos" => "", "albums" => "_albums", "searches" => "_searches"] as $kind => $suffix) {
            if (($data["enable_external_search".$suffix] ?? null) !== 1 ||
                ($data["display_results".$suffix] ?? null) !== 0 ||
                ($data["api_call".$suffix] ?? null) !== "http://manticore-api:8080/kvs_manticore_search_".$kind.".php?query=%QUERY%&limit=%LIMIT%&from=%FROM%" ||
                !is_file("/var/www/manticore-api/kvs_manticore_search_".$kind.".php")) exit(1);
        }
    ' "$1"
}

manticore_configure_plugin() {
    docker compose --profile setup run --rm --no-deps --build -T \
        -e "ENABLE_MANTICORE=$1" --entrypoint bash kvs-init /init/docker-entrypoint.d/80-manticore.sh || return 1
    manticore_verify_plugin "$1"
}

manticore_manage() {
    local action="$1"
    case "$action" in
        status)
            echo "Manticore configured: ${ENABLE_MANTICORE:-false}"
            docker compose --profile manticore ps -a manticore
            if [ "${ENABLE_MANTICORE:-false}" = true ]; then
                manticore_indexes_ready || { echo "Indexes are not ready." >&2; return 1; }
                manticore_verify_plugin true || { echo "KVS plugin configuration does not match the managed search service." >&2; return 1; }
                echo "Verified: all three indexes and KVS External Search configuration are enabled."
            else
                manticore_verify_plugin false || { echo "An External Search configuration still exists; inspect it before changing search." >&2; return 1; }
                echo "Verified: KVS uses its built-in search."
            fi
            ;;
        enable)
            # Only the search service is started. An interrupted database
            # import must never be restarted by this operation.
            source "$(dirname "${BASH_SOURCE[0]}")/database.sh"
            database_root_query -h 127.0.0.1 --protocol=tcp -e 'SELECT 1' >/dev/null || {
                echo "ERROR: MariaDB must already be running and ready before enabling search." >&2
                return 1
            }
            docker compose --profile manticore up -d --no-deps --build manticore || return 1
            manticore_wait_ready || return 1
            manticore_configure_plugin true || return 1
            add_compose_profile manticore || return 1
            set_env_value ENABLE_MANTICORE true || return 1
            echo "Manticore enabled. Indexes and the saved KVS plugin configuration were verified."
            ;;
        disable)
            manticore_configure_plugin false || return 1
            docker compose --profile manticore stop manticore || return 1
            remove_compose_profile manticore || return 1
            set_env_value ENABLE_MANTICORE false || return 1
            echo "Manticore disabled. KVS uses its built-in search; the index volume is retained."
            ;;
        *) echo "ERROR: use --manticore enable|disable|status" >&2; return 1 ;;
    esac
}
