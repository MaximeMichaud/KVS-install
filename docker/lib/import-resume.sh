#!/bin/bash
# Recover the proof of completion from an already staged import. These
# helpers never replay SQL, change the database or execute an init hook.
# shellcheck disable=SC2034  # Discovery returns globals to setup.sh.

import_resume_identifiers() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,64}$ && "$1" != . && "$1" != .. && "$2" =~ ^[A-Za-z0-9_]{1,32}$ ]] || {
        echo 'ERROR: the saved database name or table prefix is invalid; import recovery cannot continue.' >&2
        return 1
    }
}

# import_resume_discover <init directory> <saved database> <saved prefix>
# Run directly, not in a command substitution: the returned globals describe
# the exact staged artifact. Compressed SQL is not opened during discovery.
import_resume_discover() {
    local directory="$1" database="$2" prefix="$3" file manifest
    local -a candidates=()
    import_resume_identifiers "$database" "$prefix" || return 1
    if [ ! -d "$directory" ] || [ -L "$directory" ]; then
        echo 'ERROR: the original MariaDB init directory is missing or is a symbolic link.' >&2
        return 1
    fi
    for file in "$directory"/*kvs-import*; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        case "$file" in
            *kvs-import.sql|*kvs-import.sql.gz|*kvs-import.sql.xz|*kvs-import.sql.zst|*kvs-import-native.sh)
                if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
                    echo 'ERROR: the staged import must be a readable regular file, not a symbolic link.' >&2
                    return 1
                fi
                candidates+=("$file")
                ;;
            *kvs-import-native)
                if [ ! -d "$file" ] || [ -L "$file" ] || [ ! -f "$file.sh" ]; then
                    echo 'ERROR: the native import staging directory or its init hook is incomplete.' >&2
                    return 1
                fi
                ;;
        esac
    done
    if [ "${#candidates[@]}" -ne 1 ]; then
        echo 'ERROR: recovery requires exactly one original staged database import; none or multiple were found.' >&2
        return 1
    fi
    IMPORT_STAGED_DUMP=${candidates[0]}
    IMPORT_DB_DUMP=$IMPORT_STAGED_DUMP
    IMPORT_NATIVE_STAGE=''
    IMPORT_DUMP_TABLES=''
    IMPORT_RESUME_DOMAIN=$database
    IMPORT_RESUME_PREFIX=$prefix
    file=$IMPORT_STAGED_DUMP
    case "$file" in
        *kvs-import-native.sh)
            IMPORT_NATIVE_STAGE=${file%.sh}
            manifest="$IMPORT_NATIVE_STAGE/kvs-native-export.manifest"
            if [ ! -d "$IMPORT_NATIVE_STAGE" ] || [ -L "$IMPORT_NATIVE_STAGE" ] ||
                [ ! -d "$IMPORT_NATIVE_STAGE/data/$database" ] || [ -L "$IMPORT_NATIVE_STAGE/data" ] ||
                [ -L "$IMPORT_NATIVE_STAGE/data/$database" ] || [ ! -f "$manifest" ] || [ -L "$manifest" ] ||
                [ ! -f "$IMPORT_NATIVE_STAGE/finalize.sql" ] || [ -L "$IMPORT_NATIVE_STAGE/finalize.sql" ]; then
                echo 'ERROR: the native import files do not match the saved destination database.' >&2
                return 1
            fi
            native_import_metadata "$manifest" "$prefix" || return 1
            IMPORT_DUMP_TABLES=$(import_kv "$manifest" tables)
            file="$IMPORT_NATIVE_STAGE/finalize.sql"
            ;;
    esac
    IMPORT_RESUME_STAGED_IDENTITY=$(stat -Lc '%d:%i:%s:%y:%z' -- "$file") || return 1
}

# Accept only the exact final statement emitted by import_prepare_dump or
# native_import_prepare, including the expected options table and token shape.
# The token pattern is spelled out: the mawk of Debian 12 (1.3.4 20200120)
# has no interval expressions and reads [0-9]{8} as a digit then "{8}".
import_resume_parse_marker() {
    awk -v prefix="$1" '
        /[^[:space:]]/ { last=$0 }
        END {
            sub(/\r$/, "", last)
            n=split(last, part, "\047")
            if (n != 5 || part[1] != "INSERT INTO `" prefix "options` (variable, value) VALUES (" ||
                part[2] != "KVS_INSTALL_IMPORT" || part[3] != ", " ||
                part[4] !~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/ ||
                part[5] != ") ON DUPLICATE KEY UPDATE value = VALUES(value);") exit 1
            print part[4]
        }
    '
}

# import_resume_token <staged import>: call only after TCP readiness. A normal
# compressed SQL stream has no seekable tail, so decoding it once is required;
# only the final 4 KiB are retained and no SQL is sent to MariaDB.
import_resume_token() (
    set -o pipefail
    local staged="$1" file="$1" tool='' token identity
    local scan_directory='' scan_worker='' scan_timer='' scan_started scan_elapsed scan_next
    if [ "$staged" != "${IMPORT_STAGED_DUMP:-}" ] || [ -z "${IMPORT_RESUME_PREFIX:-}" ]; then
        echo 'ERROR: discover the original staged import before reading its completion token.' >&2
        return 1
    fi
    case "$file" in
        *kvs-import-native.sh) file="${file%.sh}/finalize.sql" ;;
        *.sql.zst) tool=zstd ;;
        *.sql.gz) tool=gzip ;;
        *.sql.xz) tool=xz ;;
        *.sql) ;;
        *) return 1 ;;
    esac
    if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
        echo 'ERROR: the original staged import is no longer a readable regular file.' >&2
        return 1
    fi
    identity=$(stat -Lc '%d:%i:%s:%y:%z' -- "$file") || return 1
    if [ "$identity" != "${IMPORT_RESUME_STAGED_IDENTITY:-}" ]; then
        echo 'ERROR: the staged import changed during recovery; its completion token cannot be trusted.' >&2
        return 1
    fi
    if [ -n "$tool" ]; then
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "ERROR: $tool is required to read the original staged import." >&2
            return 1
        fi
        # Only the token reaches stdout, which setup captures. Keep the scan
        # in its own process group so interruption stops every pipeline member.
        # shellcheck disable=SC2329  # Called by the EXIT trap.
        import_resume_scan_cleanup() {
            if [ -n "$scan_timer" ]; then
                kill "$scan_timer" 2>/dev/null || true
                wait "$scan_timer" 2>/dev/null || true
            fi
            if [ -n "$scan_worker" ]; then
                kill -TERM -- "-$scan_worker" 2>/dev/null || true
                kill -KILL -- "-$scan_worker" 2>/dev/null || true
                wait "$scan_worker" 2>/dev/null || true
            fi
            [ -z "$scan_directory" ] || rm -rf -- "$scan_directory"
        }
        trap import_resume_scan_cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        scan_started=$SECONDS
        scan_next=3
        echo '  Checking staged dump: 0:00:00 elapsed; reading compressed SQL to verify completion (no SQL is replayed).' >&2
        scan_directory=$(mktemp -d "${TMPDIR:-/tmp}/kvs-resume-token.XXXXXX") || return 1
        set -m
        (import_dump_cat "$file" | tail -c 4096 | import_resume_parse_marker "$IMPORT_RESUME_PREFIX") > "$scan_directory/token" &
        scan_worker=$!
        set +m
        while kill -0 "$scan_worker" 2>/dev/null; do
            sleep 1 &
            scan_timer=$!
            wait "$scan_timer" || return 1
            scan_timer=''
            scan_elapsed=$((SECONDS - scan_started))
            if [ "$scan_elapsed" -ge "$scan_next" ] && kill -0 "$scan_worker" 2>/dev/null; then
                printf '  Checking staged dump: %d:%02d:%02d elapsed; still reading compressed SQL to verify completion (no SQL is replayed).\n' \
                    "$((scan_elapsed / 3600))" "$((scan_elapsed / 60 % 60))" "$((scan_elapsed % 60))" >&2
                scan_next=$((scan_elapsed + 3))
            fi
        done
        if ! wait "$scan_worker"; then
            scan_worker=''
            echo 'ERROR: the staged dump is damaged or has no valid final completion marker for this table prefix.' >&2
            return 1
        fi
        scan_worker=''
        token=$(cat -- "$scan_directory/token") || return 1
    else
        token=$(tail -c 4096 -- "$file" | import_resume_parse_marker "$IMPORT_RESUME_PREFIX") || {
            echo 'ERROR: the staged SQL has no valid final completion marker for this table prefix.' >&2
            return 1
        }
    fi
    if [ "$(stat -Lc '%d:%i:%s:%y:%z' -- "$file")" != "$identity" ]; then
        echo 'ERROR: the staged import changed while reading its completion token.' >&2
        return 1
    fi
    if [ -n "$tool" ]; then
        printf '  Staged dump completion token checked (%ss).\n' "$((SECONDS - scan_started))" >&2
    fi
    printf '%s\n' "$token"
)

# Read this first after TCP readiness to avoid decoding a large dump when the
# database has no completion proof. A missing marker is deliberately ambiguous:
# older installers could leave their finalization in an uncommitted transaction.
import_resume_marker() {
    local database="$1" prefix="$2" marker
    import_resume_identifiers "$database" "$prefix" || return 1
    if ! marker=$(database_root_query --protocol=tcp --host=127.0.0.1 --batch --skip-column-names \
        --database="$database" -e "SELECT value FROM \`${prefix}options\` WHERE variable='KVS_INSTALL_IMPORT';" 2>/dev/null); then
        echo 'ERROR: the database completion marker could not be read; recovery has not changed the database.' >&2
        return 1
    fi
    marker=${marker%$'\r'}
    if [[ ! "$marker" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]; then
        echo 'ERROR: the database has no valid import completion marker. It may be incomplete, or an older installer may have left its final settings uncommitted.' >&2
        echo 'Keep the database running and inspect the import before continuing; recovery will not create a marker or replay the dump.' >&2
        return 1
    fi
    printf '%s\n' "$marker"
}

import_resume_verify() {
    local database="$1" prefix="$2" token="$3" marker
    if [[ ! "$token" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]]; then
        echo 'ERROR: the staged import completion token is invalid.' >&2
        return 1
    fi
    marker=$(import_resume_marker "$database" "$prefix") || return 1
    if [ "$marker" != "$token" ]; then
        echo 'ERROR: the database completion marker does not match the original staged import; recovery has not changed the database.' >&2
        return 1
    fi
}
