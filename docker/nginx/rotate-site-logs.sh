#!/bin/sh
# Rotates the site logs Nginx writes to /var/log/nginx, <domain>.access.log
# and <domain>.error.log, from inside the container: neither the host's
# logrotate nor the host path of the volume is involved, and the single-site
# stack and every multi-site site run it from the same image. The entrypoint
# starts it in the background; --once runs a single check.
#
# A log that reaches NGINX_LOG_MAX_SIZE is renamed to <name>.1 and the Nginx
# master is told to reopen its logs (SIGUSR1, what nginx -s reopen sends).
# Until a worker reopens, it keeps writing to the renamed file, so no line is
# lost: <name>.1 is compressed to <name>.1.gz only once Nginx has created
# <name> again and nothing has written to <name>.1 for a whole check
# interval. Older generations move up to <name>.2.gz and so on, and
# NGINX_LOG_KEEP of them are kept.
#
# The image links access.log and error.log to the container output, which
# Docker caps; no symbolic link is rotated, compressed or followed, and one
# lying where a generation or a temporary copy goes is replaced like a file.
# A per-log .rotation-state file records the retention limit and the next
# step before any generation moves. Its .1 stays uncompressed until the
# single entrypoint loop finishes the rotation, so a container stop never
# makes a later check repeat completed shifts or purge a generation that
# just moved into its last slot.

# The tests point these at a scratch directory and a stand-in master.
log_dir=${NGINX_LOG_DIR:-/var/log/nginx}
pid_file=${NGINX_PID_FILE:-/run/nginx.pid}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

# BusyBox mv -T refuses even a link to a directory. Remove that link first;
# -T still prevents a real directory from receiving the source as a child.
rename_log_file() {
    if [ -L "$2" ]; then
        rm -f -- "$2" || return 1
    fi
    mv -fT -- "$1" "$2"
}

rotation_pending() {
    [ -e "$1.rotation-state" ] || [ -L "$1.rotation-state" ]
}

# Prints a whole number of at most nine digits without its leading zeros,
# which shell arithmetic would read as octal.
whole_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    whole_number_value=$1
    while [ "${#whole_number_value}" -gt 1 ] &&
        [ "${whole_number_value#0}" != "$whole_number_value" ]; do
        whole_number_value=${whole_number_value#0}
    done
    [ "${#whole_number_value}" -le 9 ] || return 1
    printf '%s\n' "$whole_number_value"
}

# Prints a size in bytes, given in bytes or with a k, m or g suffix in either
# case, in powers of 1024. Docker's max-size counts in powers of 1000 and also
# takes forms such as 100MB or 1.5g, which are refused here.
size_in_bytes() {
    case "$1" in
        *[kK]) size_unit=1024 ;;
        *[mM]) size_unit=1048576 ;;
        *[gG]) size_unit=1073741824 ;;
        *)
            whole_number "$1"
            return
            ;;
    esac
    size_count=$(whole_number "${1%?}") || return 1
    printf '%s\n' "$((size_count * size_unit))"
}

max_size=${NGINX_LOG_MAX_SIZE:-100M}
if ! max_bytes=$(size_in_bytes "$max_size"); then
    warn "NGINX_LOG_MAX_SIZE=${max_size} is not a size such as 100M; using 100M"
    max_bytes=104857600
fi
if [ "$max_bytes" -eq 0 ]; then
    printf 'Nginx site log rotation is off (NGINX_LOG_MAX_SIZE=%s)\n' "$max_size"
    exit 0
fi
if ! keep=$(whole_number "${NGINX_LOG_KEEP:-20}") || [ "$keep" -lt 1 ] || [ "$keep" -gt 999 ]; then
    warn "NGINX_LOG_KEEP=${NGINX_LOG_KEEP:-} is not a number of generations from 1 to 999; keeping 20"
    keep=20
fi
if ! interval=$(whole_number "${NGINX_LOG_CHECK_INTERVAL:-60}") || [ "$interval" -lt 1 ]; then
    warn "NGINX_LOG_CHECK_INTERVAL=${NGINX_LOG_CHECK_INTERVAL:-} is not a number of seconds; checking every 60"
    interval=60
fi

# Finds the Nginx master in its PID file. A PID file left by an earlier run of
# the container names whatever process holds that number now, such as the
# shell still starting Nginx, which SIGUSR1 could stop. Only a process titled
# as the Nginx master qualifies; the answer holds for the rest of the check.
nginx_master_ready() {
    [ -z "$master_pid" ] || return 0
    master_candidate=''
    if [ -r "$pid_file" ]; then
        read -r master_candidate < "$pid_file" || :
    fi
    case "$master_candidate" in
        ''|*[!0-9]*) master_title='' ;;
        *) master_title=$(tr '\0' ' ' 2>/dev/null < "/proc/${master_candidate}/cmdline") || master_title='' ;;
    esac
    case "$master_title" in
        'nginx: master process'*)
            master_pid=$master_candidate
            master_missing_reported=''
            return 0
            ;;
    esac
    if [ -z "$master_missing_reported" ]; then
        warn "no Nginx master process in ${pid_file}; the site logs rotate once Nginx runs"
        master_missing_reported=yes
    fi
    return 1
}

# Compresses each <name>.1 once Nginx has reopened <name> and nothing has
# written to <name>.1 for a whole check interval: every worker has reopened
# its logs by then. Nginx creates <name> again as it reopens it, so while no
# file <name> exists Nginx may still write to <name>.1, however long it has
# been idle: it is kept, and Nginx is asked again.
compress_rotated_logs() {
    for rotated_log in "$log_dir"/*.access.log.1 "$log_dir"/*.error.log.1; do
        [ -f "$rotated_log" ] && [ ! -L "$rotated_log" ] || continue
        # .1 also proves that a pending rotation already renamed its active
        # log. Keep that evidence until the rotation has finished.
        rotation_pending "${rotated_log%.1}" && continue
        if [ ! -f "${rotated_log%.1}" ]; then
            reopen=yes
            unopened_log=${rotated_log%.1}
            unopened_logs="${unopened_logs} ${unopened_log##*/}"
            continue
        fi
        last_write=$(stat -c %Y -- "$rotated_log" 2>/dev/null) || continue
        [ $((now - last_write)) -ge "$interval" ] || continue
        rm -f -- "${rotated_log}.gz.tmp"
        if nice -n 19 gzip -c -- "$rotated_log" > "${rotated_log}.gz.tmp" &&
            touch -r "$rotated_log" -- "${rotated_log}.gz.tmp" &&
            rename_log_file "${rotated_log}.gz.tmp" "${rotated_log}.gz"; then
            rm -f -- "$rotated_log"
        else
            rm -f -- "${rotated_log}.gz.tmp"
            warn "could not compress ${rotated_log}; the next check tries again"
        fi
    done
}

# Removes regular generations at or above the supplied bound. Links are
# neither followed nor removed, including ones left by an older limit.
prune_generations() {
    for generation_file in "$1".*.gz; do
        [ -f "$generation_file" ] && [ ! -L "$generation_file" ] || continue
        generation=${generation_file#"$1".}
        generation=${generation%.gz}
        case "$generation" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$generation" -ge "$2" ]; then
            rm -f -- "$generation_file" || return 1
        fi
    done
}

# The state is two numbers: the KEEP at the start of this rotation and the
# next step. KEEP means purge, KEEP-1 through 1 shift that source, and 0
# renames the active log. Publish each update atomically before proceeding.
save_rotation_state() {
    if rm -f -- "${rotation_state}.tmp" &&
        printf '%s %s\n' "$rotation_keep" "$1" > "${rotation_state}.tmp" &&
        rename_log_file "${rotation_state}.tmp" "$rotation_state"; then
        rotation_step=$1
        return 0
    fi
    rm -f -- "${rotation_state}.tmp"
    warn "could not save ${rotation_state}; the next check tries again"
    return 1
}

load_rotation_state() {
    [ -f "$rotation_state" ] && [ ! -L "$rotation_state" ] &&
        {
            read -r saved_keep saved_step saved_extra && [ -z "$saved_extra" ] &&
                ! IFS= read -r saved_trailing && [ -z "$saved_trailing" ]
        } < "$rotation_state" &&
        rotation_keep=$(whole_number "$saved_keep") &&
        rotation_step=$(whole_number "$saved_step") &&
        [ "$rotation_keep" -ge 1 ] && [ "$rotation_keep" -le 999 ] &&
        [ "$rotation_step" -le "$rotation_keep" ]
}

resume_rotation() {
    rotation_log=$1
    rotation_state="${rotation_log}.rotation-state"
    if ! load_rotation_state; then
        warn "invalid rotation state ${rotation_state}; leaving its logs unchanged"
        return 1
    fi
    if [ "$rotation_step" -eq "$rotation_keep" ]; then
        prune_generations "$rotation_log" "$rotation_keep" || return 1
        save_rotation_state "$((rotation_keep - 1))" || return 1
    fi
    while [ "$rotation_step" -ge 1 ]; do
        # If the process stopped after mv but before saving the next step,
        # the source is already absent. Higher generations must not move again.
        if [ -f "${rotation_log}.${rotation_step}.gz" ] && [ ! -L "${rotation_log}.${rotation_step}.gz" ]; then
            rename_log_file "${rotation_log}.${rotation_step}.gz" \
                "${rotation_log}.$((rotation_step + 1)).gz" || return 1
        fi
        save_rotation_state "$((rotation_step - 1))" || return 1
    done
    if [ -L "${rotation_log}.1" ] || { [ -e "${rotation_log}.1" ] && [ ! -f "${rotation_log}.1" ]; }; then
        warn "${rotation_log}.1 blocks the pending rotation; the next check tries again"
        return 1
    fi
    if [ ! -f "${rotation_log}.1" ]; then
        if [ ! -f "$rotation_log" ] || [ -L "$rotation_log" ]; then
            warn "${rotation_log} is not a regular log; the pending rotation waits for it"
            return 1
        fi
        rename_log_file "$rotation_log" "${rotation_log}.1" || return 1
    fi
    # A .1 already present means the final rename completed before a stop.
    # Do not overwrite it with the new active log Nginx may have opened.
    reopen=yes
    if [ "$keep" -lt "$rotation_keep" ]; then
        prune_generations "$rotation_log" "$((keep + 1))" || return 1
    fi
    rm -f -- "$rotation_state" || return 1
    rotated_logs="${rotated_logs} ${rotation_log##*/}"
}

rotate_site_logs() {
    now=$(date +%s)
    master_pid=''
    reopen=''
    rotated_logs=''
    unopened_logs=''
    compress_rotated_logs
    # A restart may have opened an empty active log, or none yet. Resume
    # from the state files themselves. Compression above skips their .1.
    for pending_state in "$log_dir"/*.access.log.rotation-state "$log_dir"/*.error.log.rotation-state; do
        [ -e "$pending_state" ] || [ -L "$pending_state" ] || continue
        nginx_master_ready || break
        resume_rotation "${pending_state%.rotation-state}" || continue
    done
    for site_log in "$log_dir"/*.access.log "$log_dir"/*.error.log; do
        [ -f "$site_log" ] && [ ! -L "$site_log" ] || continue
        rotation_pending "$site_log" && continue
        size=$(stat -c %s -- "$site_log" 2>/dev/null) || continue
        [ "$size" -ge "$max_bytes" ] || continue
        if [ -L "${site_log}.1" ]; then
            warn "${site_log}.1 is a symbolic link; ${site_log##*/} rotates once it is gone"
            continue
        fi
        # Its previous generation is not compressed yet: a later check
        # rotates it.
        [ ! -e "${site_log}.1" ] || continue
        nginx_master_ready || return 0
        rotation_state="${site_log}.rotation-state"
        rotation_keep=$keep
        save_rotation_state "$rotation_keep" || continue
        resume_rotation "$site_log" || continue
    done
    [ -n "$reopen" ] || return 0
    nginx_master_ready || return 0
    if ! kill -s USR1 "$master_pid" 2>/dev/null; then
        warn "could not ask the Nginx master (PID ${master_pid}) to reopen its logs"
        return 0
    fi
    if [ -n "$rotated_logs" ]; then
        printf 'Rotated the Nginx site logs:%s\n' "$rotated_logs"
    fi
    if [ -n "$unopened_logs" ]; then
        warn "Nginx did not reopen${unopened_logs}; asked it again, and the .1 of each stays uncompressed until it does"
    fi
}

master_missing_reported=''
case "${1:-}" in
    --once)
        rotate_site_logs
        exit 0
        ;;
    '')
        ;;
    *)
        printf 'Usage: %s [--once]\n' "$0" >&2
        exit 2
        ;;
esac

while sleep "$interval"; do
    rotate_site_logs
done
