#!/bin/bash
# shellcheck disable=SC2016  # Shell snippets are expanded inside the container.
# Read-only MariaDB startup/import monitoring, shared by setup and reconfigure.

database_root_query() {
    timeout 8 docker compose exec -T mariadb sh -c '
        MYSQL_PWD=$MARIADB_ROOT_PASSWORD
        export MYSQL_PWD
        exec mariadb --connect-timeout=3 -u root "$@"
    ' sh "$@"
}

database_import_snapshot() {
    local prefix="${TABLES_PREFIX:-ktvs_}"
    [[ "$prefix" =~ ^[A-Za-z0-9_]{1,32}$ ]] || return 1
    # Never print SQL text or row values. The process list only supplies
    # operation/state and a quoted table identifier for known statements.
    database_root_query --batch --skip-column-names --database="$DOMAIN" 2>/dev/null <<SQL
SET SESSION max_statement_time=2;
SET SESSION lock_wait_timeout=1;
SELECT 'tables', COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND LEFT(table_name, LENGTH('$prefix'))='$prefix' AND table_type='BASE TABLE';
SELECT 'pool', @@innodb_buffer_pool_size;
SELECT 'active', COUNT(*) FROM information_schema.processlist WHERE id<>CONNECTION_ID() AND db=DATABASE() AND command<>'Sleep';
SELECT LOWER(variable_name), variable_value FROM information_schema.global_status WHERE variable_name='INNODB_DATA_WRITTEN';
SELECT 'operation', COALESCE(NULLIF(state,''),command), time,
 CASE WHEN info REGEXP '^(INSERT INTO|REPLACE INTO|CREATE TABLE|ALTER TABLE|LOCK TABLES|LOAD DATA) ' AND LOCATE(CHAR(96),info)>0
 THEN CASE WHEN SUBSTRING_INDEX(SUBSTRING_INDEX(info,CHAR(96),3),CHAR(96),-1) REGEXP '^[[:space:]]*[.][[:space:]]*$'
      THEN SUBSTRING_INDEX(SUBSTRING_INDEX(info,CHAR(96),4),CHAR(96),-1)
      ELSE SUBSTRING_INDEX(SUBSTRING_INDEX(info,CHAR(96),2),CHAR(96),-1) END
 ELSE '-' END,
 ROUND(progress,1)
 FROM information_schema.processlist WHERE id<>CONNECTION_ID() AND db=DATABASE() AND command<>'Sleep' ORDER BY time DESC LIMIT 1;
SQL
}

# Inspect the reader's file position, including zstd/gzip/xz on compressed
# dumps. This measures input consumed, not SQL committed. No process command
# lines are read, since they may hold credentials on older installations.
database_dump_position() {
    # The image replays dumps as mysql. Matching its UID allows /proc FD
    # inspection without granting SYS_PTRACE to the container.
    timeout 8 docker compose exec -T --user mysql mariadb sh -c '
        for process in /proc/[0-9]*; do
            read -r name < "$process/comm" 2>/dev/null || continue
            case "$name" in mariadb|mysql|zstd|gzip|gunzip|xz|cat) ;; *) continue ;; esac
            for fd in "$process"/fd/*; do
                target=$(readlink "$fd" 2>/dev/null) || continue
                case "$target" in
                    /docker-entrypoint-initdb.d/*kvs-import.sql|/docker-entrypoint-initdb.d/*kvs-import.sql.zst|/docker-entrypoint-initdb.d/*kvs-import.sql.gz|/docker-entrypoint-initdb.d/*kvs-import.sql.xz) ;;
                    *) continue ;;
                esac
                size=$(stat -Lc %s "$fd" 2>/dev/null) || continue
                while read -r key value; do
                    [ "$key" = pos: ] || continue
                    printf "%s\t%s\n" "$value" "$size"
                    exit 0
                done < "$process/fdinfo/${fd##*/}"
            done
        done
    ' 2>/dev/null
}

database_size_text() {
    awk -v bytes="${1:-0}" 'BEGIN {
        if (bytes >= 1073741824) printf "%.2f GiB", bytes/1073741824
        else printf "%.1f MiB", bytes/1048576
    }'
}

database_progress_line() {
    local elapsed="$1" snapshot="$2" position="$3"
    local key a b c d tables="?" written="" pool="" operation="" active="" bytes=0 total=0 pct
    while IFS=$'\t' read -r key a b c d; do
        case "$key" in
            tables) tables=$a ;;
            pool) pool=$a ;;
            active) active=$a ;;
            innodb_data_written) written=$a ;;
            operation)
                # Sanitize server-supplied names/states before the terminal.
                a=$(printf '%s' "$a" | tr -cd '[:alnum:] _./()-')
                c=$(printf '%s' "$c" | tr -cd '[:alnum:] _.-')
                operation="; $a${c:+ on $c}, ${b}s"
                if [[ "$d" =~ ^[0-9]+([.][0-9]+)?$ ]] && [ "${d%%.*}" -gt 0 ]; then
                    operation="$operation (statement $d%)"
                fi
                ;;
        esac
    done <<< "$snapshot"
    read -r bytes total <<< "$position" || true
    printf '  MariaDB: %d:%02d:%02d waiting' "$((elapsed / 3600))" "$((elapsed / 60 % 60))" "$((elapsed % 60))"
    if [[ "$bytes" =~ ^[0-9]+$ && "$total" =~ ^[1-9][0-9]*$ ]]; then
        pct=$((100 * bytes / total))
        [ "$pct" -le 100 ] || pct=100
        printf '; dump read %s / %s (%s%%, SQL may still be running)' "$(database_size_text "$bytes")" "$(database_size_text "$total")" "$pct"
    fi
    if [ -n "$snapshot" ]; then
        printf '; %s%s tables created' "$tables" "${IMPORT_DUMP_TABLES:+/$IMPORT_DUMP_TABLES}"
        [ -z "$written" ] || printf '; InnoDB written %s since startup' "$(database_size_text "$written")"
        [ -z "$pool" ] || printf '; buffer pool %s' "$(database_size_text "$pool")"
        [ -z "$active" ] || printf '; %s active SQL sessions' "$active"
        printf '%s' "$operation"
    else
        printf '; starting or restarting the database server (SQL status unavailable)'
    fi
    printf '\n'
}

# A conservative connection budget for native LOAD DATA jobs. Keep a memory
# reserve for MariaDB and the shared KVS host; manual concurrency is explicit.
database_import_jobs_for_resources() {
    local cpus="$1" available="$2" pool="$3" jobs memory_jobs
    [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || cpus=1
    [[ "$available" =~ ^[0-9]+$ ]] || available=512
    [[ "$pool" =~ ^[0-9]+$ ]] || pool=128
    jobs=$cpus
    [ "$jobs" -le 8 ] || jobs=8
    memory_jobs=$(((available - pool - 256) / 256))
    [ "$memory_jobs" -ge 1 ] || memory_jobs=1
    [ "$jobs" -le "$memory_jobs" ] || jobs=$memory_jobs
    printf '%s\n' "$jobs"
}

database_compose_cpu_limit() {
    local config
    config=$(docker compose config) || return 1
    printf '%s\n' "$config" | awk '
        /^  mariadb:$/ { db=1; next }
        db && /^  [^ ]/ { db=0 }
        db && /^    deploy:/ { deploy=1; next }
        db && /^    [^ ]/ { deploy=0; resources=0; limits=0 }
        db && deploy && /^      resources:/ { resources=1; next }
        resources && /^      [^ ]/ { resources=0; limits=0 }
        db && resources && /^        limits:/ { limits=1; next }
        limits && /^        [^ ]/ { limits=0 }
        db && (/^    cpus:/ || (limits && /^          cpus:/)) {
            value=$2; gsub(/"/, "", value)
            if (value+0>0 && (!min || value+0<min)) min=value+0
        }
        END { print min ? (int(min)<1 ? 1 : int(min)) : 0 }
    '
}

database_import_jobs() {
    local requested="${1:-auto}" available limit cpus cpu_limit pool
    if [ "$requested" != auto ]; then
        [[ "$requested" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || {
            echo "ERROR: IMPORT_DATABASE_JOBS must be auto or an integer from 1 to 32" >&2
            return 1
        }
        printf '%s\n' "$requested"
        return 0
    fi
    available=$(database_available_memory_mb)
    limit=$(database_compose_memory_limit) || return 1
    if [ "$limit" -gt 0 ] && [ "$((limit / 1048576))" -lt "$available" ]; then
        available=$((limit / 1048576))
    fi
    cpus=$(nproc 2>/dev/null) || cpus=1
    cpu_limit=$(database_compose_cpu_limit) || return 1
    if [ "$cpu_limit" -gt 0 ] && [ "$cpu_limit" -lt "$cpus" ]; then cpus=$cpu_limit; fi
    pool=${MARIADB_BUFFER_POOL_SIZE:-128M}
    case "$pool" in
        *[Gg]) pool=$((${pool%?} * 1024)) ;;
        *[Mm]) pool=${pool%?} ;;
        *) pool=128 ;;
    esac
    database_import_jobs_for_resources "$cpus" "$available" "$pool"
}

# Wait against wall time, not an assumed two seconds per iteration. A socket
# accepts SQL during the init replay, but readiness still requires TCP and
# setup separately verifies its unique final SQL completion marker.
database_wait_ready() {
    local budget="$1" once="${2:-no}" start=$SECONDS shown=-10 elapsed container state snapshot position
    [[ "$budget" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: MARIADB_WAIT_SECONDS must be a positive number of seconds" >&2
        return 1
    }
    echo "  Waiting for MariaDB; import activity is reported every 10 seconds."
    while :; do
        elapsed=$((SECONDS - start))
        container=$(docker compose ps -a -q mariadb 2>/dev/null | head -n 1)
        if [ -z "$container" ]; then
            echo "ERROR: no MariaDB container found for this Compose project." >&2
            return 1
        fi
        state=$(docker inspect --format '{{.RestartCount}} {{.State.Status}}' "$container" 2>/dev/null) || state="0 unknown"
        if [[ "$state" != "0 running" && "$state" != "0 created" && "$state" != "0 unknown" ]]; then
            echo "ERROR: MariaDB stopped or restarted during initialization ($state)." >&2
            docker compose logs --tail 20 mariadb >&2
            return 1
        fi
        if [ "$elapsed" -ge "$budget" ]; then
            echo "ERROR: MariaDB not ready after $elapsed seconds (MARIADB_WAIT_SECONDS=$budget)." >&2
            echo "The database container is left running. Inspect it with ./reconfigure.sh --import-status or docker compose logs mariadb." >&2
            return 1
        fi
        if database_root_query -h 127.0.0.1 --protocol=tcp -e 'SELECT 1' > /dev/null 2>&1; then
            echo "  MariaDB accepts TCP connections after $elapsed seconds. This alone does not verify an import; setup checks its completion marker separately."
            snapshot=$(database_import_snapshot) || true
            database_progress_line "$elapsed" "$snapshot" ""
            return 0
        fi
        if [ "$once" = yes ] || [ "$((elapsed - shown))" -ge 10 ]; then
            snapshot=$(database_import_snapshot) || true
            position=$(database_dump_position) || true
            database_progress_line "$elapsed" "$snapshot" "$position"
            shown=$elapsed
        fi
        [ "$once" != yes ] || return 0
        sleep 2
    done
}

# Reserve most memory for the rest of this shared KVS host. Explicit sizes
# persist unchanged. The automatic value is 25% of available RAM, bounded
# to 128 MiB..4 GiB, rather than MariaDB's fixed 128 MiB default.
database_buffer_pool_for_host() {
    local available_mb="$1" size
    [[ "$available_mb" =~ ^[1-9][0-9]*$ ]] || available_mb=512
    size=$((available_mb / 4 / 128 * 128))
    [ "$size" -ge 128 ] || size=128
    [ "$size" -le 4096 ] || size=4096
    printf '%sM\n' "$size"
}

# Compose normalizes memory limits to bytes in its canonical YAML output.
# Read only the MariaDB service, including deploy.resources.limits.memory.
# Do not print the full configuration: it contains database credentials.
database_compose_memory_limit() {
    local config
    config=$(docker compose config) || return 1
    printf '%s\n' "$config" | awk '
        /^  mariadb:$/ { db=1; next }
        db && /^  [^ ]/ { db=0 }
        db && /^    mem_limit:/ { value=$2; gsub(/"/, "", value); if (value+0>0 && (!min || value+0<min)) min=value+0 }
        db && /^    deploy:$/ { deploy=1; next }
        db && /^    [^ ]/ { deploy=0 }
        deploy && /^      resources:$/ { resources=1; next }
        deploy && /^      [^ ]/ { resources=0 }
        resources && /^        limits:$/ { limits=1; next }
        resources && /^        [^ ]/ { limits=0 }
        db && deploy && resources && limits && /^          memory:/ {
            value=$2; gsub(/"/, "", value); if (value+0>0 && (!min || value+0<min)) min=value+0
        }
        END { printf "%.0f\n", min }
    '
}

# Account for an installer running inside an LXC/container or constrained
# systemd slice as well as the memory available to the rest of the host.
database_available_memory_mb() {
    local available path relative limit usage remaining root file
    available=$(awk '/^MemAvailable:/ { print int($2/1024) }' /proc/meminfo)
    [[ "$available" =~ ^[0-9]+$ ]] || available=512
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        root=/sys/fs/cgroup
        relative=$(awk -F: '$1==0 { print $3 }' /proc/self/cgroup)
        file=memory.max
    else
        root=/sys/fs/cgroup/memory
        relative=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ { print $3 }' /proc/self/cgroup)
        file=memory.limit_in_bytes
    fi
    path="$root$relative"
    [ -d "$path" ] || path=$root
    while [[ "$path" == "$root" || "$path" == "$root/"* ]]; do
        if [ -r "$path/$file" ]; then
            read -r limit < "$path/$file"
            usage=0
            if [ "$file" = memory.max ]; then
                read -r usage < "$path/memory.current" || true
            else
                read -r usage < "$path/memory.usage_in_bytes" || true
            fi
            if [[ "$limit" =~ ^[0-9]+$ && "$usage" =~ ^[0-9]+$ ]]; then
                remaining=$(((limit - usage) / 1048576))
                [ "$remaining" -ge 0 ] || remaining=0
                [ "$remaining" -ge "$available" ] || available=$remaining
            fi
        fi
        [ "$path" != "$root" ] || break
        path=${path%/*}
    done
    printf '%s\n' "$available"
}

database_configure_buffer_pool() {
    local available limit size_mb value
    available=$(database_available_memory_mb)
    limit=$(database_compose_memory_limit) || return 1
    if [ "$limit" -gt 0 ] && [ "$((limit / 1048576))" -lt "$available" ]; then
        available=$((limit / 1048576))
    fi
    value=${MARIADB_BUFFER_POOL_SIZE_REQUEST:-${MARIADB_BUFFER_POOL_SIZE:-}}
    if [ -z "$value" ]; then
        value=$(database_buffer_pool_for_host "$available")
    fi
    if [[ ! "$value" =~ ^[1-9][0-9]*[MmGg]$ ]]; then
        echo "ERROR: MARIADB_BUFFER_POOL_SIZE must be a size in M or G, for example 512M or 2G" >&2
        return 1
    fi
    size_mb=${value%?}
    [[ "$value" != *[Gg] ]] || size_mb=$((size_mb * 1024))
    if [ "$limit" -gt 0 ] && [ "$size_mb" -ge "$((limit / 1048576))" ]; then
        echo "ERROR: the $value buffer pool leaves no memory for MariaDB inside its Docker memory limit. Lower MARIADB_BUFFER_POOL_SIZE." >&2
        return 1
    fi
    set_env_value MARIADB_BUFFER_POOL_SIZE "$value" || return 1
    MARIADB_BUFFER_POOL_SIZE=$value
    export MARIADB_BUFFER_POOL_SIZE
    echo "  MariaDB InnoDB buffer pool: $value (kept in .env; automatic budget: 25% of $available MiB, at most 4 GiB)."
}
