#!/bin/bash
# Select a regular archive directly in the shared directory. A lone archive
# may have been renamed or licensed for a development site's parent domain.
select_kvs_archive() {
    local dir=$1 domain=$2 path
    local -a archives=() matches=()
    for path in "$dir"/KVS_*.zip; do
        if [ -L "$path" ]; then
            printf 'Archive %s is a symbolic link. Place the regular archive at this path before continuing.\n' "$path" >&2
            return 1
        fi
        [ -f "$path" ] || continue
        archives+=("$path")
        if [[ ${path,,} == *"[${domain,,}].zip" ]]; then
            matches+=("$path")
        fi
    done
    case ${#archives[@]} in
        0) return 0 ;;
        1) printf '%s\n' "${archives[0]}"; return ;;
    esac
    if [ "${#matches[@]}" -eq 1 ]; then
        printf '%s\n' "${matches[0]}"
        return
    fi
    printf '%s/ holds %s KVS archives; expected exactly one archive ending in [%s].zip:\n' \
        "$dir" "${#archives[@]}" "$domain" >&2
    printf '  %s\n' "${archives[@]}" >&2
    return 1
}
