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

# Read setup.php from a file or "-" for a streamed archive member. The
# display path identifies the file the operator can edit. Never run site PHP.
kvs_read_tables_prefix() {
    local input=$1 setup=${2:-$1} policy=${3:-installed} saved=${4:-} assignment literal trivia prefix
    assignment="^[[:space:]]*\\\$config[[:blank:]]*\\[[[:space:]]*['\"]tables_prefix['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*"
    trivia='([[:space:]]|/[*][^*]*[*]+([^/*][^*]*[*]+)*/)*'
    literal="(['\"])([^'\"$]*)\\1${trivia}(;|[?]>)${trivia}((//|#).*)?$"
    # Mark each assignment, including an expression, so an earlier literal
    # cannot hide an ambiguous second assignment. Never evaluate site PHP.
    if ! prefix=$(sed -nE "
        /$assignment/!d
        s@${assignment}${literal}@value:\\2@
        t found
        s/.*/expression/
        :found
        p" "$input") ||
        [[ "$prefix" != value:* || "$prefix" == *$'\n'* ]]; then
        printf 'ERROR: expected one literal tables_prefix assignment in %s. Confirm the actual database prefix and write it there before initialization.\n' "$setup" >&2
        return 1
    fi
    prefix=${prefix#value:}
    if [[ ! "$prefix" =~ ^[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]{1,32}$ ]]; then
        if ! LC_ALL=C.UTF-8 expr + "$prefix" : '[[:alnum:]_]\{1,32\}$' >/dev/null; then
            printf 'ERROR: cannot use table prefix in %s. Confirm the actual database prefix.\n' "$setup" >&2
            return 1
        fi
        if [ "$policy" != installed ] && [ "$prefix" != "$saved" ]; then
            printf 'ERROR: a new table prefix in %s must contain only ASCII letters, digits and underscores.\n' "$setup" >&2
            return 1
        fi
        echo "WARNING: keeping non-ASCII TABLES_PREFIX '$prefix' only because this site already uses it. To migrate, rename the database tables and update tables_prefix in $setup and TABLES_PREFIX in .env together." >&2
    fi
    printf '%s\n' "$prefix"
}

kvs_read_archive_prefix() (
    set -o pipefail
    local archive=$1
    unzip -p "$archive" admin/include/setup.php |
        kvs_read_tables_prefix - "$archive:admin/include/setup.php" new
)
