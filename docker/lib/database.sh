#!/bin/bash
# shellcheck disable=SC2016  # Shell snippets are expanded inside the container.
# MariaDB sizing, persistent configuration and read-only import monitoring.

database_root_query() {
    local arg
    local -a query=(timeout -k 1 8 docker compose exec -T mariadb sh -c '
        MYSQL_PWD=$MARIADB_ROOT_PASSWORD
        export MYSQL_PWD
        exec mariadb --connect-timeout=3 -u root "$@"
    ' sh "$@")
    # Compose still attaches stdin with -T. Under timeout in an interactive
    # setup shell, that terminal read can stop the probe with SIGTTIN even
    # when SQL has already succeeded. Argument-based queries need no input.
    for arg in "$@"; do
        case "$arg" in
            -e*|--execute|--execute=*)
                "${query[@]}" </dev/null
                return $?
                ;;
        esac
    done
    # Preserve stdin for SQL supplied through a pipe or heredoc.
    "${query[@]}"
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
    timeout -k 1 8 docker compose exec -T --user mysql mariadb sh -c '
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
    ' </dev/null 2>/dev/null
}

# Report a bounded category, never raw client output or environment values.
database_readiness_failure() {
    local status="$1" output="$2"
    case "$status" in
        124|137) printf 'TCP readiness command exceeded its time limit (exit %s); this does not measure SQL import progress' "$status" ;;
        *)
            if [[ "$output" == *'ERROR 1045 '* ]]; then
                printf 'TCP authentication was refused (MariaDB error 1045)'
            elif [[ "$output" == *'ERROR 2026 '* ]]; then
                printf 'TCP TLS negotiation failed (MariaDB error 2026)'
            elif [[ "$output" == *'ERROR 2002 '* || "$output" == *'ERROR 2003 '* ]]; then
                printf 'TCP connection is unavailable (MariaDB error 2002/2003)'
            else
                printf 'TCP readiness command failed (exit %s)' "$status"
            fi
            ;;
    esac
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
        printf '; SQL status unavailable (the query timed out or SQL is not accessible)'
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

# Docker metadata requests also need a deadline: the daemon may be slow even
# before a SQL connection is attempted. Do not hide a timeout as a missing DB.
# The deadline is for a daemon that no longer answers. A host busy with the
# import answers late at times, and one answer later than the three seconds
# allowed before stopped a setup during the replay or a recovery after the
# KVS initialization. DOCKER_QUERY_TIMEOUT_SECONDS changes it.
database_docker_query() {
    local limit="${DOCKER_QUERY_TIMEOUT_SECONDS:-30}"

    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=30
    timeout -k 1 "$limit" docker "$@"
}

# Keep the initial import error visible across the following startup messages.
# The client may echo the failed SQL between separator lines; omit that SQL
# and password-bearing log lines instead of exposing imported values.
database_failure_logs() {
    echo "  MariaDB initialization log (last 500 lines; SQL statements and password lines omitted):" >&2
    database_docker_query compose logs --no-color --tail 500 mariadb 2>&1 | awk '
        {
            line[NR]=substr($0, 1, 2000)
            message=$0
            sub(/^[^|]*[|][[:space:]]?/, "", message)
            separator[NR]=(message ~ /^[[:space:]]*--------------[[:space:]]*$/)
            secret[NR]=(tolower(message) ~ /password|passwd|mysql_pwd|mariadb_pwd|identified[[:space:]]+by/)
            blank[NR]=(message ~ /^[[:space:]]*$/)
            if (message ~ /^[[:space:]]*ERROR [0-9]+ /) {
                end=NR-1
                while (end>0 && blank[end]) end--
                if (separator[end]) {
                    start=end-1
                    while (start>0 && !separator[start]) start--
                    # If the tail starts inside SQL, omit through its closing
                    # separator without hiding the error that follows it.
                    if (start<1) start=1
                    for (i=start; i<=end; i++) omit[i]=1
                }
            }
        }
        END {
            for (i=1; i<=NR; i++) {
                if (omit[i]) {
                    if (!omit[i-1]) print "  [SQL statement omitted]"
                } else if (secret[i]) {
                    print "  [Password-bearing log line omitted]"
                } else print line[i]
            }
        }
    ' >&2
}

# A separate timer keeps status visible while foreground probes are blocked.
# It reports pending checks, never fabricated SQL progress or a stale sample.
database_progress_heartbeat() {
    local started="$1" activity="${2:-readiness/activity checks are still in progress}" timer='' stopping=no
    trap 'if [ -n "$timer" ]; then kill "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true; fi' EXIT
    # Finish assigning the timer PID before exiting if a signal arrives
    # between starting sleep and storing $!. Otherwise sleep could be orphaned.
    trap 'stopping=yes' INT TERM HUP
    while :; do
        [ "$stopping" != yes ] || exit 0
        command sleep 5 &
        timer=$!
        [ "$stopping" != yes ] || exit 0
        wait "$timer" || exit 0
        timer=''
        [ "$stopping" != yes ] || exit 0
        printf '  MariaDB: %ss elapsed; %s.\n' "$((SECONDS - started))" "$activity" >&2
    done
}

database_wait_timeout() {
    echo "ERROR: MariaDB not ready after $1 seconds (MARIADB_WAIT_SECONDS=$2)." >&2
    echo "The database container is left running. Inspect it with ./reconfigure.sh --import-status or docker compose logs mariadb." >&2
}

# Compose starts PHP-FPM, nginx and the other services on a healthy MariaDB
# only, and refuses at once while Docker reports it unhealthy. The health
# check fails for as long as the image replays an import (its temporary
# server has no health check account yet): a replay longer than the five
# retries leaves the container marked unhealthy until the first check after
# the real server opened TCP, up to one interval later.
database_wait_healthy() {
    local container="$1" budget="${DATABASE_HEALTH_WAIT_SECONDS:-120}" start=$SECONDS health shown=no

    while :; do
        health=$(database_docker_query inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null) ||
            health=unknown
        case "$health" in
            healthy | '') return 0 ;;
        esac
        if [ "$((SECONDS - start))" -ge "$budget" ]; then
            echo "ERROR: MariaDB answers SQL, but Docker still reports it $health after $((SECONDS - start)) seconds; the services that depend on it cannot start." >&2
            echo "Inspect its health check with: docker inspect --format '{{json .State.Health}}' $container" >&2
            return 1
        fi
        if [ "$shown" = no ]; then
            echo "  Docker reports MariaDB $health (its health check failed during the import); waiting for the next check before starting the services that depend on it."
            shown=yes
        fi
        sleep 1
    done
}

# Wait against wall time, not an assumed two seconds per iteration. A socket
# accepts SQL during the init replay, but readiness still requires TCP and
# setup separately verifies its unique final SQL completion marker.
database_wait_ready() (
    local budget="$1" once="${2:-no}" start=$SECONDS shown=-10 elapsed container state snapshot position heartbeat_pid=''
    local tcp_output tcp_status tcp_failure previous_failure=''
    [[ "$budget" =~ ^(0|[1-9][0-9]*)$ ]] || {
        echo "ERROR: MARIADB_WAIT_SECONDS must be a non-negative number of seconds (0 waits without a deadline)" >&2
        return 1
    }
    echo "  Checking MariaDB readiness; pending checks are reported every 5 seconds."
    trap 'if [ -n "$heartbeat_pid" ]; then kill "$heartbeat_pid" 2>/dev/null || true; wait "$heartbeat_pid" 2>/dev/null || true; fi' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    database_progress_heartbeat "$start" &
    heartbeat_pid=$!
    while :; do
        elapsed=$((SECONDS - start))
        if [ "$budget" -gt 0 ] && [ "$elapsed" -ge "$budget" ]; then
            database_wait_timeout "$elapsed" "$budget"
            return 1
        fi
        if ! container=$(database_docker_query compose ps -a -q mariadb 2>/dev/null); then
            echo "ERROR: Docker did not return the MariaDB container status; the container is left untouched." >&2
            return 1
        fi
        if [ -z "$container" ] || [[ "$container" == *$'\n'* ]]; then
            echo "ERROR: expected one MariaDB container for this Compose project." >&2
            return 1
        fi
        if ! state=$(database_docker_query inspect --format '{{.RestartCount}} {{.State.Status}}' "$container" 2>/dev/null); then
            echo "ERROR: Docker did not return the MariaDB running state; the container is left untouched." >&2
            return 1
        fi
        if [[ "$state" != "0 running" && "$state" != "0 created" ]]; then
            echo "ERROR: MariaDB stopped or restarted during initialization ($state)." >&2
            database_failure_logs || true
            return 1
        fi
        elapsed=$((SECONDS - start))
        if [ "$budget" -gt 0 ] && [ "$elapsed" -ge "$budget" ]; then
            database_wait_timeout "$elapsed" "$budget"
            return 1
        fi
        if tcp_output=$(database_root_query -h 127.0.0.1 --protocol=tcp -e 'SELECT 1' 2>&1); then
            elapsed=$((SECONDS - start))
            echo "  MariaDB accepts TCP connections after $elapsed seconds. This alone does not verify an import; setup checks its completion marker separately."
            [ "$once" = yes ] || database_wait_healthy "$container" || return 1
            return 0
        else
            tcp_status=$?
        fi
        tcp_failure=$(database_readiness_failure "$tcp_status" "$tcp_output")
        if [ "$tcp_failure" != "$previous_failure" ]; then
            printf '  MariaDB: %s.\n' "$tcp_failure"
            previous_failure=$tcp_failure
        fi
        elapsed=$((SECONDS - start))
        if [ "$budget" -gt 0 ] && [ "$elapsed" -ge "$budget" ]; then
            database_wait_timeout "$elapsed" "$budget"
            return 1
        fi
        if [ "$once" = yes ] || [ "$((elapsed - shown))" -ge 10 ]; then
            snapshot=$(database_import_snapshot) || true
            position=$(database_dump_position) || true
            elapsed=$((SECONDS - start))
            database_progress_line "$elapsed" "$snapshot" "$position"
            shown=$elapsed
        fi
        [ "$once" != yes ] || return 0
        sleep 2
    done
)

# Keep half the available budget for MariaDB overhead, PHP, search and the OS.
# Persist the result once; do not resize an existing database on each restart.
database_buffer_pool_for_host() {
    local available_mb="$1" size
    if [[ ! "$available_mb" =~ ^[0-9]+$ ]] || [ "$available_mb" -lt 256 ]; then
        echo "ERROR: at least 256 MiB of available memory is required to size MariaDB." >&2
        return 1
    fi
    size=$((available_mb / 2 / 128 * 128))
    [ "$size" -ge 128 ] || size=128
    printf '%sM\n' "$size"
}

# Redo occupies disk, not an equivalent RAM allocation. This bounded default
# reduces checkpoint pressure during imports without an unbounded disk cost.
database_redo_for_pool() {
    local pool_mb="$1" size
    size=$((pool_mb / 2 / 64 * 64))
    [ "$size" -ge 128 ] || size=128
    [ "$size" -le 2048 ] || size=2048
    printf '%sM\n' "$size"
}

# Bound the decimal input before arithmetic; shell expressions are not sizes.
database_size_mb() {
    local value="$1" size
    [[ "$value" =~ ^[1-9][0-9]{0,8}[MmGg]$ ]] || return 1
    size=${value%?}
    [[ "$value" != *[Gg] ]] || size=$((size * 1024))
    printf '%s\n' "$size"
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
database_memory_budget_mb() {
    local measure="${1:-available}" available path relative limit usage remaining root file key
    key=MemAvailable:
    [ "$measure" != capacity ] || key=MemTotal:
    available=$(awk -v key="$key" '$1==key { print int($2/1024) }' /proc/meminfo)
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
            if [ "$measure" != capacity ]; then
                if [ "$file" = memory.max ]; then
                    read -r usage < "$path/memory.current" || true
                else
                    read -r usage < "$path/memory.usage_in_bytes" || true
                fi
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

database_available_memory_mb() { database_memory_budget_mb available; }
database_capacity_memory_mb() { database_memory_budget_mb capacity; }

# An override can replace services.mariadb.command entirely. Check the rendered
# command before saving settings or replacing a database volume.
database_verify_compose_resources() {
    local config
    config=$(docker compose config) || return 1
    if ! printf '%s\n' "$config" | awk -v pool="$1" -v redo="$2" '
        /^  mariadb:$/ { db=1; next }
        db && /^  [^ ]/ { db=0 }
        db && /^    command:$/ { command=1; next }
        command && /^    [^ ]/ { command=0 }
        db && command {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/["\047]/, "", line)
            if (line == "--innodb-buffer-pool-size=" pool) p++
            if (line == "--innodb-log-file-size=" redo) r++
            # MariaDB also recognizes loose/maximum prefixes. A later such
            # argument must not silently override the validated memory budget.
            sub(/^--loose[-_]/, "--", line)
            sub(/^--maximum[-_]/, "--", line)
            if (line ~ /^--innodb[-_]buffer[-_]pool[-_]size([=[:space:]]|$)/) pc++
            if (line ~ /^--innodb[-_]log[-_]file[-_]size([=[:space:]]|$)/) rc++
        }
        END { exit !(p==1 && r==1 && pc==1 && rc==1) }
    '; then
        echo "ERROR: the rendered MariaDB command does not use the selected buffer pool and redo sizes. Update the MariaDB command override to use MARIADB_BUFFER_POOL_SIZE and MARIADB_REDO_LOG_SIZE." >&2
        return 1
    fi
}

database_configure_resources() {
    local available capacity limit pool redo pool_mb redo_mb reserve
    available=$(database_available_memory_mb)
    capacity=$(database_capacity_memory_mb)
    limit=$(database_compose_memory_limit) || return 1
    if [ "$limit" -gt 0 ] && [ "$((limit / 1048576))" -lt "$available" ]; then
        available=$((limit / 1048576))
    fi
    if [ "$limit" -gt 0 ] && [ "$((limit / 1048576))" -lt "$capacity" ]; then
        capacity=$((limit / 1048576))
    fi
    pool=${MARIADB_BUFFER_POOL_SIZE_REQUEST:-${MARIADB_BUFFER_POOL_SIZE:-auto}}
    if [ "$pool" = auto ]; then
        pool=$(database_buffer_pool_for_host "$available") || return 1
    fi
    if ! pool_mb=$(database_size_mb "$pool") || [ "$pool_mb" -lt 5 ]; then
        echo "ERROR: MARIADB_BUFFER_POOL_SIZE must be auto or a size of at least 5M, for example 512M or 2G." >&2
        return 1
    fi
    # Saved pools already consume memory and must not be compared with free
    # memory again. Validate them against capacity, including cgroup/Compose.
    reserve=$((pool_mb / 8))
    [ "$reserve" -ge 128 ] || reserve=128
    if [ "$((pool_mb + reserve))" -gt "$capacity" ]; then
        echo "ERROR: the $pool buffer pool needs at least $reserve MiB of additional headroom within the $capacity MiB host/container capacity. Lower MARIADB_BUFFER_POOL_SIZE." >&2
        return 1
    fi
    redo=${MARIADB_REDO_LOG_SIZE_REQUEST:-${MARIADB_REDO_LOG_SIZE:-auto}}
    if [ "$redo" = auto ]; then redo=$(database_redo_for_pool "$pool_mb"); fi
    if ! redo_mb=$(database_size_mb "$redo") || [ "$redo_mb" -lt 4 ] || [ "$redo_mb" -gt 524288 ]; then
        echo "ERROR: MARIADB_REDO_LOG_SIZE must be auto or a size from 4M to 512G." >&2
        return 1
    fi
    MARIADB_BUFFER_POOL_SIZE="$pool" MARIADB_REDO_LOG_SIZE="$redo" \
        database_verify_compose_resources "$pool" "$redo" || return 1
    # Both values and the effective command passed validation before any write.
    set_env_value MARIADB_BUFFER_POOL_SIZE "$pool" || return 1
    set_env_value MARIADB_REDO_LOG_SIZE "$redo" || return 1
    MARIADB_BUFFER_POOL_SIZE=$pool
    MARIADB_REDO_LOG_SIZE=$redo
    export MARIADB_BUFFER_POOL_SIZE MARIADB_REDO_LOG_SIZE
    echo "  MariaDB buffer pool: $pool; redo log: $redo on disk (saved in .env for initial startup and subsequent restarts)."
}

database_verify_running_resources() {
    local actual pool redo expected_pool expected_redo
    expected_pool=$(database_size_mb "$MARIADB_BUFFER_POOL_SIZE") || return 1
    expected_redo=$(database_size_mb "$MARIADB_REDO_LOG_SIZE") || return 1
    actual=$(database_root_query --batch --skip-column-names -e \
        'SELECT @@GLOBAL.innodb_buffer_pool_size, @@GLOBAL.innodb_log_file_size;') || return 1
    read -r pool redo <<< "$actual"
    if [ "$pool" != "$((expected_pool * 1048576))" ] || [ "$redo" != "$((expected_redo * 1048576))" ]; then
        echo "ERROR: running MariaDB buffer pool or redo size differs from the saved configuration. Inspect its command and custom configuration." >&2
        return 1
    fi
    echo "  MariaDB buffer pool and redo size verified through a new SQL connection."
}
