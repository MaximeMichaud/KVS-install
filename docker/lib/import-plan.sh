#!/bin/bash
# Read-only migration planning, reached before setup logging or host changes.

import_plan_archive_tool() {
    local file="$1" kind tool compressor

    kind=$(import_archive_kind "$file") || {
        echo 'ERROR: unsupported import archive format' >&2
        return 1
    }
    case "$kind" in
        zip) tool=unzip ;;
        tar) tool=tar ;;
        7z)
            tool=''
            for compressor in 7zz 7z 7za; do
                if command -v "$compressor" >/dev/null 2>&1; then tool=$compressor; break; fi
            done
            ;;
    esac
    if [ -z "$tool" ] || ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: an installed $kind reader is required for a dry run; no packages were installed" >&2
        return 1
    fi
    compressor=$(import_compressor_for "$file")
    if [ -n "$compressor" ] && ! command -v "$compressor" >/dev/null 2>&1; then
        echo "ERROR: $compressor is required to inspect this archive; no packages were installed" >&2
        return 1
    fi
    printf '%s\n' "$tool"
}

# The temporary directory holds only inspected metadata. No source files,
# setup configuration, target directories or services are modified.
import_plan() (
    set -o pipefail
    local dev_mode="$1" source='' sources=0 site_info='' dump_info=''
    local version='not inspected' prefix='not inspected' tables='not inspected'
    local source_path='' archive_tool analysis temporary='' ssl db_choice domain
    local files_only=no reuse_dump=no flag value
    local legacy_info='' application_archive

    domain=${DOMAIN:-}
    domain=${domain,,}
    if ! validate_domain "$domain"; then
        echo 'ERROR: DOMAIN must be a valid target domain for an import dry run' >&2
        return 1
    fi
    ssl=${SSL_CHOICE:-1}
    [ "$dev_mode" != true ] || ssl=3
    case "$ssl" in
        1) ssl="Let's Encrypt" ;;
        2) ssl=ZeroSSL ;;
        3) ssl=self-signed ;;
        *) echo 'ERROR: SSL_CHOICE must be 1, 2 or 3' >&2; return 1 ;;
    esac
    db_choice=${DB_CHOICE:-1}
    if [[ ! "$db_choice" =~ ^[1-9][0-9]?$ ]] || [ "$db_choice" -gt "${#MARIADB_LTS_VERSIONS[@]}" ]; then
        echo "ERROR: DB_CHOICE must be a menu index from 1 to ${#MARIADB_LTS_VERSIONS[@]}" >&2
        return 1
    fi
    if [ -n "${IMPORT_ARCHIVE:-}" ]; then source=archive; sources=$((sources + 1)); fi
    if [ -n "${IMPORT_SITE_DIR:-}${IMPORT_DB_DUMP:-}" ]; then
        if [ -z "${IMPORT_SITE_DIR:-}" ] || [ -z "${IMPORT_DB_DUMP:-}" ]; then
            echo 'ERROR: IMPORT_SITE_DIR and IMPORT_DB_DUMP must be set together' >&2
            return 1
        fi
        source=directory
        sources=$((sources + 1))
    fi
    if [ -n "${IMPORT_REMOTE_HOST:-}" ]; then source=remote; sources=$((sources + 1)); fi
    if [ "$sources" -ne 1 ]; then
        echo 'ERROR: select exactly one import source: archive, directory with dump, or SSH host' >&2
        return 1
    fi
    for flag in IMPORT_FILES_ONLY IMPORT_REUSE_DUMP; do
        case "${!flag:-}" in
            y|Y|yes|YES|true) value=yes ;;
            ''|n|N|no|NO|false) value=no ;;
            *) echo "ERROR: $flag must be yes or no" >&2; return 1 ;;
        esac
        case "$flag" in
            IMPORT_FILES_ONLY) files_only=$value ;;
            IMPORT_REUSE_DUMP) reuse_dump=$value ;;
        esac
    done
    if [ "$source" != remote ] && { [ "$files_only" = yes ] || [ -n "${IMPORT_REUSE_SITE_DIR:-}" ]; }; then
        echo 'ERROR: IMPORT_FILES_ONLY and IMPORT_REUSE_SITE_DIR require IMPORT_REMOTE_HOST' >&2
        return 1
    fi
    if [ "$files_only" = yes ] && [ "$reuse_dump" = yes ]; then
        echo 'ERROR: IMPORT_FILES_ONLY receives no dump; it cannot be combined with IMPORT_REUSE_DUMP' >&2
        return 1
    fi

    case "$source" in
        directory)
            site_info=$(import_validate_site "$IMPORT_SITE_DIR") || return 1
            source_path=$IMPORT_SITE_DIR
            prefix=$(import_field "$site_info" 3)
            dump_info=$(import_inspect_dump "$IMPORT_DB_DUMP" "$prefix") || return 1
            tables=$(import_field "$dump_info" 1)
            if [[ ! "$tables" =~ ^[0-9]+$ ]] || [ "$tables" -lt 1 ]; then
                echo "ERROR: the dump holds no CREATE TABLE for the $prefix tables" >&2
                return 1
            fi
            case $(import_field "$dump_info" 5) in
                *,*) echo 'ERROR: the dump contains several databases' >&2; return 1 ;;
            esac
            if [ "$(import_field "$dump_info" 4)" != yes ]; then
                echo 'WARNING: the dump has no completion line; confirm it is complete before import' >&2
            fi
            ;;
        archive)
            if [ ! -f "$IMPORT_ARCHIVE" ] || [ ! -r "$IMPORT_ARCHIVE" ]; then
                echo 'ERROR: IMPORT_ARCHIVE must be a readable file' >&2
                return 1
            fi
            archive_tool=$(import_plan_archive_tool "$IMPORT_ARCHIVE") || return 1
            temporary=$(mktemp -d "${TMPDIR:-/tmp}/kvs-import-plan.XXXXXX") || return 1
            trap 'rm -rf -- "$temporary"' EXIT
            import_archive_list "$IMPORT_ARCHIVE" "$archive_tool" > "$temporary/list" || return 1
            if import_cli_archive_is_package "$temporary/list"; then
                application_archive=$(import_cli_application_archive "$(pwd)/kvs-archive") || return 1
                legacy_info=$(import_cli_inspect "$IMPORT_ARCHIVE" "$application_archive") || return 1
                version=$(import_field "$legacy_info" 1)
                prefix=$(import_field "$legacy_info" 3)
            else
                analysis=$(import_archive_analyze "$temporary/list") || return 1
                import_archive_peek "$IMPORT_ARCHIVE" "$archive_tool" "$(import_field "$analysis" 1)" "$temporary/peek" || return 1
                site_info=$(import_validate_site "$temporary/peek") || return 1
            fi
            source_path=$IMPORT_ARCHIVE
            ;;
        remote)
            if [[ ! "$IMPORT_REMOTE_HOST" =~ ^[A-Za-z0-9_.:-]+$ ]] ||
                [[ ! "${IMPORT_REMOTE_USER:-root}" =~ ^[A-Za-z0-9._-]+$ ]] ||
                [[ ! "${IMPORT_REMOTE_PORT:-22}" =~ ^[1-9][0-9]{0,4}$ ]] ||
                [ "${IMPORT_REMOTE_PORT:-22}" -gt 65535 ]; then
                echo 'ERROR: invalid SSH host, user or port' >&2
                return 1
            fi
            if [ -n "${IMPORT_REMOTE_DIR:-}" ]; then
                import_remote_path_check "$IMPORT_REMOTE_DIR" || return 1
            fi
            if [ -n "${IMPORT_SSH_KEY:-}" ] && [ ! -r "$IMPORT_SSH_KEY" ]; then
                echo 'ERROR: IMPORT_SSH_KEY is not readable' >&2
                return 1
            fi
            source_path="ssh://${IMPORT_REMOTE_USER:-root}@$IMPORT_REMOTE_HOST:${IMPORT_REMOTE_PORT:-22}${IMPORT_REMOTE_DIR:-/}"
            ;;
    esac
    if [ -n "$site_info" ]; then
        version=$(import_field "$site_info" 1)
        prefix=$(import_field "$site_info" 3)
    fi

    printf '%s\n' 'Migration plan (dry run)' "Source type: $source" "Source: $source_path" \
        "KVS version: $version" "Table prefix: $prefix" "Database tables: $tables" \
        "Destination: /var/www/$domain" "MariaDB: ${MARIADB_LTS_VERSIONS[$((db_choice - 1))]} (menu choice $db_choice)" \
        "SSL: $ssl"
    if [ "$source" = remote ]; then
        echo 'SSH preview only: no connection was opened. Source version, credentials and data remain unverified.'
    elif [ "$source" = archive ]; then
        echo 'Archive metadata inspected. The database payload will be validated during import.'
    fi
    if [ -n "$legacy_info" ]; then
        echo "Legacy KVS CLI data package: reconstruct with $application_archive; custom application files and settings are not included."
    fi
    if [ "$files_only" = yes ]; then
        echo 'Database action: unchanged (files-only pass)'
        echo 'Planned steps: validate source and destination markers, update site files; leave database and services unchanged.'
    else
        if [ "$source" = remote ] && [ "$reuse_dump" = yes ]; then
            echo 'Database action: import the previously received dump after source checks'
        else
            echo 'Database action: import the selected source database'
        fi
        echo 'Planned steps: validate source, stage site files and database, configure Docker, start services, verify database completion.'
    fi
    if [ -n "${IMPORT_REUSE_SITE_DIR:-}" ]; then
        printf 'Site files: take over %s after source-marker and destination checks\n' "$IMPORT_REUSE_SITE_DIR"
    fi
    echo 'Existing installation and database replacement checks still apply during setup.'
    if [ "$dev_mode" = true ] && [ "$files_only" != yes ]; then
        echo 'Development mode: setup may recreate existing project volumes after its normal checks.'
    fi
    echo 'No installation changes were made. This plan does not prove that a full migration will succeed.'
)
