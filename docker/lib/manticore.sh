#!/bin/bash
# shellcheck disable=SC1091
# Manage only the search service and its KVS plugin on an installed site.

# A start that finds the indexes the manticore-data volume kept serves them
# at once and rebuilds them behind searchd (manticore/docker-entrypoint.sh):
# right for a restart, not once the database changed under them. This file
# in the volume makes the next start drop them and build every index from
# the database before searchd answers; it goes once a build made every
# table.
MANTICORE_REBUILD_REQUEST=/var/lib/manticore/kvs-rebuild-before-start
# Why the build before searchd failed on some tables, until a start builds
# every table, and why the rebuild behind searchd failed, until a later one
# rebuilt every table.
MANTICORE_BUILD_FAILED=/var/run/manticore/kvs-build-failed
MANTICORE_REBUILD_FAILED=/var/run/manticore/kvs-rebuild-failed
# There while the start of the container builds every table on the request.
MANTICORE_REQUESTED_BUILD=/var/run/manticore/kvs-requested-build

# Asks for that build. A container that runs read the volume when it started,
# so it goes as well: the next up starts a new one, which reads the request.
manticore_request_rebuild() {
    docker compose --profile manticore run --rm --no-deps -T --entrypoint touch \
        manticore "$MANTICORE_REBUILD_REQUEST" || return 1
    docker compose --profile manticore rm --stop --force manticore
}

# The container runs, has not been restarted, and its start is building
# every table on a request still in the volume.
manticore_requested_build_running() {
    local container
    container=$(docker compose --profile manticore ps -a -q manticore) && [ -n "$container" ] || return 1
    [ "$(docker inspect --format '{{.RestartCount}} {{.State.Status}}' "$container" 2>/dev/null)" = '0 running' ] || return 1
    # The shell of the container expands the arguments.
    # shellcheck disable=SC2016
    timeout 8 docker compose --profile manticore exec -T manticore sh -c 'test -e "$1" && test -e "$2"' \
        sh "$MANTICORE_REQUESTED_BUILD" "$MANTICORE_REBUILD_REQUEST" 2>/dev/null
}

# searchd lists the three tables, and no requested build is left: a start
# that was asked for one serves nothing before it ends. The client never
# asks searchd for TLS, which it sometimes offers at a start without being
# able to complete it.
manticore_indexes_ready() {
    local indexes kind prefix="${DOMAIN//[.-]/_}"
    indexes=$(timeout 8 docker compose --profile manticore exec -T manticore \
        mysql --skip-ssl --connect-timeout=3 -h 127.0.0.1 -P 9306 --batch --skip-column-names -e 'SHOW TABLES' 2>/dev/null) || return 1
    for kind in videos albums searches; do
        printf '%s\n' "$indexes" | cut -f1 | grep -Fxq "${prefix}_${kind}" || return 1
    done
    timeout 8 docker compose --profile manticore exec -T manticore \
        test ! -e "$MANTICORE_REBUILD_REQUEST" 2>/dev/null
}

# Prints why a build of the indexes failed; fails when none did.
manticore_rebuild_failure() {
    local failure
    failure=$(timeout 8 docker compose --profile manticore exec -T manticore \
        cat "$MANTICORE_BUILD_FAILED" "$MANTICORE_REBUILD_FAILED" 2>/dev/null) || :
    [ -n "$failure" ] || return 1
    printf '%s\n' "$failure"
}

manticore_wait_ready() {
    local budget="${MANTICORE_WAIT_SECONDS:-3600}" start=$SECONDS shown=-10 elapsed container state failure
    [[ "$budget" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: MANTICORE_WAIT_SECONDS must be a positive number of seconds" >&2
        return 1
    }
    # A build that failed on some tables leaves searchd running without
    # them: nothing to wait for.
    while failure=$(manticore_rebuild_failure) || ! manticore_indexes_ready; do
        if [ -n "${failure:-}" ]; then
            echo "ERROR: Manticore could not build every index: ${failure}. KVS search configuration has not been switched." >&2
            echo "Check: docker compose --profile manticore exec manticore cat /var/log/manticore/indexer-init.log" >&2
            return 1
        fi
        elapsed=$((SECONDS - start))
        container=$(docker compose --profile manticore ps -a -q manticore)
        state=$(docker inspect --format '{{.RestartCount}} {{.State.Status}}' "$container" 2>/dev/null) || state=missing
        if [ "$state" != '0 running' ] || [ "$elapsed" -ge "$budget" ]; then
            echo "ERROR: Manticore indexes are not ready after ${elapsed}s ($state). KVS search configuration has not been switched." >&2
            if manticore_requested_build_running; then
                echo "The build of every index from the database goes on: run ./reconfigure.sh --manticore enable again to wait for it." >&2
            fi
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

# Enable and disable switch the KVS plugin with docker compose run --build,
# which Docker Compose has from 2.13.0 on: an older one would stop enable
# there, once the indexes are built. Checked before anything changes.
manticore_require_compose() {
    local version
    version=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -n "$version" ] && [ "$(printf '%s\n' 2.13.0 "$version" | sort -V | head -n 1)" = 2.13.0 ]; then
        return 0
    fi
    echo "ERROR: --manticore $1 needs Docker Compose 2.13.0 or newer, the first whose docker compose run takes --build; found ${version:-none}. Nothing was changed." >&2
    return 1
}

# Compose builds the manticore image of this stack. On a stack kvsctl
# installed a release on, docker-compose.release.yml pins the image of the
# release and clears the build section, and a build would only print that
# there is nothing to build. Compose renders the services manticore depends
# on as well: only the block of manticore counts. A configuration Compose
# cannot read is left to the build, which says why.
manticore_builds_image() {
    local config
    config=$(docker compose --profile manticore config manticore 2>/dev/null) || return 0
    awk '
        /^[^ ]/ { services = ($0 == "services:"); service = ""; next }
        services && /^  [^ #]/ { service = $0; next }
        service == "  manticore:" && /^    build:/ { found = 1 }
        END { exit !found }' <<< "$config"
}

manticore_manage() {
    local action="$1" failure
    case "$action" in
        status)
            echo "Manticore configured: ${ENABLE_MANTICORE:-false}"
            docker compose --profile manticore ps -a manticore
            if [ "${ENABLE_MANTICORE:-false}" = true ]; then
                if failure=$(manticore_rebuild_failure); then
                    echo "Manticore could not build every index: ${failure}" >&2
                    echo "Check: docker compose --profile manticore exec manticore cat /var/log/manticore/indexer-init.log" >&2
                    return 1
                fi
                manticore_indexes_ready || { echo "Indexes are not ready." >&2; return 1; }
                manticore_verify_plugin true || { echo "KVS plugin configuration does not match the managed search service." >&2; return 1; }
                echo "Verified: all three indexes and KVS External Search configuration are enabled."
            else
                manticore_verify_plugin false || { echo "An External Search configuration still exists; inspect it before changing search." >&2; return 1; }
                echo "Verified: KVS uses its built-in search."
            fi
            ;;
        enable)
            manticore_require_compose enable || return 1
            # Only the search service is started. An interrupted database
            # import must never be restarted by this operation.
            source "$(dirname "${BASH_SOURCE[0]}")/database.sh"
            database_root_query -h 127.0.0.1 --protocol=tcp -e 'SELECT 1' >/dev/null || {
                echo "ERROR: MariaDB must already be running and ready before enabling search." >&2
                return 1
            }
            # The volume may keep indexes from before search was disabled,
            # or from another database: KVS is switched to indexes built
            # from this one only. A build an earlier request started, which
            # outlasted the wait of an earlier enable for instance, is
            # waited for: removing its container would start it over.
            if manticore_builds_image; then
                docker compose --profile manticore build manticore || return 1
            fi
            if manticore_requested_build_running; then
                echo "  Manticore is still building every index from the database on an earlier request: waiting for that build."
            else
                manticore_request_rebuild || return 1
                docker compose --profile manticore up -d --no-deps manticore || return 1
            fi
            manticore_wait_ready || return 1
            manticore_configure_plugin true || return 1
            add_compose_profile manticore || return 1
            set_env_value ENABLE_MANTICORE true || return 1
            echo "Manticore enabled. Indexes built from the current database and the saved KVS plugin configuration were verified."
            ;;
        disable)
            manticore_require_compose disable || return 1
            manticore_configure_plugin false || return 1
            docker compose --profile manticore stop manticore || return 1
            remove_compose_profile manticore || return 1
            set_env_value ENABLE_MANTICORE false || return 1
            echo "Manticore disabled. KVS uses its built-in search; the index volume is retained."
            ;;
        *) echo "ERROR: use --manticore enable|disable|status" >&2; return 1 ;;
    esac
}
