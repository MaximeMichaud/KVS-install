#!/bin/bash
# Read legacy KVS CLI packages without running their application PHP.
_KVS_IMPORT_CLI_HELPER="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)/import-cli-package.py"

# Read import_archive_list's type/size/path file; Python validates the package.
import_cli_archive_is_package() {
    local listing=${1:-} kind _size member metadata=no database=no full_site=no
    [ -f "$listing" ] && [ -r "$listing" ] || return 1
    while IFS=$'\t' read -r kind _size member; do
        [ "$kind" = f ] || continue
        while [[ "$member" == ./* ]]; do member=${member#./}; done
        case "$member" in
            metadata.json) metadata=yes ;;
            database.sql.zst) database=yes ;;
            admin/include/setup.php|www/admin/include/setup.php) full_site=yes ;;
        esac
    done < "$listing"
    [ "$metadata" = yes ] && [ "$database" = yes ] && [ "$full_site" = no ]
}

# Require one operator-provided application ZIP; version.php decides compatibility.
import_cli_application_archive() {
    local directory=${1:-} member
    local -a matches=()
    if [ ! -d "$directory" ]; then
        printf 'ERROR: the application archive directory is unavailable.\n' >&2
        return 1
    fi
    for member in "$directory"/KVS_*.zip; do
        [ -e "$member" ] || [ -L "$member" ] || continue
        matches+=("$member")
    done
    if [ "${#matches[@]}" -ne 1 ]; then
        printf 'ERROR: exactly one KVS_*.zip application archive is required.\n' >&2
        return 1
    fi
    member=${matches[0]}
    if [ ! -f "$member" ] || [ ! -r "$member" ] || [[ "$member" =~ [[:cntrl:]] ]]; then
        printf 'ERROR: the application archive must be a readable file with a representable path.\n' >&2
        return 1
    fi
    printf '%s\n' "$member"
}

_import_cli_run() {
    local dependency
    for dependency in python3 zstd; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            printf 'ERROR: legacy CLI packages require %s; no dependency was installed.\n' "$dependency" >&2
            return 1
        fi
    done
    python3 "$_KVS_IMPORT_CLI_HELPER" "$@"
}

# version<TAB>source_path<TAB>prefix<TAB>content yes/no<TAB>actual MB<TAB>ionCube
import_cli_inspect() {
    _import_cli_run inspect "$@"
}

# Prepare only www/ and database.sql.zst in an existing empty, private stage.
import_cli_prepare() {
    _import_cli_run prepare "$@"
}
