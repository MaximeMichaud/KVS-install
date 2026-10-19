#!/bin/bash
# Runtime sizing for the shared web pool. This file is sourced by the PHP
# entrypoint; the optional filesystem root lets tests supply kernel fixtures.

fpm_memory_mb() {
    local root="${1:-}" memory limit path mount_root mount_path type relative membership file
    memory=$(awk '$1 == "MemTotal:" { printf "%.0f\n", int($2 / 1024) }' "$root/proc/meminfo") || return 1
    if [[ ! "$memory" =~ ^[1-9][0-9]{0,11}$ ]]; then
        echo "ERROR: cannot determine PHP-FPM memory capacity from /proc/meminfo" >&2
        return 1
    fi
    if [ ! -r "$root/proc/self/cgroup" ] || [ ! -r "$root/proc/self/mountinfo" ]; then
        echo "ERROR: cannot read PHP-FPM cgroup membership or mounts" >&2
        return 1
    fi

    # Map the process membership onto each visible memory hierarchy. Walking
    # its parents also handles a limit imposed on a systemd slice. Private
    # Docker cgroup namespaces normally expose the container at the root.
    while read -r mount_root mount_path type; do
        printf -v mount_root '%b' "$mount_root"
        printf -v mount_path '%b' "$mount_path"
        if [ "$type" = cgroup2 ]; then
            membership=$(awk -F: '$1 == "0" { print $3; exit }' "$root/proc/self/cgroup")
            file=memory.max
        else
            membership=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ { print $3; exit }' "$root/proc/self/cgroup")
            file=memory.limit_in_bytes
        fi
        [ -n "$membership" ] || continue
        case "$membership" in
            "$mount_root") relative='' ;;
            "$mount_root"/*) relative=${membership#"$mount_root"} ;;
            *)
                if [ "$mount_root" = / ]; then relative=$membership
                elif [ "$membership" = / ]; then relative=''
                else continue
                fi
                ;;
        esac
        mount_path="$root$mount_path"
        path="${mount_path%/}${relative%/}"
        while [[ "$path" = "$mount_path" || "$path" = "$mount_path/"* ]]; do
            if [ -r "$path/$file" ]; then
                read -r limit < "$path/$file" || return 1
                # max (v2), and the huge unlimited sentinel (v1), cannot
                # reduce host capacity. Bound input before shell arithmetic.
                if [[ "$limit" =~ ^[0-9]{1,18}$ ]]; then
                    limit=$((10#$limit / 1048576))
                    [ "$limit" -ge "$memory" ] || memory=$limit
                fi
            fi
            [ "$path" != "$mount_path" ] || break
            path=${path%/*}
        done
    done < <(awk '
        {
            for (i=7; i<=NF; i++) if ($i == "-") {
                if ($(i+1) == "cgroup2" ||
                    ($(i+1) == "cgroup" && $(i+3) ~ /(^|,)memory(,|$)/))
                    print $4, $5, $(i+1)
                break
            }
        }
    ' "$root/proc/self/mountinfo")
    [ "$memory" -gt 0 ] || {
        echo "ERROR: PHP-FPM memory capacity is below 1 MiB" >&2
        return 1
    }
    printf '%s\n' "$memory"
}

fpm_positive_integer() {
    if [[ ! "$2" =~ ^[1-9][0-9]{0,5}$ ]]; then
        echo "ERROR: $1 must be a positive decimal integer (at most 999999)" >&2
        return 1
    fi
}

configure_php_fpm() {
    local root="${1:-}" capacity=manual percent="${PHP_FPM_MEMORY_PERCENT:-25}"
    local process_mb="${PHP_FPM_PROCESS_MEMORY_MB:-64}" maximum start minimum spare
    local name value output temporary
    maximum=${PHP_FPM_MAX_CHILDREN:-auto}
    start=${PHP_FPM_START_SERVERS:-auto}
    minimum=${PHP_FPM_MIN_SPARE_SERVERS:-auto}
    spare=${PHP_FPM_MAX_SPARE_SERVERS:-auto}

    fpm_positive_integer PHP_FPM_MEMORY_PERCENT "$percent" || return 1
    [ "$percent" -le 100 ] || {
        echo "ERROR: PHP_FPM_MEMORY_PERCENT must be between 1 and 100" >&2
        return 1
    }
    fpm_positive_integer PHP_FPM_PROCESS_MEMORY_MB "$process_mb" || return 1
    for name in PHP_FPM_MAX_CHILDREN PHP_FPM_START_SERVERS PHP_FPM_MIN_SPARE_SERVERS PHP_FPM_MAX_SPARE_SERVERS; do
        value=${!name:-auto}
        [ "$value" = auto ] || fpm_positive_integer "$name" "$value" || return 1
    done

    if [ "$maximum" = auto ]; then
        capacity=$(fpm_memory_mb "$root") || return 1
        maximum=$((capacity * percent / 100 / process_mb))
        [ "$maximum" -ge 1 ] || maximum=1
    fi
    if [ "$spare" = auto ]; then
        spare=$((maximum / 2))
        [ "$spare" -ge 1 ] || spare=1
        if [ "$minimum" != auto ] && [ "$spare" -lt "$minimum" ]; then spare=$minimum; fi
        if [ "$start" != auto ] && [ "$spare" -lt "$start" ]; then spare=$start; fi
    fi
    if [ "$minimum" = auto ]; then
        minimum=$((maximum / 8))
        [ "$minimum" -ge 1 ] || minimum=1
        [ "$minimum" -le "$spare" ] || minimum=$spare
        if [ "$start" != auto ] && [ "$minimum" -gt "$start" ]; then minimum=$start; fi
    fi
    if [ "$start" = auto ]; then
        start=$((maximum / 4))
        [ "$start" -ge "$minimum" ] || start=$minimum
        [ "$start" -le "$spare" ] || start=$spare
    fi
    if ! (( minimum <= start && start <= spare && spare <= maximum )); then
        echo "ERROR: PHP-FPM requires min_spare_servers <= start_servers <= max_spare_servers <= max_children (got $minimum <= $start <= $spare <= $maximum)" >&2
        return 1
    fi

    # Leave the image's pool and the operator's PHP settings intact. This
    # late pool file replaces all four values together, including on restart.
    output="$root/usr/local/etc/php-fpm.d/zz-kvs-pool.conf"
    temporary=$(mktemp "${output}.XXXXXX") || return 1
    if ! printf '%s\n' \
        '; Generated at startup by fpm-config.sh. Configure PHP_FPM_* in Compose.' \
        '[www]' 'pm = dynamic' "pm.max_children = $maximum" "pm.start_servers = $start" \
        "pm.min_spare_servers = $minimum" "pm.max_spare_servers = $spare" > "$temporary" ||
        ! chmod 0644 "$temporary" || ! mv -f "$temporary" "$output"; then
        rm -f "$temporary"
        return 1
    fi
    echo "PHP-FPM: memory_mb=${capacity}, budget=${percent}%, estimate=${process_mb} MiB/worker; max_children=$maximum start_servers=$start min_spare_servers=$minimum max_spare_servers=$spare"
}
