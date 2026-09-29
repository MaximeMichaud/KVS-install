#!/bin/bash
# Native MariaDB directory imports. Requires the helpers in lib/import.sh.

# native_import_jobs <auto|1..32>: bound automatic concurrency on small hosts.
native_import_jobs() {
    local requested="${1:-auto}" cpus memory jobs

    if declare -F database_import_jobs >/dev/null; then
        database_import_jobs "$requested"
        return
    fi
    if [ "$requested" != auto ]; then
        if [[ ! "$requested" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]]; then
            echo "ERROR: IMPORT_DATABASE_JOBS must be auto or an integer from 1 to 32" >&2
            return 1
        fi
        printf '%s\n' "$requested"
        return 0
    fi
    cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cpus=1
    [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || cpus=1
    if declare -F database_available_memory_mb >/dev/null; then
        memory=$(database_available_memory_mb) || memory=0
    else
        memory=$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' /proc/meminfo 2>/dev/null) || memory=0
    fi
    [[ "$memory" =~ ^[0-9]+$ ]] || memory=0
    jobs=$((memory / 512))
    [ "$jobs" -ge 1 ] || jobs=1
    [ "$jobs" -le "$cpus" ] || jobs=$cpus
    [ "$jobs" -le 8 ] || jobs=8
    printf '%s\n' "$jobs"
}

# Reject unsafe paths, links, special files, duplicate entries and unexpected
# files before extraction. GNU tar escapes control characters in this listing;
# the deliberately narrow filename alphabet rejects those escaped names too.
native_import_archive_check() {
    local archive="$1" listing="$2"

    case "$archive" in
        *.mariadb.tar.zst|*.mariadb.tar.gz) ;;
        *) echo "ERROR: native imports require a .mariadb.tar.zst or .mariadb.tar.gz bundle" >&2; return 1 ;;
    esac
    [ -f "$archive" ] || { echo "ERROR: native import bundle is missing: $archive" >&2; return 1; }
    LC_ALL=C tar --numeric-owner --quoting-style=escape -tvf "$archive" > "$listing" || return 1
    awk '
        function invalid() { bad = 1 }
        {
            type = substr($1, 1, 1)
            name = $0
            sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", name)
            sub(/^\.\//, "", name)
            sub(/\/$/, "", name)
            if (name == "." && type == "d") next
            if (seen[name]++) invalid()
            if (type == "d") { if (name != "data") invalid(); next }
            if (type != "-") { invalid(); next }
            if (name == "kvs-native-export.manifest") { manifest++; next }
            if (name == "SHA256SUMS") { hashes++; next }
            if (name !~ /^data\/[A-Za-z0-9_]+\.(sql|txt)$/) { invalid(); next }
            if (name ~ /\.sql$/) { sql++; schemas[substr(name, 1, length(name)-4)]++ }
            else { txt++; contents[substr(name, 1, length(name)-4)]++ }
        }
        END {
            for (name in schemas) if (contents[name] != 1) invalid()
            for (name in contents) if (schemas[name] != 1) invalid()
            if (bad || manifest != 1 || hashes != 1 || sql == 0 || sql != txt) {
                print "ERROR: invalid native bundle layout, missing table pairs, duplicate entries or unsafe archive member" > "/dev/stderr"
                exit 1
            }
        }
    ' "$listing"
}

# The native payload must fit beside the still-existing database volume.
# Reserve rounded file blocks and a small allowance for directory metadata.
native_import_stage_space() {
    local listing="$1" directory="$2" required available
    required=$(awk 'substr($1, 1, 1) == "-" { bytes += int(($3 + 4095) / 4096) * 4096 }
        END { printf "%.0f\n", bytes + 16777216 }' "$listing") || return 1
    available=$(df -PB1 -- "$directory" | awk 'NR == 2 { print $4 }') || return 1
    if [[ ! "$required" =~ ^[0-9]+$ || ! "$available" =~ ^[0-9]+$ ]]; then
        echo "ERROR: could not determine free space for native import staging" >&2
        return 1
    fi
    if [ "$available" -lt "$required" ]; then
        echo "ERROR: native import staging needs $required bytes including its reserve; only $available bytes are available in $directory" >&2
        return 1
    fi
}

# native_import_metadata <manifest> <prefix>: validate without sourcing input.
native_import_metadata() {
    local manifest="$1" prefix="$2" field value

    for field in format complete source_database tables_prefix kvs_version tables; do
        if [ "$(grep -c "^${field}=" "$manifest")" != 1 ]; then
            echo "ERROR: native bundle manifest has a missing or duplicate $field field" >&2
            return 1
        fi
    done
    [[ "$(import_kv "$manifest" format)" =~ ^[12]$ ]] &&
        [ "$(import_kv "$manifest" complete)" = yes ] || {
        echo "ERROR: native bundle is incomplete or uses an unsupported format" >&2
        return 1
    }
    value=$(import_kv "$manifest" source_database)
    [[ "$value" =~ ^[A-Za-z0-9_]{1,64}$ ]] || return 1
    [[ "$prefix" =~ ^[A-Za-z0-9_]{1,32}$ ]] || return 1
    [ "$(import_kv "$manifest" tables_prefix)" = "$prefix" ] || {
        echo "ERROR: native bundle table prefix does not match the site" >&2
        return 1
    }
    value=$(import_kv "$manifest" kvs_version)
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+([._+-][A-Za-z0-9]+)*$ ]] || return 1
    value=$(import_kv "$manifest" tables)
    [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] || return 1
}

# Inspect metadata and archive structure, without extracting the data files.
# The return fields match import_inspect_dump: tables, version, USE count, done.
native_import_inspect() (
    local archive="$1" prefix="$2" work tables total expected
    work=$(mktemp -d) || return 1
    trap 'rm -rf -- "$work"' EXIT
    native_import_archive_check "$archive" "$work/list" || return 1
    tar -xOf "$archive" --occurrence=1 --wildcards --no-anchored kvs-native-export.manifest > "$work/manifest" || return 1
    native_import_metadata "$work/manifest" "$prefix" || return 1
    expected=$(import_kv "$work/manifest" tables)
    total=$(awk '$NF ~ /^([.]\/)?data\/[A-Za-z0-9_]+[.]sql$/ { n++ } END { print n+0 }' "$work/list")
    tables=$(awk -v prefix="$prefix" '$NF ~ ("^([.]\\/)?data/" prefix "[A-Za-z0-9_]*[.]sql$") { n++ } END { print n+0 }' "$work/list")
    if [ "$total" != "$expected" ] || [ "$tables" -lt 1 ]; then
        echo "ERROR: native bundle table count does not match its manifest or site prefix" >&2
        return 1
    fi
    printf '%s\t\t0\tyes\n' "$tables"
)

# Require a checksum for every payload file exactly once; do not allow the
# checksum file itself to name paths outside this private extraction directory.
native_import_verify_hashes() {
    local directory="$1" line digest filename count=0 expected
    local -A seen=()

    while IFS= read -r line || [ -n "$line" ]; do
        digest=${line:0:64}
        filename=${line:66}
        if [[ ! "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || [ "${line:64:2}" != '  ' ]; then
            echo "ERROR: invalid native bundle checksum record" >&2
            return 1
        fi
        if [[ "$filename" != kvs-native-export.manifest && ! "$filename" =~ ^data/[A-Za-z0-9_]+\.(sql|txt)$ ]]; then
            echo "ERROR: unsafe native bundle checksum path" >&2
            return 1
        fi
        if [ -n "${seen[$filename]:-}" ] || [ ! -f "$directory/$filename" ]; then
            echo "ERROR: duplicate or missing native bundle checksum member" >&2
            return 1
        fi
        seen[$filename]=yes
        count=$((count + 1))
    done < "$directory/SHA256SUMS"
    expected=$(find "$directory/data" -maxdepth 1 -type f -printf '.\n' | wc -l)
    if [ "$count" -ne "$((expected + 1))" ] || [ -z "${seen[kvs-native-export.manifest]:-}" ]; then
        echo "ERROR: native bundle checksums do not cover every payload file" >&2
        return 1
    fi
    (cd "$directory" && sha256sum --check --strict --status SHA256SUMS) || {
        echo "ERROR: native bundle checksum verification failed" >&2
        return 1
    }
}

# Generated columns and unqualified foreign keys are supported. Refuse schema
# constructs which cannot be safely moved to a different database name.
native_import_validate_schema() {
    local directory="$1" file table references reference
    for file in "$directory"/data/*.sql; do
        table=${file##*/}
        table=${table%.sql}
        if ! references=$(awk -v table="$table" '
            # Remove string literals and ordinary comments before looking for
            # SQL structure. Keep quoted identifiers and executable comments.
            function structure(line,    i, c, next_c, result) {
                result = ""
                for (i = 1; i <= length(line); i++) {
                    c = substr(line, i, 1); next_c = substr(line, i+1, 1)
                    if (comment) {
                        if (c == "*" && next_c == "/") { comment = 0; i++ }
                        continue
                    }
                    if (quote != "") {
                        if (escaped) { escaped = 0; continue }
                        if (c == "\\") { escaped = 1; continue }
                        if (c == quote) {
                            if (next_c == quote) i++
                            else quote = ""
                        }
                        continue
                    }
                    if (identifier) {
                        result = result c
                        if (c == "`") {
                            if (next_c == "`") { result = result next_c; i++ }
                            else identifier = 0
                        }
                        continue
                    }
                    if (c == "\047" || c == "\"") { quote = c; result = result " "; continue }
                    if (c == "`") { identifier = 1; result = result c; continue }
                    if (c == "#" || (c == "-" && next_c == "-" && substr(line, i+2, 1) ~ /[[:space:]]/)) break
                    if (c == "/" && next_c == "*") {
                        if (substr(line, i+2, 1) == "!") i += 2
                        else if (substr(line, i+2, 2) == "M!") i += 3
                        else { comment = 1; i++ }
                        result = result " "
                        continue
                    }
                    if (c == "*" && next_c == "/") { result = result " "; i++; continue }
                    result = result c
                }
                return result
            }
            {
                code = structure($0)
                upper = toupper(code)
                gsub(/`([^`]|``)*`/, "`identifier`", upper)
                if (upper ~ /(^|[^A-Z_])(VIEW|TRIGGER|PROCEDURE|FUNCTION|EVENT|USE)([[:space:]]|$)/ ||
                    code ~ /`[^`]+`[[:space:]]*\.[[:space:]]*`/ ||
                    upper ~ /CREATE[[:space:]]+DATABASE/) bad = 1
                if (upper ~ /(^|[^A-Z_])REFERENCES[[:space:]]/) {
                    remaining = upper; expected_refs = 0; parsed_refs = 0
                    while (match(remaining, /(^|[^A-Z_])REFERENCES[[:space:]]/)) {
                        expected_refs++
                        remaining = substr(remaining, RSTART + RLENGTH)
                    }
                    remaining = code
                    while (match(remaining, /(^|[^A-Za-z_])[Rr][Ee][Ff][Ee][Rr][Ee][Nn][Cc][Ee][Ss][[:space:]]+`[A-Za-z0-9_]+`[[:space:]]*\(/)) {
                        reference = substr(remaining, RSTART, RLENGTH)
                        remaining = substr(remaining, RSTART + RLENGTH)
                        parsed_refs++
                        sub(/^[^`]*`/, "", reference)
                        sub(/`.*/, "", reference)
                        print reference
                    }
                    if (parsed_refs != expected_refs) bad = 1
                }
                if (upper ~ /^[[:space:]]*CREATE[[:space:]]+TABLE[[:space:]]/) {
                    definitions++
                    name = code
                    sub(/^[[:space:]]*[Cc][Rr][Ee][Aa][Tt][Ee][[:space:]]+[Tt][Aa][Bb][Ll][Ee][[:space:]]+/, "", name)
                    if (name !~ ("^`" table "`[[:space:]]*\\(")) bad = 1
                }
            }
            END { if (bad || definitions != 1 || quote != "" || comment || identifier) exit 1 }
        ' "$file"); then
            echo "ERROR: native import requires unqualified table definitions and internal foreign keys ($table); use SQL format for unsupported schemas" >&2
            return 1
        fi
        while IFS= read -r reference; do
            [ -n "$reference" ] || continue
            if [ ! -f "$directory/data/$reference.sql" ] || [ ! -f "$directory/data/$reference.txt" ]; then
                echo "ERROR: native foreign key in $table references a table missing from the bundle: $reference" >&2
                return 1
            fi
        done <<< "$references"
    done
}

# native_import_prepare <bundle> <prefix> <version> <old path> <new path>
#                       <stage directory> <token> <destination database> <jobs>
# Publish a read-only payload and a sibling init hook only after full validation.
native_import_prepare() (
    local archive="$1" prefix="$2" version="$3" old_path="$4" new_path="$5"
    local stage="$6" token="$7" database="$8" requested="${9:-auto}"
    local parent work jobs tables total sql runtime
    [[ "$database" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { echo "ERROR: invalid destination database name" >&2; return 1; }
    [ "$database" != . ] && [ "$database" != .. ] || { echo "ERROR: invalid destination database name" >&2; return 1; }
    jobs=$(native_import_jobs "$requested") || return 1
    if [ -e "$stage" ] || [ -L "$stage" ] || [ -e "$stage.sh" ] || [ -L "$stage.sh" ]; then
        echo "ERROR: native import staging destination already exists: $stage" >&2
        return 1
    fi
    parent=$(dirname -- "$stage")
    mkdir -p -- "$parent" || return 1
    work=$(mktemp -d "$parent/.native-import.XXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    native_import_archive_check "$archive" "$work/list" || return 1
    native_import_stage_space "$work/list" "$parent" || return 1
    mkdir "$work/payload" || return 1
    tar -xf "$archive" --no-same-owner --no-same-permissions --delay-directory-restore -C "$work/payload" || return 1
    native_import_metadata "$work/payload/kvs-native-export.manifest" "$prefix" || return 1
    native_import_verify_hashes "$work/payload" || return 1
    native_import_validate_schema "$work/payload" || return 1
    tables=$(import_kv "$work/payload/kvs-native-export.manifest" tables)
    total=$(find "$work/payload/data" -maxdepth 1 -name '*.sql' -type f -printf '.\n' | wc -l)
    if [ "$tables" -ne "$total" ] || [ ! -f "$work/payload/data/${prefix}options.sql" ]; then
        echo "ERROR: native bundle has an incorrect table count or no options table" >&2
        return 1
    fi
    runtime="$(dirname -- "${BASH_SOURCE[0]}")/native-import-runtime.sh"
    cp -- "$runtime" "$work/payload/runtime.sh" || return 1
    sql="$work/payload/finalize.sql"
    {
        echo 'SET autocommit=1;'
        printf "INSERT INTO \`%soptions\` (variable, value) VALUES ('INITIAL_VERSION', '%s') ON DUPLICATE KEY UPDATE value = value;\n" "$prefix" "$(import_sql_escape "$version")"
        if [ "$old_path" != "$new_path" ]; then
            import_path_rewrite_sql "$prefix" "$old_path" "$new_path"
        fi
        printf "INSERT INTO \`%soptions\` (variable, value) VALUES ('KVS_INSTALL_IMPORT', '%s') ON DUPLICATE KEY UPDATE value = VALUES(value);\n" "$prefix" "$(import_sql_escape "$token")"
    } > "$sql" || return 1
    mv "$work/payload/data" "$work/source-data" || return 1
    mkdir "$work/payload/data" || return 1
    mv "$work/source-data" "$work/payload/data/$database" || return 1
    {
        echo '#!/bin/bash'
        echo '# Sourced by the official MariaDB entrypoint during initialization.'
        printf 'native_import_root=/docker-entrypoint-initdb.d/%q\n' "$(basename -- "$stage")"
        printf 'native_import_database=%q\nnative_import_tables=%q\nnative_import_jobs=%q\n' "$database" "$tables" "$jobs"
        cat <<'HOOK'
# shellcheck source=/dev/null
source "$native_import_root/runtime.sh" || return 1
native_import_run "$native_import_root" "$native_import_database" "$native_import_tables" "$native_import_jobs" || return 1
unset native_import_root native_import_database native_import_tables native_import_jobs
HOOK
    } > "$work/hook.sh" || return 1
    find "$work/payload" -type d -exec chmod 755 {} + || return 1
    find "$work/payload" -type f -exec chmod 644 {} + || return 1
    chmod 644 "$work/hook.sh" || return 1
    mv "$work/payload" "$stage" || return 1
    if ! mv "$work/hook.sh" "$stage.sh"; then
        rm -rf -- "$stage"
        return 1
    fi
    printf '%s\n' "$stage.sh"
)
