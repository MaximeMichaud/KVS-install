#!/bin/bash
# kvs-export.sh, the exporter that runs on the old server, against fixtures
# and stub database tools. Nothing here reaches a real database: the stubs
# record how they were called and answer with canned output, which is also
# how the password handling is verified.
# shellcheck disable=SC2016  # Fixture content holds literal dollar signs.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXPORT_SCRIPT="$REPO_ROOT/kvs-export.sh"
TMP_ROOT=$(mktemp -d /tmp/kvs-export-test.XXXXXX)
TESTS_RUN=0

STUB_BIN="$TMP_ROOT/bin-stub"
MIN_BIN="$TMP_ROOT/bin-minimal"
EXTRA_BIN="$TMP_ROOT/bin-extra"
STUB_LOG="$TMP_ROOT/stub.log"
export STUB_LOG
# Keep the staging directory of the archive inside the fixtures.
export TMPDIR="$TMP_ROOT"

# The password as PHP writes it in setup_db.php, and the string it stands
# for: a quote and a backslash are the two characters PHP escapes there.
PHP_PASSWORD_LITERAL="it\\'s\\\\ok"
REAL_PASSWORD="it's\\ok"

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

#################################################################
# Fixtures
#################################################################

make_setup_db() {
    local file="$1"
    local host="$2"
    local password="$3"

    {
        echo '<?php'
        printf "define('DB_HOST','%s');\n" "$host"
        printf "define('DB_LOGIN','kvs');\n"
        printf "define('DB_PASS','%s');\n" "$password"
        printf "define('DB_DEVICE','oldsite');\n"
    } > "$file"
}

make_site() {
    local dir="$1"
    local url="${2:-https://www.example.com/}"
    local host="${3:-localhost}"
    local password="${4-$PHP_PASSWORD_LITERAL}"

    mkdir -p "$dir/admin/include" "$dir/contents/videos"
    cat > "$dir/admin/include/setup.php" <<EOF
<?php
\$config['project_path']="$dir";
\$config['project_url']="$url";
\$config['ffmpeg_path']="/usr/bin/ffmpeg";
\$config['tables_prefix']="ktvs_";
EOF
    printf '<?php\n/* Developed by Kernel Team. */\n$config['"'"'project_version'"'"'] = "7.0.2";\n' \
        > "$dir/admin/include/version.php"
    make_setup_db "$dir/admin/include/setup_db.php" "$host" "$password"
    echo "video" > "$dir/contents/videos/1.mp4"
}

# The stub client and dump tool: they log their argv and the password they
# were handed, so a test can prove the password travelled in the
# environment and never on the command line.
make_stubs() {
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/mariadb" <<'EOF'
#!/bin/bash
{
    printf 'mariadb argv:'
    printf ' [%s]' "$@"
    printf '\n'
    printf 'mariadb env: MYSQL_PWD=[%s]\n' "${MYSQL_PWD-}"
    printf 'mariadb env: HOME=[%s] MYSQL_HOME=[%s]\n' "${HOME-}" "${MYSQL_HOME-}"
} >> "${STUB_LOG:-/dev/null}"
if [ "${STUB_DB_FAIL:-no}" = yes ]; then
    echo "ERROR 2002 (HY000): Can't connect to local server through socket '/run/mysqld/mysqld.sock' (2)" >&2
    exit 1
fi
printf '11.8.2-MariaDB\t127\t45\t%s\n' "${STUB_NON_TRANSACTIONAL:-0}"
EOF
    cat > "$STUB_BIN/mariadb-dump" <<'EOF'
#!/bin/bash
{
    printf 'mariadb-dump argv:'
    printf ' [%s]' "$@"
    printf '\n'
    printf 'mariadb-dump env: MYSQL_PWD=[%s]\n' "${MYSQL_PWD-}"
    printf 'mariadb-dump env: HOME=[%s] MYSQL_HOME=[%s]\n' "${HOME-}" "${MYSQL_HOME-}"
} >> "${STUB_LOG:-/dev/null}"
for arg in "$@"; do
    case "$arg" in
        --connect-timeout*)
            # The real tool refuses the client's option (seen on MariaDB 11.8).
            echo "mariadb-dump: unknown variable '${arg#--}'" >&2
            exit 7
            ;;
    esac
    if [ "$arg" = "--help" ]; then
        printf 'Usage: mariadb-dump [OPTIONS] database [tables]\n'
        printf '  --single-transaction\n'
        if [ "${STUB_DUMP_COLUMN_STATISTICS:-no}" = yes ]; then
            printf '  --column-statistics=0\n'
        fi
        if [ "${STUB_DUMP_GTID:-no}" = yes ]; then
            printf '  --set-gtid-purged=name\n'
        fi
        exit 0
    fi
done
if [ "${STUB_DB_FAIL:-no}" = yes ]; then
    echo "mariadb-dump: Got error: 2002: Can't connect to local server" >&2
    exit 2
fi
printf -- '-- MariaDB dump 10.19\n'
printf 'CREATE TABLE `ktvs_options` (`variable` varchar(255) NOT NULL, `value` text NOT NULL, PRIMARY KEY (`variable`));\n'
printf "INSERT INTO \`ktvs_options\` VALUES ('INITIAL_VERSION','7.0.2');\n"
printf -- '-- Dump completed\n'
EOF
    # df answers a full filesystem on demand, and defers to the real one
    # otherwise so the free space check is exercised for real everywhere else.
    cat > "$STUB_BIN/df" <<EOF
#!/bin/bash
if [ "\${STUB_DF_FULL:-no}" = yes ]; then
    echo "Filesystem 1M-blocks Used Available Capacity Mounted on"
    echo "/dev/stub 1000 999 1 100% /"
    exit 0
fi
exec "$(command -v df)" "\$@"
EOF
    # du logs how the site is measured and answers a fixed size.
    cat > "$STUB_BIN/du" <<'EOF'
#!/bin/bash
{
    printf 'du argv:'
    printf ' [%s]' "$@"
    printf '\n'
} >> "${STUB_LOG:-/dev/null}"
printf '77\t%s\n' "${*: -1}"
EOF
    chmod +x "$STUB_BIN/mariadb" "$STUB_BIN/mariadb-dump" "$STUB_BIN/df" "$STUB_BIN/du"
}

# A PATH without zstd and without pigz cannot be built by pruning the real
# one, so it is built from symlinks to the tools the exporter may use.
make_min_bin() {
    local tool path

    mkdir -p "$MIN_BIN"
    for tool in sed find readlink du df date mktemp rm mkdir ln tar wc uname gzip cat; do
        path=$(command -v "$tool" 2> /dev/null) || continue
        ln -sf "$path" "$MIN_BIN/$tool"
    done
    [ -x "$MIN_BIN/gzip" ] || fail "the test needs gzip"
}

# zstd and rsync stubs: the compressor choice must not depend on what the
# machine running the tests happens to have installed.
make_extra_bin() {
    mkdir -p "$EXTRA_BIN"
    cat > "$EXTRA_BIN/zstd" <<'EOF'
#!/bin/bash
{
    printf 'zstd argv:'
    printf ' [%s]' "$@"
    printf '\n'
} >> "${STUB_LOG:-/dev/null}"
exec cat
EOF
    cat > "$EXTRA_BIN/rsync" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$EXTRA_BIN/zstd" "$EXTRA_BIN/rsync"
}

#################################################################
# Running the exporter
#################################################################

# run_export <PATH> <stdout file> <stderr file> [arguments...]
run_export() {
    local path_value="$1"
    local out="$2"
    local err="$3"
    local status=0

    shift 3
    : > "$STUB_LOG"
    PATH="$path_value" "$BASH" "$EXPORT_SCRIPT" "$@" > "$out" 2> "$err" < /dev/null || status=$?
    return "$status"
}

detect_value() {
    local file="$1"
    local key="$2"
    local line

    while IFS= read -r line; do
        case $line in
            "$key="*)
                printf '%s' "${line#*=}"
                return 0
                ;;
        esac
    done < "$file"
    return 1
}

assert_key() {
    local file="$1"
    local key="$2"
    local expected="$3"
    local got

    got=$(detect_value "$file" "$key") || fail "$key is missing from the detect output"
    [ "$got" = "$expected" ] || fail "$key must be '$expected', got '$got'"
}

argv_lines() {
    grep -- ' argv:' "$STUB_LOG" || true
}

#################################################################
# Tests
#################################################################

test_detect_reports_the_installation_as_key_value_lines() {
    local site="$TMP_ROOT/detect-site"
    local out="$TMP_ROOT/detect.out"
    local err="$TMP_ROOT/detect.err"
    local line

    make_site "$site"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" ||
        fail "detect must succeed on a KVS site"

    while IFS= read -r line; do
        [[ $line =~ ^[a-z_0-9]+= ]] || fail "detect may only print key=value lines, got '$line'"
    done < "$out"

    assert_key "$out" kvs_export 1
    assert_key "$out" site_dir "$site"
    assert_key "$out" kvs_version 7.0.2
    assert_key "$out" project_url "https://www.example.com/"
    assert_key "$out" domain example.com
    assert_key "$out" project_path "$site"
    assert_key "$out" tables_prefix ktvs_
    assert_key "$out" db_host localhost
    assert_key "$out" db_name oldsite
    assert_key "$out" db_user kvs
    assert_key "$out" db_client mariadb
    assert_key "$out" db_dump_tool mariadb-dump
    assert_key "$out" db_ok yes
    assert_key "$out" db_server_version 11.8.2-MariaDB
    assert_key "$out" db_tables 127
    assert_key "$out" db_size_mb 45
    assert_key "$out" compressor gzip
    assert_key "$out" rsync no
    detect_value "$out" db_error > /dev/null && fail "a reachable database must print no db_error"
    [ -n "$(detect_value "$out" hostname)" ] || fail "the hostname must be reported"
    assert_key "$out" site_size_mb 77
    grep -q '^du argv: \[-sLm\]' "$STUB_LOG" || fail "the site must be measured through its symbolic links (du -sLm)"
    grep -q "Measuring the site size" "$err" || fail "the size measurement must be announced on stderr"
    pass "detect reports the installation as key=value lines"
}

test_the_password_reaches_the_client_only_through_the_environment() {
    local site="$TMP_ROOT/password-site"
    local out="$TMP_ROOT/password.out"
    local err="$TMP_ROOT/password.err"

    make_site "$site"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "detect must succeed"

    grep -Fq "env: MYSQL_PWD=[$REAL_PASSWORD]" "$STUB_LOG" ||
        fail "the unescaped password must reach the client through MYSQL_PWD: $(cat "$STUB_LOG")"
    argv_lines | grep -Fq "$REAL_PASSWORD" && fail "the password must never appear in the argv"
    argv_lines | grep -Fq "$PHP_PASSWORD_LITERAL" && fail "the escaped password must never appear in the argv either"
    assert_key "$out" db_password_hint "it********"

    make_site "$TMP_ROOT/password-short" "https://short.example.com" localhost "abc"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$TMP_ROOT/password-short" || fail "detect must succeed"
    assert_key "$out" db_password_hint "********"
    grep -Fq "env: MYSQL_PWD=[abc]" "$STUB_LOG" || fail "a short password must still be handed over"

    make_site "$TMP_ROOT/password-empty" "https://empty.example.com" localhost ""
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$TMP_ROOT/password-empty" || fail "detect must succeed"
    assert_key "$out" db_password_hint ""
    pass "the password reaches the client only through the environment"
}

test_the_connection_follows_the_host_written_in_setup_db() {
    local out="$TMP_ROOT/host.out"
    local err="$TMP_ROOT/host.err"

    make_site "$TMP_ROOT/host-local" "https://a.example.com" "localhost"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$TMP_ROOT/host-local" || fail "detect must succeed"
    argv_lines | grep -Fq -- '[-h]' && fail "localhost must use the socket the client defaults to"
    argv_lines | grep -Fq -- '[--connect-timeout=10]' || fail "the client must be given a connect timeout"
    argv_lines | grep -Fq -- '[-u] [kvs]' || fail "the database user must be passed"

    make_site "$TMP_ROOT/host-port" "https://b.example.com" "db.example.com:3307"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$TMP_ROOT/host-port" || fail "detect must succeed"
    argv_lines | grep -Fq -- '[-h] [db.example.com] [-P] [3307]' ||
        fail "host:port must split into -h and -P: $(argv_lines)"
    assert_key "$out" db_host "db.example.com:3307"

    # PHP reaches localhost:3307 over TCP, while the clients take the
    # host name localhost as the socket and ignore the port unless TCP is
    # requested: the dump would come from the default instance.
    make_site "$TMP_ROOT/host-local-port" "https://e.example.com" "localhost:3307"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$TMP_ROOT/host-local-port" || fail "detect must succeed"
    argv_lines | grep -Fq -- '[--protocol=tcp] [-h] [localhost] [-P] [3307]' ||
        fail "localhost:port must force TCP on the port: $(argv_lines)"

    make_site "$TMP_ROOT/host-socket" "https://c.example.com" "localhost:/run/mysqld/mysqld.sock"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$TMP_ROOT/host-socket" || fail "detect must succeed"
    argv_lines | grep -Fq -- '[-S] [/run/mysqld/mysqld.sock]' ||
        fail "host:/path must become a socket: $(argv_lines)"

    make_site "$TMP_ROOT/host-remote" "https://d.example.com" "db.example.com"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$TMP_ROOT/host-remote" || fail "detect must succeed"
    argv_lines | grep -Fq -- '[-h] [db.example.com]' || fail "a bare host must be passed with -h"
    pass "the connection follows the host written in setup_db.php"
}

test_an_unreachable_database_is_reported_without_stopping_detect() {
    local site="$TMP_ROOT/unreachable-site"
    local out="$TMP_ROOT/unreachable.out"
    local err="$TMP_ROOT/unreachable.err"
    local status=0
    local message

    make_site "$site"
    export STUB_DB_FAIL=yes
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || status=$?
    [ "$status" -eq 0 ] || fail "detect must still exit 0 when the database is unreachable, got $status"
    assert_key "$out" db_ok no
    message=$(detect_value "$out" db_error) || fail "db_error must be printed"
    case $message in
        *2002*) ;;
        *) fail "db_error must carry the client message, got '$message'" ;;
    esac
    case $message in
        *$'\n'*) fail "db_error must stay on one line" ;;
    esac

    status=0
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" || status=$?
    [ "$status" -eq 3 ] || fail "dump must exit 3 when the database is unreachable, got $status"
    [ ! -s "$out" ] || fail "a failed dump must print nothing on stdout"
    unset STUB_DB_FAIL
    pass "an unreachable database is reported without stopping detect"
}

test_the_dump_uses_the_compressor_that_is_installed() {
    local site="$TMP_ROOT/compressor-site"
    local out="$TMP_ROOT/compressor.out"
    local err="$TMP_ROOT/compressor.err"
    local plain

    make_site "$site"

    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" || fail "the dump must succeed"
    [ -s "$out" ] || fail "the dump must land on stdout"
    plain=$(gzip -dc < "$out") || fail "without zstd the dump must be gzip compressed"
    grep -Fq 'CREATE TABLE `ktvs_options`' <<< "$plain" || fail "the dump must carry the tables"
    grep -Fq -- '-- Dump completed' <<< "$plain" || fail "the dump must carry the completion line"
    argv_lines | grep -Fq -- '[--single-transaction]' || fail "the dump needs --single-transaction"
    argv_lines | grep -Fq -- '[--quick]' || fail "the dump needs --quick"
    argv_lines | grep -Fq -- '[--hex-blob]' || fail "the dump needs --hex-blob"
    argv_lines | grep -Fq -- '[--triggers]' || fail "the dump needs --triggers"
    argv_lines | grep -Fq -- '[--default-character-set=utf8mb4]' || fail "the dump needs the utf8mb4 charset"
    argv_lines | grep -Fq -- '[--no-tablespaces]' || fail "the dump needs --no-tablespaces"
    argv_lines | grep -Fq -- '[--max-allowed-packet=512M]' || fail "the dump needs a large packet size"
    argv_lines | grep -Fq -- '[oldsite]' || fail "the database name must be the last argument"
    argv_lines | grep -Fq -- '[--routines]' && fail "--routines must not be used"
    argv_lines | grep -Fq -- '[--databases]' && fail "--databases must not be used"
    grep -Fq "env: MYSQL_PWD=[$REAL_PASSWORD]" "$STUB_LOG" || fail "the dump tool must get the password from the environment"
    # A password in root's .my.cnf beats MYSQL_PWD, so the clients must not
    # see the caller's home nor MYSQL_HOME (case 1045 on a box with .my.cnf).
    grep -Fq "mariadb-dump env: HOME=[/nonexistent] MYSQL_HOME=[]" "$STUB_LOG" ||
        fail "the dump tool must run without the user option files (HOME, MYSQL_HOME)"
    grep -Fq "mariadb env: HOME=[/nonexistent] MYSQL_HOME=[]" "$STUB_LOG" ||
        fail "the probe must run without the user option files (HOME, MYSQL_HOME)"
    argv_lines | grep -Fq "$REAL_PASSWORD" && fail "the password must never appear in the dump argv"

    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "detect must succeed"
    assert_key "$out" compressor gzip

    run_export "$EXTRA_BIN:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "detect must succeed"
    assert_key "$out" compressor zstd
    assert_key "$out" rsync yes

    run_export "$EXTRA_BIN:$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" || fail "the dump must succeed"
    argv_lines | grep -Fq -- 'zstd argv: [-T0] [-3] [-q] [-c]' ||
        fail "zstd must be called with the streaming options: $(argv_lines)"
    grep -Fq -- '-- Dump completed' "$out" || fail "the stub compressor passes the dump through unchanged"

    run_export "$EXTRA_BIN:$STUB_BIN:$MIN_BIN" "$out" "$err" --gzip detect "$site" || fail "detect must succeed"
    assert_key "$out" compressor gzip
    pass "the dump uses the compressor that is installed"
}

test_column_statistics_is_passed_only_to_a_tool_that_knows_it() {
    local site="$TMP_ROOT/column-site"
    local out="$TMP_ROOT/column.out"
    local err="$TMP_ROOT/column.err"

    make_site "$site"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" || fail "the dump must succeed"
    argv_lines | grep -Fq -- '[--column-statistics=0]' &&
        fail "a tool without column statistics must not be given the option"

    export STUB_DUMP_COLUMN_STATISTICS=yes
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" || fail "the dump must succeed"
    argv_lines | grep -Fq -- '[--column-statistics=0]' ||
        fail "a tool that advertises column statistics must be told to skip them"
    unset STUB_DUMP_COLUMN_STATISTICS
    pass "column statistics is passed only to a tool that knows it"
}

test_gtid_state_is_left_out_by_a_tool_that_records_it() {
    local site="$TMP_ROOT/gtid-site"
    local out="$TMP_ROOT/gtid.out"
    local err="$TMP_ROOT/gtid.err"

    make_site "$site"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" || fail "the dump must succeed"
    argv_lines | grep -Fq -- '[--set-gtid-purged=OFF]' &&
        fail "a tool without the GTID option must not be given it"

    export STUB_DUMP_GTID=yes
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" || fail "the dump must succeed"
    argv_lines | grep -Fq -- '[--set-gtid-purged=OFF]' ||
        fail "a tool that records the GTID state must be told not to"
    unset STUB_DUMP_GTID
    pass "GTID state is left out by a tool that records it"
}

test_non_transactional_tables_switch_the_dump_to_table_locks() {
    local site="$TMP_ROOT/engine-site"
    local out="$TMP_ROOT/engine.out"
    local err="$TMP_ROOT/engine.err"

    make_site "$site"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "detect must succeed"
    assert_key "$out" db_non_transactional 0
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" || fail "the dump must succeed"
    argv_lines | grep -Fq -- '[--single-transaction]' || fail "InnoDB tables are dumped in one transaction"
    argv_lines | grep -Fq -- '[--lock-tables]' && fail "no table lock when every table is transactional"

    export STUB_NON_TRANSACTIONAL=3
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "detect must succeed"
    assert_key "$out" db_non_transactional 3
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" || fail "the dump must succeed"
    argv_lines | grep -Fq -- '[--lock-tables]' || fail "MyISAM or Aria tables need a table lock"
    argv_lines | grep -Fq -- '[--single-transaction]' && fail "the transaction option is useless with a table lock"
    grep -q '3 tables use MyISAM or Aria' "$err" || fail "the lock must be announced"
    unset STUB_NON_TRANSACTIONAL
    pass "non transactional tables switch the dump to table locks"
}

test_the_mysql_tools_are_used_when_the_mariadb_ones_are_absent() {
    local site="$TMP_ROOT/mysql-site"
    local bin="$TMP_ROOT/bin-mysql"
    local out="$TMP_ROOT/mysql.out"
    local err="$TMP_ROOT/mysql.err"

    make_site "$site"
    mkdir -p "$bin"
    cp "$STUB_BIN/mariadb" "$bin/mysql"
    cp "$STUB_BIN/mariadb-dump" "$bin/mysqldump"
    cp "$STUB_BIN/df" "$bin/df"

    run_export "$bin:$MIN_BIN" "$out" "$err" detect "$site" || fail "detect must work with the mysql tools"
    assert_key "$out" db_client mysql
    assert_key "$out" db_dump_tool mysqldump
    assert_key "$out" db_ok yes

    run_export "$bin:$MIN_BIN" "$out" "$err" dump "$site" || fail "the dump must work with mysqldump"
    gzip -dc < "$out" | grep -Fq -- '-- Dump completed' || fail "mysqldump must produce the dump"
    pass "the mysql tools are used when the mariadb ones are absent"
}

test_the_archive_holds_the_site_the_dump_and_the_manifest() {
    local site="$TMP_ROOT/archive-site"
    local archive="$TMP_ROOT/export.tar"
    local out="$TMP_ROOT/archive.out"
    local err="$TMP_ROOT/archive.err"
    local manifest="$TMP_ROOT/manifest.read"
    local listing

    make_site "$site"
    # A contents directory that lives on another disk must travel with the
    # site, which is what the dereferencing tar is for.
    rm -rf "$site/contents"
    mkdir -p "$TMP_ROOT/other-disk/videos"
    echo "elsewhere" > "$TMP_ROOT/other-disk/videos/2.mp4"
    ln -s "$TMP_ROOT/other-disk" "$site/contents"

    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" -y -o "$archive" archive "$site" ||
        fail "the archive must be written: $(cat "$err")"
    [ -s "$archive" ] || fail "the archive must not be empty"
    [ ! -s "$out" ] || fail "an archive written to a path must print nothing on stdout"

    listing=$(tar -tf "$archive")
    grep -Fxq "www/admin/include/setup.php" <<< "$listing" || fail "the site files must be under www/: $listing"
    grep -Fxq "www/contents/videos/2.mp4" <<< "$listing" || fail "a symlinked contents directory must be archived"
    grep -Fxq "database.sql.gz" <<< "$listing" || fail "the dump must be in the archive: $listing"
    grep -Fxq "kvs-export.manifest" <<< "$listing" || fail "the manifest must be in the archive: $listing"
    tar -tvf "$archive" | grep -E '^d.* www/$' > /dev/null ||
        fail "www must be archived as a directory, not as a symlink"

    tar -xOf "$archive" kvs-export.manifest > "$manifest"
    assert_key "$manifest" format 1
    assert_key "$manifest" site www
    assert_key "$manifest" dump database.sql.gz
    assert_key "$manifest" kvs_export 1
    assert_key "$manifest" kvs_version 7.0.2
    assert_key "$manifest" domain example.com
    assert_key "$manifest" db_name oldsite
    [ "$(detect_value "$manifest" dump_bytes)" -gt 0 ] || fail "the manifest must record the dump size"
    [[ $(detect_value "$manifest" created) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
        fail "the manifest must record a UTC creation time"

    tar -xOf "$archive" database.sql.gz | gzip -dc | grep -Fq 'CREATE TABLE `ktvs_options`' ||
        fail "the archived dump must hold the tables"
    grep -q "Archive written: $archive" "$err" || fail "the archive path must be reported: $(cat "$err")"
    grep -q "IMPORT_ARCHIVE=" "$err" || fail "the next step must be explained"
    pass "the archive holds the site, the dump and the manifest"
}

test_the_archive_can_be_written_on_stdout() {
    local site="$TMP_ROOT/stdout-site"
    local out="$TMP_ROOT/stdout.tar"
    local err="$TMP_ROOT/stdout.err"
    local listing

    make_site "$site"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" -y -o - archive "$site" ||
        fail "the archive must be written on stdout: $(cat "$err")"
    listing=$(tar -tf "$out")
    grep -Fxq "www/admin/include/setup.php" <<< "$listing" || fail "the site must be in the archive on stdout"
    grep -Fxq "kvs-export.manifest" <<< "$listing" || fail "the manifest must be in the archive on stdout"
    pass "the archive can be written on stdout"
}

test_dump_only_writes_a_dump_next_to_the_archive() {
    local site="$TMP_ROOT/dumponly-site"
    local work="$TMP_ROOT/dumponly-work"
    local out="$TMP_ROOT/dumponly.out"
    local err="$TMP_ROOT/dumponly.err"
    local produced
    local status=0

    make_site "$site"
    mkdir -p "$work"
    : > "$STUB_LOG"
    (
        cd "$work" &&
            PATH="$STUB_BIN:$MIN_BIN" "$BASH" "$EXPORT_SCRIPT" -y --dump-only "$site" \
                > "$out" 2> "$err" < /dev/null
    ) || status=$?
    [ "$status" -eq 0 ] || fail "--dump-only must succeed: $(cat "$err")"
    produced=$(find "$work" -maxdepth 1 -type f -name 'example.com-kvs-export-*.sql.gz')
    [ -n "$produced" ] || fail "the dump must be named after the domain and the date: $(find "$work")"
    gzip -dc < "$produced" | grep -Fq 'CREATE TABLE `ktvs_options`' || fail "the dump must hold the tables"
    [ ! -s "$out" ] || fail "--dump-only into a file must print nothing on stdout"
    find "$work" -maxdepth 1 -name '*.tar' | grep -q . && fail "--dump-only must not write an archive"

    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" -y --dump-only -o - "$site" ||
        fail "--dump-only with -o - must succeed"
    gzip -dc < "$out" | grep -Fq -- '-- Dump completed' || fail "the dump must reach stdout with -o -"
    pass "--dump-only writes a dump next to the archive"
}

test_the_site_is_searched_under_the_configured_roots() {
    local roots="$TMP_ROOT/roots"
    local out="$TMP_ROOT/search.out"
    local err="$TMP_ROOT/search.err"
    local status=0
    local line

    mkdir -p "$roots/empty-root"
    make_site "$roots/first/example.com"
    # A copy of a site inside a contents directory must not be found: that
    # tree holds the media files and is pruned.
    mkdir -p "$roots/first/example.com/contents/backup/admin/include"
    cp "$roots/first/example.com/admin/include/setup.php" \
        "$roots/first/example.com/contents/backup/admin/include/setup.php"

    KVS_EXPORT_SEARCH_ROOTS="$roots/first:$roots/missing" \
        run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect ||
        fail "a single site under the roots must be used: $(cat "$err")"
    assert_key "$out" site_dir "$roots/first/example.com"

    make_site "$roots/first/other.example.com" "https://other.example.com"
    status=0
    KVS_EXPORT_SEARCH_ROOTS="$roots/first" \
        run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect || status=$?
    [ "$status" -eq 2 ] || fail "several sites must exit 2, got $status"
    grep -q '^site_candidate_1=' "$out" || fail "the candidates must be listed on stdout: $(cat "$out")"
    grep -q '^site_candidate_2=' "$out" || fail "both candidates must be listed: $(cat "$out")"
    while IFS= read -r line; do
        [[ $line =~ ^[a-z_0-9]+= ]] || fail "the candidate output must stay key=value, got '$line'"
    done < "$out"

    status=0
    KVS_EXPORT_SEARCH_ROOTS="$roots/empty-root" \
        run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect || status=$?
    [ "$status" -eq 2 ] || fail "no site must exit 2, got $status"
    grep -q "no KVS site found" "$err" || fail "the failed search must be explained: $(cat "$err")"

    status=0
    KVS_EXPORT_SEARCH_ROOTS="$roots/first" \
        run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" archive || status=$?
    [ "$status" -eq 2 ] || fail "the archive command must exit 2 on an ambiguous search, got $status"
    grep -q "several KVS sites found" "$err" || fail "the ambiguity must be explained on stderr"
    grep -Fq "$roots/first/other.example.com" "$err" || fail "the candidates must be listed on stderr"
    unset KVS_EXPORT_SEARCH_ROOTS
    pass "the site is searched under the configured roots"
}

test_a_site_without_its_config_files_is_refused() {
    local site="$TMP_ROOT/broken-site"
    local out="$TMP_ROOT/broken.out"
    local err="$TMP_ROOT/broken.err"
    local status=0

    make_site "$site"
    rm "$site/admin/include/setup_db.php"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || status=$?
    [ "$status" -eq 1 ] || fail "a site without setup_db.php must exit 1, got $status"
    grep -q "setup_db.php is missing" "$err" || fail "the missing file must be named: $(cat "$err")"

    make_site "$TMP_ROOT/broken-version"
    rm "$TMP_ROOT/broken-version/admin/include/version.php"
    status=0
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$TMP_ROOT/broken-version" || status=$?
    [ "$status" -eq 1 ] || fail "a site without version.php must exit 1, got $status"

    mkdir -p "$TMP_ROOT/not-a-site"
    status=0
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$TMP_ROOT/not-a-site" || status=$?
    [ "$status" -eq 1 ] || fail "a directory without setup.php must exit 1, got $status"
    grep -q "holds no KVS site" "$err" || fail "the refusal must explain: $(cat "$err")"

    status=0
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$TMP_ROOT/absent" || status=$?
    [ "$status" -eq 1 ] || fail "a missing directory must exit 1, got $status"
    pass "a site without its config files is refused"
}

test_the_script_works_when_bash_reads_it_from_stdin() {
    local site="$TMP_ROOT/stdin-site"
    local out="$TMP_ROOT/stdin.out"
    local err="$TMP_ROOT/stdin.err"
    local status=0

    make_site "$site"
    : > "$STUB_LOG"
    PATH="$STUB_BIN:$MIN_BIN" "$BASH" -s -- detect "$site" \
        < "$EXPORT_SCRIPT" > "$out" 2> "$err" || status=$?
    [ "$status" -eq 0 ] || fail "the script must run when bash reads it from stdin: $(cat "$err")"
    assert_key "$out" kvs_export 1
    assert_key "$out" site_dir "$site"
    assert_key "$out" db_ok yes
    [ "$(wc -l < "$out")" -ge 20 ] || fail "the whole detect output must be printed, got $(cat "$out")"

    status=0
    : > "$STUB_LOG"
    PATH="$STUB_BIN:$MIN_BIN" "$BASH" -s -- dump "$site" \
        < "$EXPORT_SCRIPT" > "$out" 2> "$err" || status=$?
    [ "$status" -eq 0 ] || fail "the dump must run from stdin too: $(cat "$err")"
    gzip -dc < "$out" | grep -Fq -- '-- Dump completed' || fail "the dump must be complete when read from stdin"
    pass "the script works when bash reads it from stdin"
}

test_an_unattended_run_asks_nothing() {
    local site="$TMP_ROOT/unattended-site"
    local archive="$TMP_ROOT/unattended.tar"
    local out="$TMP_ROOT/unattended.out"
    local err="$TMP_ROOT/unattended.err"

    make_site "$site"
    # No -y here: with no terminal on stdin and none on stderr the run must
    # go ahead instead of waiting for an answer nobody can give.
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" -o "$archive" archive "$site" ||
        fail "an unattended archive must not stop for a confirmation: $(cat "$err")"
    tar -tf "$archive" | grep -Fxq "kvs-export.manifest" || fail "the archive must be complete"
    grep -q "Installation detected on" "$err" || fail "the summary must be printed on stderr"
    grep -q "password it\*\*\*\*\*\*\*\*" "$err" || fail "the summary must mask the password: $(cat "$err")"
    grep -Fq "$REAL_PASSWORD" "$err" && fail "the summary must never print the password"
    pass "an unattended run asks nothing"
}

test_a_full_filesystem_stops_the_archive() {
    local site="$TMP_ROOT/space-site"
    local out="$TMP_ROOT/space.out"
    local err="$TMP_ROOT/space.err"
    local status=0

    make_site "$site"
    export STUB_DF_FULL=yes
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" -y -o "$TMP_ROOT/space.tar" archive "$site" || status=$?
    unset STUB_DF_FULL
    [ "$status" -eq 1 ] || fail "a full filesystem must stop the archive, got $status"
    grep -q "not enough free space" "$err" || fail "the refusal must explain: $(cat "$err")"
    [ ! -e "$TMP_ROOT/space.tar" ] || fail "nothing must be written when the space check fails"
    pass "a full filesystem stops the archive"
}

test_the_usage_is_available_and_bad_options_are_refused() {
    local out="$TMP_ROOT/usage.out"
    local err="$TMP_ROOT/usage.err"
    local status=0

    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --help || fail "--help must exit 0"
    grep -q "Usage: kvs-export.sh" "$out" || fail "--help must print the usage"
    grep -q -- "--dump-only" "$out" || fail "the usage must document --dump-only"

    status=0
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --nonsense || status=$?
    [ "$status" -eq 1 ] || fail "an unknown option must exit 1, got $status"
    grep -q "unknown option" "$err" || fail "the unknown option must be named"

    status=0
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" -o || status=$?
    [ "$status" -eq 1 ] || fail "an option without its value must exit 1, got $status"
    pass "the usage is available and bad options are refused"
}

make_stubs
make_min_bin
make_extra_bin

test_detect_reports_the_installation_as_key_value_lines
test_the_password_reaches_the_client_only_through_the_environment
test_the_connection_follows_the_host_written_in_setup_db
test_an_unreachable_database_is_reported_without_stopping_detect
test_the_dump_uses_the_compressor_that_is_installed
test_column_statistics_is_passed_only_to_a_tool_that_knows_it
test_gtid_state_is_left_out_by_a_tool_that_records_it
test_non_transactional_tables_switch_the_dump_to_table_locks
test_the_mysql_tools_are_used_when_the_mariadb_ones_are_absent
test_the_archive_holds_the_site_the_dump_and_the_manifest
test_the_archive_can_be_written_on_stdout
test_dump_only_writes_a_dump_next_to_the_archive
test_the_site_is_searched_under_the_configured_roots
test_a_site_without_its_config_files_is_refused
test_the_script_works_when_bash_reads_it_from_stdin
test_an_unattended_run_asks_nothing
test_a_full_filesystem_stops_the_archive
test_the_usage_is_available_and_bad_options_are_refused

echo "All $TESTS_RUN export tests passed."
