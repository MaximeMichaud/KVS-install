#!/bin/bash
# Import of an existing KVS site: the shared functions of docker/lib/import.sh
# on fixtures, and the wiring of the Docker setup and init scripts.
# shellcheck disable=SC2016  # Fixture content and grep patterns hold literal dollar signs.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/kvs-import-test.XXXXXX)
TESTS_RUN=0

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "ok $TESTS_RUN - $1"
}

# shellcheck source=../docker/lib/import.sh
source "$REPO_ROOT/docker/lib/import.sh"

make_site() {
    local dir="$1"
    local project_path="$2"
    local prefix="${3:-ktvs_}"

    mkdir -p "$dir/admin/include" "$dir/contents/videos"
    cat > "$dir/admin/include/setup.php" <<EOF
<?php
\$config['project_path']="$project_path";
\$config['project_url']="https://old.example.com";
\$config['ffmpeg_path']="/opt/ffmpeg/bin/ffmpeg";
\$config['tables_prefix']="$prefix";
EOF
    echo "<?php define('DB_HOST','localhost');" > "$dir/admin/include/setup_db.php"
    printf '<?php\n/* Developed by Kernel Team. */\n$config['"'"'project_version'"'"'] = "7.0.2";\n' > "$dir/admin/include/version.php"
    echo "video" > "$dir/contents/videos/1.mp4"
}

make_dump() {
    local file="$1"
    local with_initial="$2"
    {
        echo "-- MariaDB dump"
        echo "CREATE DATABASE /*!32312 IF NOT EXISTS*/ \`oldsite\`;"
        echo "USE \`oldsite\`;"
        echo "CREATE TABLE \`ktvs_options\` (\`variable\` varchar(255) NOT NULL, \`value\` text NOT NULL, PRIMARY KEY (\`variable\`));"
        if [ "$with_initial" = yes ]; then
            echo "INSERT INTO \`ktvs_options\` VALUES ('CRON_TIME','1'),('INITIAL_VERSION','5.5.1'),('UPDATE_VERSION','7.0.2');"
        else
            echo "INSERT INTO \`ktvs_options\` VALUES ('CRON_TIME','1'),('UPDATE_VERSION','7.0.2');"
        fi
        echo "CREATE TABLE \`ktvs_admin_servers\` (\`server_id\` int, \`path\` varchar(255), \`urls\` text);"
        echo "INSERT INTO \`ktvs_admin_servers\` VALUES (1,'/home/old/www/contents/videos','https://old.example.com/contents/videos');"
        echo "CREATE TABLE \`other_table\` (\`id\` int);"
    } > "$file"
}

test_php_config_values_are_read_as_kvs_writes_them() {
    local site="$TMP_ROOT/site-read"
    make_site "$site" /home/old/www

    [ "$(import_read_php_config_value "$site/admin/include/setup.php" project_path)" = "/home/old/www" ] ||
        fail "project_path must be read from setup.php"
    [ "$(import_read_php_config_value "$site/admin/include/setup.php" tables_prefix)" = "ktvs_" ] ||
        fail "tables_prefix must be read from setup.php"
    [ "$(import_read_kvs_version "$site")" = "7.0.2" ] ||
        fail "the version must be read from version.php with spaces around the equal sign"
    pass "PHP config values are read as KVS writes them"
}

test_site_validation_accepts_a_kvs_site_and_refuses_the_rest() {
    local site="$TMP_ROOT/site-valid"
    local output
    make_site "$site" /home/old/www

    output=$(import_validate_site "$site") || fail "a KVS site must validate"
    [ "$output" = $'7.0.2\t/home/old/www' ] || fail "validation must print the version and the project path: got '$output'"

    output=$(import_validate_site "$TMP_ROOT/missing" 2>&1) && fail "a missing directory must be refused"
    grep -q "not a directory" <<< "$output" || fail "a missing directory must be named: $output"

    mkdir -p "$TMP_ROOT/empty"
    output=$(import_validate_site "$TMP_ROOT/empty" 2>&1) && fail "a directory without setup.php must be refused"
    grep -q "setup.php is missing" <<< "$output" || fail "the missing setup.php must be named: $output"

    make_site "$TMP_ROOT/site-prefix" /home/old/www "site_"
    output=$(import_validate_site "$TMP_ROOT/site-prefix" 2>&1) && fail "another table prefix must be refused"
    grep -q "table prefix 'site_'" <<< "$output" || fail "the prefix must be named: $output"

    make_site "$TMP_ROOT/site-nodb" /home/old/www
    rm "$TMP_ROOT/site-nodb/admin/include/setup_db.php"
    output=$(import_validate_site "$TMP_ROOT/site-nodb" 2>&1) && fail "a site without setup_db.php must be refused"

    make_site "$TMP_ROOT/site-noversion" /home/old/www
    rm "$TMP_ROOT/site-noversion/admin/include/version.php"
    output=$(import_validate_site "$TMP_ROOT/site-noversion" 2>&1) && fail "a site without version.php must be refused"

    pass "site validation accepts a KVS site and refuses the rest"
}

test_archive_version_is_read_from_the_zip() {
    local stage="$TMP_ROOT/archive-stage"
    make_site "$stage" /var/www/kvs
    (cd "$stage" && zip -q -r "$TMP_ROOT/KVS_7.0.2_[example.com].zip" admin)

    [ "$(import_archive_version "$TMP_ROOT/KVS_7.0.2_[example.com].zip")" = "7.0.2" ] ||
        fail "the archive version must come from its version.php"
    [ -z "$(import_archive_version "$TMP_ROOT/missing.zip")" ] ||
        fail "a missing archive must yield an empty version"
    pass "archive version is read from the zip"
}

test_dump_inspection_counts_tables_and_finds_the_markers() {
    local dump="$TMP_ROOT/dump-with.sql"
    make_dump "$dump" yes

    [ "$(import_inspect_dump "$dump" ktvs_)" = $'2\t5.5.1\t2' ] ||
        fail "inspection must count the ktvs_ tables, the INITIAL_VERSION and the database statements: got '$(import_inspect_dump "$dump" ktvs_)'"

    make_dump "$TMP_ROOT/dump-without.sql" no
    [ "$(import_inspect_dump "$TMP_ROOT/dump-without.sql" ktvs_)" = $'2\t\t2' ] ||
        fail "a dump without INITIAL_VERSION must report it empty"

    zstd -q -f "$dump" -o "$TMP_ROOT/dump.sql.zst"
    gzip -c "$dump" > "$TMP_ROOT/dump.sql.gz"
    [ "$(import_inspect_dump "$TMP_ROOT/dump.sql.zst" ktvs_)" = $'2\t5.5.1\t2' ] || fail "a zstd dump must be read"
    [ "$(import_inspect_dump "$TMP_ROOT/dump.sql.gz" ktvs_)" = $'2\t5.5.1\t2' ] || fail "a gzip dump must be read"

    [ "$(import_inspect_dump "$dump" site_)" = $'0\t5.5.1\t2' ] || fail "tables of another prefix must not count"
    import_inspect_dump "$TMP_ROOT/missing.sql" ktvs_ 2>/dev/null && fail "a missing dump must be refused"
    pass "dump inspection counts tables and finds the markers"
}

test_prepared_dump_loads_into_the_container_database() {
    local dump="$TMP_ROOT/dump-prepare.sql"
    local output="$TMP_ROOT/prepared.sql.zst"
    local result content
    make_dump "$dump" no

    result=$(import_prepare_dump "$dump" ktvs_ 7.0.2 /home/old/www /var/www/kvs "$output" token-123) ||
        fail "a dump with ktvs_ tables must be prepared"
    [ "$result" = $'2\t\t2' ] || fail "preparation must report the inspection: got '$result'"
    [ "$(import_field $'a\t\tc' 2)" = "" ] && [ "$(import_field $'a\t\tc' 3)" = "c" ] || fail "import_field must keep empty fields"
    content=$(zstd -dc "$output")
    grep -q "^CREATE DATABASE" <<< "$content" && fail "CREATE DATABASE must be dropped"
    grep -q "^USE " <<< "$content" && fail "USE must be dropped"
    grep -q "^CREATE TABLE \`ktvs_options\`" <<< "$content" || fail "the tables must be kept"
    grep -Fq "('INITIAL_VERSION', '7.0.2')" <<< "$content" || fail "a missing INITIAL_VERSION must be recorded with the site version"
    grep -Fq "UPDATE \`ktvs_admin_servers\` SET path = CONCAT('/var/www/kvs', SUBSTRING(path, CHAR_LENGTH('/home/old/www') + 1)) WHERE path = '/home/old/www' OR path LIKE '/home/old/www/%';" <<< "$content" ||
        fail "the storage server paths must move to the container path"
    grep -Fq "UPDATE \`ktvs_admin_conversion_servers\` SET path" <<< "$content" || fail "the conversion server paths must move too"
    [ "$(tail -n 1 <<< "$content")" = "INSERT INTO \`ktvs_options\` (variable, value) VALUES ('KVS_INSTALL_IMPORT', 'token-123') ON DUPLICATE KEY UPDATE value = VALUES(value);" ] ||
        fail "the completion marker must be the last statement: got '$(tail -n 1 <<< "$content")'"

    make_dump "$TMP_ROOT/dump-same.sql" yes
    import_prepare_dump "$TMP_ROOT/dump-same.sql" ktvs_ 7.0.2 /var/www/kvs /var/www/kvs "$TMP_ROOT/same.sql" token-456 >/dev/null ||
        fail "a dump for the same path must be prepared"
    grep -q "INITIAL_VERSION', '7.0.2'" "$TMP_ROOT/same.sql" && fail "a present INITIAL_VERSION must not be rewritten"
    grep -q "^UPDATE " "$TMP_ROOT/same.sql" && fail "no path rewrite when the project path is already the container path"
    grep -Fq "'KVS_INSTALL_IMPORT', 'token-456'" "$TMP_ROOT/same.sql" || fail "the marker must be present in a plain output too"

    echo "-- nothing here" > "$TMP_ROOT/dump-empty.sql"
    import_prepare_dump "$TMP_ROOT/dump-empty.sql" ktvs_ 7.0.2 /a /b "$TMP_ROOT/empty.sql" t 2>/dev/null &&
        fail "a dump without ktvs_ tables must be refused"
    pass "prepared dump loads into the container database"
}

test_sql_escaping_survives_quotes_and_like_wildcards() {
    local sql
    sql=$(import_path_rewrite_sql ktvs_ "/srv/it's_100%/www" /var/www/kvs)
    grep -Fq "CHAR_LENGTH('/srv/it\\'s_100%/www')" <<< "$sql" || fail "quotes must be escaped in the SQL string"
    grep -Fq "LIKE '/srv/it\\'s\\_100\\%/www/%'" <<< "$sql" || fail "LIKE wildcards must be escaped in the pattern: $sql"
    pass "SQL escaping survives quotes and LIKE wildcards"
}

test_site_placement_copies_once_and_refuses_a_used_directory() {
    local source="$TMP_ROOT/place-source"
    local destination="$TMP_ROOT/place-destination"
    local output
    make_site "$source" /home/old/www
    touch "$source/.kvs-extraction-in-progress"

    output=$(import_place_site "$source" "$destination") || fail "a copy into an absent directory must succeed"
    [ -f "$destination/contents/videos/1.mp4" ] || fail "the site files must be copied"
    [ ! -e "$destination/.kvs-extraction-in-progress" ] || fail "an interrupted extraction marker must not travel"
    grep -q "copied" <<< "$output" || fail "the copy must be reported: $output"

    [ "$(cat "$destination/.kvs-import-source")" = "$(readlink -f "$source")" ] || fail "the copy must record its source"

    echo "changed" > "$source/contents/videos/2.mp4"
    output=$(import_place_site "$source" "$destination") || fail "a copy of the same source must be resumable"
    grep -q "Resuming" <<< "$output" || fail "the resumed copy must be reported: $output"
    [ -f "$destination/contents/videos/2.mp4" ] || fail "the resumed copy must bring the new files"

    rm "$destination/.kvs-import-source"
    output=$(import_place_site "$source" "$destination" 2>&1) && fail "a non-empty destination without the marker must be refused"
    grep -q "not empty" <<< "$output" || fail "the refusal must explain: $output"

    make_site "$TMP_ROOT/place-other" /home/other/www
    readlink -f "$TMP_ROOT/place-other" > "$destination/.kvs-import-source"
    output=$(import_place_site "$source" "$destination" 2>&1) && fail "a copy of another source must be refused"
    readlink -f "$source" > "$destination/.kvs-import-source"

    output=$(import_place_site "$destination" "$destination") || fail "the destination itself must be accepted as source"
    grep -q "already in place" <<< "$output" || fail "an in-place import must be reported: $output"

    ln -s "$destination" "$TMP_ROOT/place-link"
    output=$(import_place_site "$destination" "$TMP_ROOT/place-link") || fail "a symlink to the destination must be accepted"
    grep -q "already in place" <<< "$output" || fail "a symlinked destination must count as in place: $output"

    mkdir -p "$TMP_ROOT/place-empty"
    import_place_site "$source" "$TMP_ROOT/place-empty" >/dev/null || fail "an empty destination directory must be accepted"
    [ -f "$TMP_ROOT/place-empty/admin/include/setup.php" ] || fail "the files must land in the empty directory"
    pass "site placement copies once and refuses a used directory"
}

test_free_space_check_uses_the_nearest_existing_parent() {
    local source="$TMP_ROOT/space-source"
    make_site "$source" /home/old/www
    import_free_space_ok "$source" "$TMP_ROOT/absent/deeper/site" || fail "a small site must fit next to the temp directory"
    (
        # shellcheck disable=SC2329  # Stub consumed by the extracted function.
        df() { echo "Filesystem 1M-blocks Used Available Capacity Mounted on"; echo "fs 1 1 0 100% /"; }
        import_free_space_ok "$source" "$TMP_ROOT/absent"
    ) && fail "a full filesystem must fail the check"
    pass "free space check uses the nearest existing parent"
}

test_setup_and_init_are_wired_for_imports() {
    local setup="$REPO_ROOT/docker/setup.sh"
    local configure="$REPO_ROOT/docker/init/docker-entrypoint.d/40-configure-database.sh"
    local settings="$REPO_ROOT/docker/init/docker-entrypoint.d/70-system-settings.sh"
    local config_php="$REPO_ROOT/docker/init/docker-entrypoint.d/10-config-php.sh"

    grep -Fq 'IMPORT_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/import.sh"' "$setup" || fail "setup.sh must locate lib/import.sh next to itself"
    grep -Fq 'if [ -f "$IMPORT_LIB" ]; then' "$setup" || fail "a copy of setup.sh without the library must still install a fresh site"
    grep -Fq 'declare -F import_validate_site' "$setup" || fail "an import without the library must stop with an explanation"
    grep -Fq 'Import an existing KVS site (experimental)' "$setup" || fail "the import must be labelled experimental"
    grep -Fq 'IMPORT_SITE_DIR=DIR' "$setup" || fail "the usage must document IMPORT_SITE_DIR"
    grep -Fq 'IMPORT_SITE_DIR and IMPORT_DB_DUMP must be set together' "$setup" || fail "the two inputs must be required together"
    for step in prepare_import import_require_empty_volume import_stage_dump import_place_site_files import_verify_database import_finish; do
        grep -Eq "^${step}$|^    ${step}$|^${step}\$" "$setup" || grep -Eq "^\s*${step}(\s|$)" "$setup" || fail "setup.sh must call $step"
    done
    grep -Fq 'KVS_IMPORT_COMPLETED' "$setup" || fail "a completed import must be recorded in .env"
    grep -Fq "SELECT value FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';" "$setup" || fail "the completion marker must be verified before the KVS init"
    grep -Fq 'MARIADB_WAIT_SECONDS=${MARIADB_WAIT_SECONDS:-3600}' "$setup" || fail "an import must wait for the dump replay"
    grep -Fq '{{.RestartCount}} {{.State.Status}}' "$setup" || fail "a restarted MariaDB container must be reported"
    grep -Fq 'run_root_mariadb -u root -h 127.0.0.1 --protocol=tcp -e "SELECT 1"' "$setup" || fail "the readiness probe must use TCP, the socket answers during the init replay"
    grep -Fq 'rm -f "/var/www/$DOMAIN/.kvs-import-source"' "$setup" || fail "the copy marker must go once the import completed"
    grep -Fq 'rm -f mariadb/init/*kvs-import*' "$setup" || fail "stale staged dumps must be removed before staging"

    grep -Fq "'^https?://(www[.])?\${DOMAIN_PATTERN}(:[0-9]+)?/contents/'" "$configure" || fail "http storage URLs must be adopted too"
    grep -Fq 'Storage servers use external hosts' "$configure" || fail "external storage hosts must be tolerated"
    grep -Fq "GEOIP_UPDATE_CLAUSE=\", '\\\$.geoip_database', '\$GEOIP_DB'\"" "$settings" || fail "the GeoIP path must always follow the container"
    grep -Fq "ffmpeg path:" "$config_php" || fail "an ffmpeg path from another server must be replaced"
    grep -Fq 'docker/mariadb/init/*kvs-import*' "$REPO_ROOT/.gitignore" || fail "staged dumps must be ignored by git"
    pass "setup and init are wired for imports"
}

test_php_config_values_are_read_as_kvs_writes_them
test_site_validation_accepts_a_kvs_site_and_refuses_the_rest
test_archive_version_is_read_from_the_zip
test_dump_inspection_counts_tables_and_finds_the_markers
test_prepared_dump_loads_into_the_container_database
test_sql_escaping_survives_quotes_and_like_wildcards
test_site_placement_copies_once_and_refuses_a_used_directory
test_free_space_check_uses_the_nearest_existing_parent
test_setup_and_init_are_wired_for_imports

echo "All $TESTS_RUN import tests passed."
