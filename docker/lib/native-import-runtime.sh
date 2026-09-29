#!/bin/bash
# Sourced inside the official MariaDB entrypoint, from a verified native bundle.

native_import_restore_sql_mode() {
    local original=$1 restored
    [[ "$original" =~ ^[A-Z0-9_,]*$ ]] || return 1
    restored=$(docker_process_sql --batch --skip-column-names \
        -e "SET GLOBAL sql_mode='$original'; SELECT @@GLOBAL.sql_mode;") || return 1
    [ "$restored" = "$original" ]
}

native_import_load() (
    local log original_sql_mode restore_sql_mode=no mode_ready status=0
    log=$(mktemp /tmp/kvs-native-import.XXXXXX) || return 1
    trap '
        status=$?
        if [ "$restore_sql_mode" = yes ]; then
            if ! native_import_restore_sql_mode "$original_sql_mode"; then
                echo "ERROR: the original SQL mode could not be restored after native loading." >&2
                status=1
            fi
        fi
        rm -f -- "$log" || true
        exit "$status"
    ' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    set -o pipefail
    original_sql_mode=$(docker_process_sql --batch --skip-column-names \
        -e 'SELECT @@GLOBAL.sql_mode;') || return 1
    if [[ ! "$original_sql_mode" =~ ^[A-Z0-9_,]*$ ]]; then
        echo 'ERROR: the original SQL mode could not be read safely for native loading.' >&2
        return 1
    fi
    # mariadb-import opens independent loading sessions without an init-command
    # option. During isolated database initialization, set their inherited mode
    # so explicit AUTO_INCREMENT zero values survive, then restore it on exit.
    if [[ ",$original_sql_mode," != *,NO_AUTO_VALUE_ON_ZERO,* ]]; then
        restore_sql_mode=yes
        mode_ready=$(docker_process_sql --batch --skip-column-names -e \
            "SET GLOBAL sql_mode=CONCAT_WS(',', NULLIF(@@GLOBAL.sql_mode,''), 'NO_AUTO_VALUE_ON_ZERO'); SELECT FIND_IN_SET('NO_AUTO_VALUE_ON_ZERO', @@GLOBAL.sql_mode)>0;") || return 1
        if [ "$mode_ready" != 1 ]; then
            echo 'ERROR: native loading could not enable preservation of AUTO_INCREMENT zero values.' >&2
            return 1
        fi
    fi
    if ! MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-}" mariadb-import --no-defaults \
        --protocol=socket --socket="${SOCKET:-/run/mysqld/mysqld.sock}" --user=root \
        --innodb-optimize-keys --verbose "$@" 2>&1 | tee "$log"; then
        echo 'ERROR: native data or index loading failed; the completion marker was not written.' >&2
        return 1
    fi
    if grep -Eq '(Warnings|Skipped):[[:space:]]*[1-9][0-9]*' "$log"; then
        echo 'ERROR: native loading reported warnings or skipped rows; the completion marker was not written.' >&2
        return 1
    fi
)

# Keep the original indexes and constraints on generated-column tables. Native
# mariadb-import recreates tables and drops their foreign keys; adding those
# keys again can fail when a referenced base column feeds a stored expression.
native_import_load_generated() {
    local root=$1 database=$2 table=$3 mapping=$4 file warnings
    file="$root/data/$database/$table.txt"
    if [[ ! "$file" =~ ^/[A-Za-z0-9_./-]+$ ]] || [ ! -f "$file" ]; then
        echo 'ERROR: unsupported generated-column data path in native import.' >&2
        return 1
    fi
    if ! warnings=$(docker_process_sql --batch --skip-column-names --database="$database" -e "
SET SESSION foreign_key_checks=0;
SET SESSION unique_checks=1;
SET SESSION time_zone='+00:00';
SET SESSION sql_mode=CONCAT_WS(',', NULLIF(@@SESSION.sql_mode,''), 'NO_AUTO_VALUE_ON_ZERO');
LOAD DATA INFILE '$file' INTO TABLE \`$table\` CHARACTER SET binary ($mapping);
SELECT @@warning_count;"); then
        echo 'ERROR: generated-column data loading failed; the completion marker was not written.' >&2
        return 1
    fi
    if [ "$warnings" != 0 ]; then
        echo 'ERROR: generated-column loading reported warnings or could not be verified; the completion marker was not written.' >&2
        return 1
    fi
}

# Return the original column order, including fields which SELECT * would hide.
# The source dump writes every column in ordinal order, including generated ones.
native_import_columns() {
    docker_process_sql --batch --skip-column-names --database="$1" -e "
SELECT c.TABLE_NAME, c.ORDINAL_POSITION, c.COLUMN_NAME,
 IF(c.EXTRA REGEXP 'GENERATED', 'generated', 'value'),
 HEX(c.COLUMN_TYPE), HEX(c.EXTRA), COALESCE(HEX(c.GENERATION_EXPRESSION),'')
FROM information_schema.COLUMNS c
WHERE c.TABLE_SCHEMA=DATABASE() AND c.TABLE_NAME IN (
 SELECT s.TABLE_NAME FROM information_schema.COLUMNS s
 WHERE s.TABLE_SCHEMA=DATABASE() AND s.EXTRA REGEXP 'GENERATED|INVISIBLE'
)
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;"
}

native_import_foreign_keys() {
    docker_process_sql --batch --skip-column-names --database="$1" -e "
SELECT k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION, k.COLUMN_NAME,
 k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME,
 r.UPDATE_RULE, r.DELETE_RULE
FROM information_schema.KEY_COLUMN_USAGE k
JOIN information_schema.REFERENTIAL_CONSTRAINTS r
 ON r.CONSTRAINT_SCHEMA=k.CONSTRAINT_SCHEMA
 AND r.CONSTRAINT_NAME=k.CONSTRAINT_NAME AND r.TABLE_NAME=k.TABLE_NAME
WHERE k.CONSTRAINT_SCHEMA=DATABASE() AND k.REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION;"
}

# Validate every FK, including nullable composites and self references. Enabling
# foreign_key_checks alone does not validate rows loaded with checks disabled.
# The metadata-only pass rejects unsupported definitions before data loading.
native_import_check_foreign_keys() {
    local database=$1 metadata=$2 table constraint ordinal column ref_schema ref_table ref_column _rules
    local key previous='' previous_table='' previous_ref='' next=1 join='' not_null='' result i
    local -a queries=() names=()
    local -A seen=()
    [ -n "$metadata" ] || return 0
    while IFS=$'\t' read -r table constraint ordinal column ref_schema ref_table ref_column _rules; do
        for key in "$table" "$constraint" "$column" "$ref_table" "$ref_column"; do
            if [[ ! "$key" =~ ^[A-Za-z0-9_]{1,64}$ ]]; then
                echo 'ERROR: unsupported foreign key identifier in native import.' >&2
                return 1
            fi
        done
        if [ "$ref_schema" != "$database" ]; then
            echo 'ERROR: native imports cannot reference another database.' >&2
            return 1
        fi
        key="$table.$constraint"
        if [ "$key" != "$previous" ]; then
            if [ -n "${seen[$key]:-}" ]; then
                echo 'ERROR: unordered foreign key metadata in native import.' >&2
                return 1
            fi
            seen[$key]=yes
            if [ -n "$previous" ]; then
                queries+=("SELECT EXISTS(SELECT 1 FROM \`$previous_table\` c WHERE $not_null AND NOT EXISTS(SELECT 1 FROM \`$previous_ref\` p WHERE $join) LIMIT 1);")
                names+=("$previous")
            fi
            previous=$key previous_table=$table previous_ref=$ref_table
            next=1 join='' not_null=''
        fi
        if [ "$ordinal" != "$next" ] || [ "$ref_table" != "$previous_ref" ]; then
            echo 'ERROR: incomplete foreign key metadata in native import.' >&2
            return 1
        fi
        join+="${join:+ AND }p.\`$ref_column\`=c.\`$column\`"
        not_null+="${not_null:+ AND }c.\`$column\` IS NOT NULL"
        next=$((next + 1))
    done <<< "$metadata"
    queries+=("SELECT EXISTS(SELECT 1 FROM \`$previous_table\` c WHERE $not_null AND NOT EXISTS(SELECT 1 FROM \`$previous_ref\` p WHERE $join) LIMIT 1);")
    names+=("$previous")
    [ "${3:-verify}" != metadata-only ] || return 0
    for ((i=0; i<${#queries[@]}; i++)); do
        echo "Native database import: checking foreign key ${names[$i]}."
        result=$(docker_process_sql --batch --skip-column-names --database="$database" \
            -e "SET SESSION foreign_key_checks=1; ${queries[$i]}") || return 1
        if [ "$result" != 0 ]; then
            echo "ERROR: foreign key ${names[$i]} has orphaned rows or could not be verified; the completion marker was not written." >&2
            return 1
        fi
    done
}

native_import_run() {
    local root=$1 database=$2 tables=$3 jobs=$4 columns before_keys after_keys after_columns
    local table ordinal column kind _details current='' expected=1 count file
    local -a special=() exclusions=()
    local -A mappings=()

    if ! mariadb-import --no-defaults --help 2>/dev/null | grep -F -- '--innodb-optimize-keys' >/dev/null; then
        echo 'ERROR: native imports require mariadb-import 11.8 or newer.' >&2
        return 1
    fi
    # Create every table first, including both ends of cyclic foreign keys.
    # The native loader recreates ordinary tables. Generated-column tables keep
    # their original definitions, indexes and foreign keys throughout loading.
    echo 'Native database import: preparing table definitions.'
    if ! (
        set -o pipefail
        {
            printf 'SET SESSION foreign_key_checks=0;\n'
            for file in "$root/data/$database/"*.sql; do
                cat -- "$file" || exit 1
                printf '\n'
            done
        } | docker_process_sql --database="$database"
    ); then
        echo 'ERROR: native table creation failed; the completion marker was not written.' >&2
        return 1
    fi
    columns=$(native_import_columns "$database") || return 1
    before_keys=$(native_import_foreign_keys "$database") || return 1
    native_import_check_foreign_keys "$database" "$before_keys" metadata-only || return 1
    if [ -n "$columns" ]; then
        while IFS=$'\t' read -r table ordinal column kind _details; do
            if [[ ! "$table" =~ ^[A-Za-z0-9_]{1,64}$ || ! "$column" =~ ^[A-Za-z0-9_]{1,64}$ ]] ||
                [ ! -f "$root/data/$database/$table.sql" ] || [ ! -f "$root/data/$database/$table.txt" ]; then
                echo 'ERROR: unsupported column mapping in native import.' >&2
                return 1
            fi
            if [ "$table" != "$current" ]; then
                if [ -n "${mappings[$table]:-}" ]; then
                    echo 'ERROR: unordered column metadata in native import.' >&2
                    return 1
                fi
                current=$table expected=1
                special+=("$table")
                exclusions+=("--ignore-table=$database.$table")
            fi
            if [ "$ordinal" != "$expected" ]; then
                echo 'ERROR: incomplete column mapping in native import.' >&2
                return 1
            fi
            case "$kind" in
                generated) column="@kvs_generated_$ordinal" ;;
                value) column="\`$column\`" ;;
                *) echo 'ERROR: unknown native column mapping type.' >&2; return 1 ;;
            esac
            mappings[$table]+="${mappings[$table]:+,}$column"
            expected=$((expected + 1))
        done <<< "$columns"
    fi
    if [ "${#special[@]}" -gt "$tables" ]; then
        echo 'ERROR: native column mappings exceed the table count.' >&2
        return 1
    fi
    if [ "${#special[@]}" -lt "$tables" ]; then
        echo "Native database import: loading $((tables - ${#special[@]})) ordinary tables with $jobs workers."
        native_import_load --dir="$root/data" --parallel="$jobs" "${exclusions[@]}" || return 1
    fi
    for table in "${special[@]}"; do
        echo "Native database import: loading $table with an explicit generated-column mapping."
        native_import_load_generated "$root" "$database" "$table" "${mappings[$table]}" || return 1
    done
    count=$(docker_process_sql --batch --skip-column-names --database="$database" \
        -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE';") || return 1
    if [ "$count" != "$tables" ]; then
        echo 'ERROR: restored table count does not match the native bundle; the completion marker was not written.' >&2
        return 1
    fi
    after_columns=$(native_import_columns "$database") || return 1
    after_keys=$(native_import_foreign_keys "$database") || return 1
    if [ "$columns" != "$after_columns" ] || [ "$before_keys" != "$after_keys" ]; then
        echo 'ERROR: native loading changed column definitions or foreign keys; the completion marker was not written.' >&2
        return 1
    fi
    native_import_check_foreign_keys "$database" "$after_keys" || return 1
    docker_process_sql --database="$database" < "$root/finalize.sql" || return 1
    echo 'Native database import: data, generated columns, indexes, foreign keys and site settings completed.'
}
