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
export STUB_NATIVE_DATADIR_HEX
STUB_NATIVE_DATADIR_HEX=$(printf '%s' "$TMP_ROOT" | od -An -tx1 | tr -d ' \n')
# The nginx probe looks for a binary and reads /etc/nginx otherwise; the
# tests point it at nothing unless they test it.
export KVS_EXPORT_NGINX_BIN="$TMP_ROOT/no-nginx"
export KVS_EXPORT_NGINX_ROOT="$TMP_ROOT/no-etc-nginx"

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
    printf 'mariadb argv:%s\n' "$(printf ' [%s]' "$@")"
    printf 'mariadb env: MYSQL_PWD=[%s]\n' "${MYSQL_PWD-}"
    printf 'mariadb env: HOME=[%s] MYSQL_HOME=[%s]\n' "${HOME-}" "${MYSQL_HOME-}"
} >> "${STUB_LOG:-/dev/null}"
if [ "${STUB_DB_FAIL:-no}" = yes ]; then
    echo "ERROR 2002 (HY000): Can't connect to local server through socket '/run/mysqld/mysqld.sock' (2)" >&2
    exit 1
fi
native_root=no
previous=''
for arg in "$@"; do
    if [ "$previous" = -u ] && [ "$arg" = root ]; then native_root=yes; fi
    previous=$arg
done
if [ "$native_root" = yes ]; then
    [[ "$1" = --no-defaults && " $* " == *' --protocol=socket '* && " $* " == *' --skip-password '* ]] || exit 95
    [ -z "${MYSQL_PWD:-}" ] || exit 96
    if [ "${STUB_NATIVE_ROOT_ACCESS:-no}" != yes ]; then
        printf '%s\n' 'ERROR 1045 (28000): Access denied for user root (using password: NO)' >&2
        exit 1
    fi
fi
for arg in "$@"; do
    case "$arg" in
        *"SELECT 'unsupported'"*)
            # Interpret the compatibility predicates against fixture metadata.
            # In particular, an old blanket GENERATED or FOREIGN KEY check
            # must report the positive fixture counts instead of canned zero.
            query=${arg,,}
            query=${query//[$' \t\r\n']/}
            for predicate in \
                "table_type<>'basetable'" \
                "enginenotin('innodb','myisam','aria')" \
                "create_optionslike'%systemversioning%'" \
                'frominformation_schema.triggerswheretrigger_schema=database()' \
                'frominformation_schema.routineswhereroutine_schema=database()' \
                'frominformation_schema.eventswhereevent_schema=database()' \
                "select'datadir',hex(@@datadir)" \
                "select'instance',concat_ws(':',hex(@@hostname),@@port,@@server_id,hex(@@socket),hex(@@datadir),hex(version()))" \
                "c.table_schema=database()andbinaryc.column_namenotregexp'^[a-za-z0-9_]{1,64}$'" \
                "g.table_schema=c.table_schemaandg.table_name=c.table_nameand(g.extralike'%generated%'" \
                "g.extralike'%auto_increment%'andnotexists(" \
                "p.index_name='primary'andp.seq_in_index=1andp.column_name=g.column_name" \
                'k.table_schema=database()andk.referenced_table_nameisnotnull' \
                "binaryk.constraint_namenotregexp'^[a-za-z0-9_]{1,64}$'" \
                "binaryk.column_namenotregexp'^[a-za-z0-9_]{1,64}$'" \
                "binaryk.referenced_column_namenotregexp'^[a-za-z0-9_]{1,64}$'"; do
                [[ "$query" == *"$predicate"* ]] || exit 91
            done
            unsupported=0
            details=''
            add_blocker() {
                [ "$2" -gt 0 ] || return 0
                unsupported=$((unsupported + $2))
                details+="${details:+, }$1=$2"
            }
            add_blocker events "${STUB_NATIVE_EVENTS:-0}"
            if [[ "$query" == *'frominformation_schema.key_column_usagewheretable_schema=database()andreferenced_table_schema<>database()'* ]]; then
                [[ "$query" == *'count(distincttable_name,constraint_name)'* ]] || exit 94
                add_blocker external_foreign_keys "${STUB_NATIVE_EXTERNAL_FKS:-0}"
            elif [[ "$query" == *"constraint_type='foreignkey'"* ]]; then
                add_blocker foreign_keys "$((${STUB_NATIVE_LOCAL_FKS:-0} + ${STUB_NATIVE_EXTERNAL_FKS:-0}))"
            else
                exit 92
            fi
            if [[ "$query" == *"extraregexp'generated|invisible'"* ]]; then
                add_blocker generated_or_invisible_columns "$((${STUB_NATIVE_GENERATED:-0} + ${STUB_NATIVE_INVISIBLE:-0}))"
            elif [[ "$query" == *"frominformation_schema.columnswheretable_schema=database()andextralike'%invisible%'"* ]]; then
                add_blocker invisible_columns "${STUB_NATIVE_INVISIBLE:-0}"
            else
                exit 93
            fi
            add_blocker nonstandard_tables "${STUB_NATIVE_NONSTANDARD:-0}"
            add_blocker routines "${STUB_NATIVE_ROUTINES:-0}"
            add_blocker triggers "${STUB_NATIVE_TRIGGERS:-0}"
            invalid_identifiers=0
            for identifier in "${STUB_NATIVE_GENERATED_TABLE_COLUMN:-value}" \
                "${STUB_NATIVE_SECONDARY_AI_COLUMN:-value}" \
                "${STUB_NATIVE_FK_CONSTRAINT:-fk_fixture}" \
                "${STUB_NATIVE_FK_COLUMN:-parent_id}" \
                "${STUB_NATIVE_FK_REF_COLUMN:-id}"; do
                [[ "$identifier" =~ ^[A-Za-z0-9_]{1,64}$ ]] || invalid_identifiers=$((invalid_identifiers + 1))
            done
            add_blocker unsupported_identifiers "$invalid_identifiers"
            if [ "$native_root" = yes ]; then
                add_blocker triggers "${STUB_NATIVE_ROOT_HIDDEN_TRIGGERS:-0}"
            fi
            printf 'unsupported\t%s\t%s\ncount\t1\ntable\tktvs_options\ndirectory\t%s\nsocket\t2F746D702F666978747572652E736F636B\ndatadir\t%s\n' \
                "${STUB_NATIVE_UNSUPPORTED:-$unsupported}" "$details" "${STUB_NATIVE_DIRECTORY_HEX:-}" "$STUB_NATIVE_DATADIR_HEX"
            instance=fixture
            if [ "$native_root" = yes ]; then instance=${STUB_NATIVE_ROOT_INSTANCE:-fixture}; fi
            printf 'instance\t%s\n' "$instance"
            exit 0
            ;;
        *'INTO OUTFILE'*)
            path=${arg#*INTO OUTFILE \'}
            path=${path%%\'*}
            if [ "${STUB_NATIVE_PARTIAL_PROBE:-no}" = yes ]; then
                if [ "$native_root" = yes ]; then
                    printf '%s\n' 'ERROR 1086 (HY000): File already exists' >&2
                else
                    : > "$path"
                    printf '%s\n' 'ERROR 1 (HY000): No space left on device' >&2
                fi
                exit 1
            fi
            file_access=${STUB_NATIVE_FILE_ACCESS:-yes}
            if [ "$native_root" = yes ]; then file_access=${STUB_NATIVE_ROOT_FILE_ACCESS:-yes}; fi
            if [ "$file_access" != yes ]; then
                printf '%s\n' 'ERROR 1045 (28000): FILE access denied for the fixture account' >&2
                exit 1
            fi
            if [ -n "${STUB_NATIVE_PROBE_ERROR:-}" ]; then
                printf '%s\n' "$STUB_NATIVE_PROBE_ERROR" >&2
                exit 1
            fi
            [ "${STUB_NATIVE_PROBE_INVISIBLE:-no}" != yes ] || exit 0
            printf 'kvs-native-export-probe\n' > "$path"
            exit 0
            ;;
        *admin_servers*)
            # The storage server rows, tab separated, as the batch mode prints them.
            printf '%b' "${STUB_SERVERS:-}"
            exit 0
            ;;
    esac
done
printf '11.8.2-MariaDB\t127\t45\t%s\t%s\n' "${STUB_NON_TRANSACTIONAL:-0}" "${STUB_UTF8MB4:-1}"
EOF
    cat > "$STUB_BIN/mariadb-dump" <<'EOF'
#!/bin/bash
{
    printf 'mariadb-dump argv:%s\n' "$(printf ' [%s]' "$@")"
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
        if [ "${STUB_NATIVE_CAPABLE:-no}" = yes ]; then
            printf '  --dir=name\n  --parallel=count\n'
        fi
        exit 0
    fi
done
for arg in "$@"; do
    case $arg in
        --dir=*)
            [ "${STUB_NATIVE_DUMP_FAIL:-no}" != yes ] || exit 42
            directory=${arg#*=}/${STUB_NATIVE_DATABASE_DIRECTORY:-oldsite}
            mkdir -p "$directory"
            printf 'CREATE TABLE `ktvs_options` (`variable` varchar(255) PRIMARY KEY, `value` text);\n' > "$directory/ktvs_options.sql"
            printf 'INITIAL_VERSION\t7.0.2\n' > "$directory/ktvs_options.txt"
            exit 0
            ;;
    esac
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
    # du logs how each entry is measured and answers a fixed size for it;
    # STUB_DU_SLEEP makes every call slow, for the time budget test.
    cat > "$STUB_BIN/du" <<'EOF'
#!/bin/bash
# One write per line: several of these run at once on the same log.
printf 'du argv:%s\n' "$(printf ' [%s]' "$@")" >> "${STUB_LOG:-/dev/null}"
if [ -n "${STUB_DU_SLEEP:-}" ]; then
    # Die on TERM at once, as the real du does, without leaving a sleep
    # behind that would keep the pipe open.
    sleep "$STUB_DU_SLEEP" &
    trap 'kill $! 2> /dev/null; exit 143' TERM
    wait $!
fi
printf '%s\t%s\n' "${STUB_DU_KB:-1024}" "${*: -1}"
printf 'du done: %s\n' "${*: -1}" >> "${STUB_LOG:-/dev/null}"
EOF
    # findmnt answers nfs for the path named in STUB_NFS_PATH, ext4 otherwise.
    cat > "$STUB_BIN/findmnt" <<'EOF'
#!/bin/bash
path=""
while [ $# -gt 0 ]; do
    case "$1" in
        -T) path=$2; shift 2 ;;
        *) shift ;;
    esac
done
if [ -n "${STUB_NFS_PATH:-}" ] && [ "$path" = "$STUB_NFS_PATH" ]; then
    echo nfs4
else
    echo ext4
fi
EOF
    chmod +x "$STUB_BIN/mariadb" "$STUB_BIN/mariadb-dump" "$STUB_BIN/df" "$STUB_BIN/du" "$STUB_BIN/findmnt"
}

# A site with what a real webroot accumulates: temporary uploads, compiled
# templates, logs (a 2 MB query log of the debug switch among them) and KVS
# backups, a hidden ACME directory, an old backup and a custom library at
# the root, sources next to the converted videos.
make_site_with_extras() {
    local dir="$1"

    make_site "$dir"
    mkdir -p "$dir/tmp" "$dir/admin/data/tmp" "$dir/admin/smarty/template-c" "$dir/admin/logs" "$dir/admin/data/backup" \
        "$dir/contents/videos_sources/0/1" "$dir/.well-known/acme" "$dir/backup" "$dir/lib"
    echo "part" > "$dir/tmp/upload.part"
    echo "tmp" > "$dir/admin/data/tmp/t"
    echo "compiled" > "$dir/admin/smarty/template-c/x.php"
    echo "log" > "$dir/admin/logs/cron.txt"
    head -c 2097152 /dev/zero > "$dir/admin/logs/debug_sql_post.txt"
    echo "backup" > "$dir/admin/data/backup/b.tar.gz"
    echo "source" > "$dir/contents/videos_sources/0/1/s.mp4"
    echo "token" > "$dir/.well-known/acme/t"
    echo "old" > "$dir/backup/old.sql"
    echo "lib" > "$dir/lib/a.php"
}

# A PATH without zstd and without pigz cannot be built by pruning the real
# one, so it is built from symlinks to the tools the exporter may use.
make_min_bin() {
    local tool path

    mkdir -p "$MIN_BIN"
    for tool in sed find readlink du df date mktemp rm mkdir ln tar wc uname gzip cat xargs nproc pkill sleep awk sort stat id chmod chown mv sha256sum getconf mkfifo tee head cut; do
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
# The file this compressor writes tells where the dump was staged.
zstd_target=$(readlink "/proc/$$/fd/1" 2> /dev/null || true)
{
    printf 'zstd argv:%s\n' "$(printf ' [%s]' "$@")"
    printf 'zstd stdout: [%s]\n' "$zstd_target"
} >> "${STUB_LOG:-/dev/null}"
exec cat
EOF
    cat > "$EXTRA_BIN/rsync" <<'EOF'
#!/bin/bash
[ "${1:-}" != --version ] || echo "rsync  version 3.0.9  protocol version 30"
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
    # Four entries three levels down (the three config files and the video),
    # 1 MB each from the stub.
    assert_key "$out" site_size_mb 4
    assert_key "$out" site_size_status exact
    assert_key "$out" site_size_entries 4
    assert_key "$out" site_size_entries_total 4
    [[ "$(detect_value "$out" site_fs_used_mb)" =~ ^[0-9]+$ ]] || fail "the usage of the filesystem holding the site must be reported"
    [[ "$(detect_value "$out" site_size_seconds)" =~ ^[0-9]+$ ]] || fail "the measurement time must be reported"
    grep -q '^du argv: \[-sLk\] \[--\] ' "$STUB_LOG" || fail "each entry must be measured through its symbolic links (du -sLk -- entry)"
    [ "$(grep -c '^du argv:' "$STUB_LOG")" -eq 4 ] || fail "one du per entry three levels down, got $(grep -c '^du argv:' "$STUB_LOG")"
    grep -q "^du argv: .*/admin/include/setup_db.php\]" "$STUB_LOG" || fail "the entries are the files three levels down"
    grep -q "Measuring the site size" "$err" || fail "the size measurement must be announced on stderr"
    grep -q "^Site size: 4 MB (4 entries, " "$err" || fail "the measured size must be reported with the time it took: $(cat "$err")"
    grep -q "The filesystem holding the site uses" "$err" || fail "the filesystem usage must be shown before the walk: $(cat "$err")"
    pass "detect reports the installation as key=value lines"
}

# nginx_config_lines <detect output> <file>: the web server configuration
# the report carries, written back as text.
nginx_config_lines() {
    sed -n 's/^nginx_config_[0-9][0-9]*=//p' "$1" > "$2"
}

test_detect_reports_the_encoding_and_the_web_server_configuration() {
    local site="$TMP_ROOT/nginx-site"
    local out="$TMP_ROOT/nginx.out"
    local err="$TMP_ROOT/nginx.err"
    local bin="$TMP_ROOT/bin-nginx"
    local root="$TMP_ROOT/etc-nginx"
    local text="$TMP_ROOT/nginx.text"

    make_site "$site"
    # A plain functions_base.php: the site is not encoded.
    printf '<?php\nfunction sql() {}\n' > "$site/admin/include/functions_base.php"
    mkdir -p "$bin" "$root/conf.d" "$root/sites-available" "$root/sites-enabled"
    # The stub nginx prints its configuration as nginx -T does, every file
    # behind a header line, or fails like a binary whose test fails.
    cat > "$bin/nginx" <<EOF
#!/bin/bash
[ "\${1:-}" = -T ] || exit 1
[ "\${STUB_NGINX_FAIL:-no}" = yes ] && exit 1
printf '# configuration file /etc/nginx/nginx.conf:\\nhttp {\\n    include /etc/nginx/conf.d/*.conf;\\n}\\n'
printf '# configuration file /etc/nginx/conf.d/site.conf:\\nserver {\\n    root $site;\\n    rewrite ^/videos/\$ /videos.php last;\\n}\\n'
EOF
    chmod +x "$bin/nginx"

    KVS_EXPORT_NGINX_BIN="$bin/nginx" run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" ||
        fail "detect must succeed with an nginx: $(cat "$err")"
    assert_key "$out" ioncube no
    assert_key "$out" nginx_config_source "nginx -T"
    assert_key "$out" nginx_config_lines 9
    assert_key "$out" nginx_site_files /etc/nginx/conf.d/site.conf
    nginx_config_lines "$out" "$text"
    [ "$(wc -l < "$text")" -eq 9 ] || fail "the configuration travels line by line, got $(wc -l < "$text") lines"
    grep -q "^    root $site;$" "$text" || fail "the vhost must be in the configuration carried: $(cat "$text")"
    grep -q '^    rewrite ^/videos/$ /videos.php last;$' "$text" || fail "the rewrite rules travel untouched"
    # The configuration comes last so the head of the report stays readable.
    [ "$(grep -n '^nginx_config_1=' "$out" | cut -d: -f1)" -gt "$(grep -n '^entry_1=' "$out" | cut -d: -f1)" ] ||
        fail "the configuration lines must follow the entries"

    # An encoded site, and an nginx that cannot print its configuration:
    # the files under the configuration directory are read instead, the
    # ones in conf.d and the links in sites-enabled among them.
    printf "<?php //004fb\nif(!extension_loaded('ionCube Loader')){die();}\n" > "$site/admin/include/functions_base.php"
    printf 'user www-data;\ninclude /etc/nginx/sites-enabled/*;\n' > "$root/nginx.conf"
    printf 'server {\n    root %s;\n}\n' "$site" > "$root/sites-available/site"
    ln -s "$root/sites-available/site" "$root/sites-enabled/site"
    printf 'gzip on;\n' > "$root/conf.d/gzip.conf"
    STUB_NGINX_FAIL=yes KVS_EXPORT_NGINX_BIN="$bin/nginx" KVS_EXPORT_NGINX_ROOT="$root" \
        run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" ||
        fail "detect must succeed when nginx cannot print its configuration: $(cat "$err")"
    assert_key "$out" ioncube yes
    assert_key "$out" nginx_config_source files
    assert_key "$out" nginx_site_files "$root/sites-enabled/site"
    nginx_config_lines "$out" "$text"
    grep -q "^# configuration file $root/conf.d/gzip.conf:$" "$text" || fail "the conf.d files must travel"
    grep -q "^# configuration file $root/nginx.conf:$" "$text" || fail "nginx.conf must travel"
    grep -q "^# configuration file $root/sites-enabled/site:$" "$text" || fail "the enabled sites must travel through their links"
    grep -q "^# configuration file $root/sites-available/site:$" "$text" && fail "an available site that is not enabled stays behind"
    [ "$(grep -c "^# configuration file " "$text")" -eq 3 ] || fail "three files, got $(grep -c '^# configuration file ' "$text")"

    # No nginx at all: reported as none, detect goes on.
    KVS_EXPORT_NGINX_BIN="$TMP_ROOT/no-nginx" KVS_EXPORT_NGINX_ROOT="$TMP_ROOT/no-such-dir" \
        run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" ||
        fail "detect must succeed without nginx"
    assert_key "$out" nginx_config_source none
    assert_key "$out" nginx_config_lines 0
    assert_key "$out" nginx_site_files ""
    grep -q '^nginx_config_1=' "$out" && fail "no configuration lines without a configuration"
    pass "detect reports the encoding and the web server configuration"
}

test_the_size_walk_stops_at_its_time_budget() {
    local site="$TMP_ROOT/budget-site"
    local out="$TMP_ROOT/budget.out"
    local err="$TMP_ROOT/budget.err"
    local started

    make_site "$site"
    started=$SECONDS
    STUB_DU_SLEEP=20 run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --size-timeout 1 detect "$site" ||
        fail "a walk cut short is not a failure: $(cat "$err")"
    [ $((SECONDS - started)) -lt 10 ] || fail "the walk must be killed at the budget, the run took $((SECONDS - started)) s"
    assert_key "$out" site_size_status incomplete
    assert_key "$out" site_size_mb 0
    assert_key "$out" site_size_entries 0
    assert_key "$out" site_size_entries_total 4
    assert_key "$out" db_ok yes
    grep -q "cut short after" "$err" || fail "the report must say the measurement was cut short: $(cat "$err")"
    grep -q "^du argv:" "$STUB_LOG" || fail "the walk must have started"
    grep -q "^du done:" "$STUB_LOG" && fail "the du at work must be killed with the walk"
    grep -q "Measuring the site size for at most 1s" "$err" || fail "the budget must be announced: $(cat "$err")"

    # The same budget from the environment, for a run by hand.
    KVS_EXPORT_SIZE_TIMEOUT=1 STUB_DU_SLEEP=20 run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" ||
        fail "the budget from the environment must work: $(cat "$err")"
    assert_key "$out" site_size_status incomplete
    pass "the size walk stops at its time budget"
}

# The size walk lists the entries it measures in a temporary file. In a
# full temporary directory that list is cut short, and the walk measured
# part of the site and reported it as the whole of it, exact. It now
# measures the site in one pass instead, and says why.
test_a_full_temporary_directory_does_not_shrink_the_site_size() {
    local site="$TMP_ROOT/full-tmp-site"
    local out="$TMP_ROOT/full-tmp.out"
    local err="$TMP_ROOT/full-tmp.err"
    local i total

    make_site "$site"
    mkdir -p "$site/contents/videos_screenshots"
    for ((i = 1; i <= 300; i++)); do
        : > "$site/contents/videos_screenshots/screenshot-of-a-video-with-a-rather-long-file-name-$i.jpg"
    done
    # 8 kB at most for any file the exporter writes: its report fits, the
    # 40 kB list of the entries to measure does not.
    (
        ulimit -f 8
        STUB_LOG=/dev/null run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site"
    ) || fail "detect must go on when the temporary directory is full: $(cat "$err")"
    assert_key "$out" site_size_status exact
    total=$(detect_value "$out" site_size_entries_total)
    [ "$total" = 1 ] || [ "$total" = 304 ] ||
        fail "an exact size must cover the whole site, not $total of its 304 entries: $(grep '^Site size' "$err")"
    grep -q "could not be written" "$err" || fail "the one-pass measurement must be explained: $(cat "$err")"
    pass "a full temporary directory does not shrink the site size"
}

# entry_value <detect output> <path> prints "mb|kind|state" of an entry.
entry_value() {
    sed -n "s/^entry_[0-9]*=$(printf '%s' "$2" | sed 's/[.[\/*^$]/\\&/g')|//p" "$1" | head -n 1
}

# has_pattern <detect output> <pattern>: the pattern is among the exclude_N lines.
has_pattern() {
    sed -n 's/^exclude_[0-9]*=//p' "$1" | grep -Fxq -- "$2"
}

test_detect_reports_the_entries_and_what_stays_behind() {
    local site="$TMP_ROOT/entries-site"
    local out="$TMP_ROOT/entries.out"
    local err="$TMP_ROOT/entries.err"

    make_site_with_extras "$site"
    export STUB_SERVERS="Local Videos\t$site/contents/videos\t0\thttps://www.example.com/contents/videos\nDisk 2\t/mnt/disk2/videos\t0\thttps://www.example.com/videos2\nCDN\t/var/storage\t1\thttps://cdn.example.com/\n"
    export STUB_NFS_PATH="$site/contents/videos_sources"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "detect must succeed: $(cat "$err")"
    unset STUB_SERVERS STUB_NFS_PATH

    # Thirteen entries three levels down, 1 MB each from the stub; the
    # temporary files, the compiled templates, the hidden directory and the
    # query log stay behind on their own, the source videos sit on NFS. The
    # du stub answers 1 MB per measured entry whatever it holds, the query
    # log among them.
    assert_key "$out" site_total_mb 14
    assert_key "$out" site_size_mb 8
    [ "$(entry_value "$out" contents/videos)" = "1|kvs|copied" ] || fail "contents/videos: $(entry_value "$out" contents/videos)"
    [ "$(entry_value "$out" contents/videos_sources)" = "1|network:nfs4|excluded" ] || fail "a network mount stays behind: $(entry_value "$out" contents/videos_sources)"
    [ "$(entry_value "$out" tmp)" = "1|transient|excluded" ] || fail "tmp: $(entry_value "$out" tmp)"
    [ "$(entry_value "$out" admin/data/tmp)" = "1|transient|excluded" ] || fail "admin/data/tmp: $(entry_value "$out" admin/data/tmp)"
    [ "$(entry_value "$out" admin/smarty/template-c)" = "1|transient|excluded" ] || fail "compiled templates: $(entry_value "$out" admin/smarty/template-c)"
    [ "$(entry_value "$out" .well-known)" = "1|hidden|excluded" ] || fail "a hidden entry stays behind: $(entry_value "$out" .well-known)"
    [ "$(entry_value "$out" backup)" = "1|extra|copied" ] || fail "an unknown directory is reported and copied: $(entry_value "$out" backup)"
    [ "$(entry_value "$out" lib)" = "1|extra|copied" ] || fail "lib: $(entry_value "$out" lib)"
    [ "$(entry_value "$out" admin/logs)" = "2|kvs|copied" ] || fail "admin/logs holds its two entries: $(entry_value "$out" admin/logs)"
    [ "$(entry_value "$out" admin/logs/debug_sql_post.txt)" = "1|debuglog|excluded" ] || fail "the query log stays behind: $(entry_value "$out" admin/logs/debug_sql_post.txt)"
    [ "$(entry_value "$out" admin/data/backup)" = "1|kvs|copied" ] || fail "admin/data/backup: $(entry_value "$out" admin/data/backup)"
    [ "$(entry_value "$out" admin)" = "8|kvs|copied" ] || fail "admin holds its eight entries: $(entry_value "$out" admin)"
    [ "$(entry_value "$out" contents)" = "2|kvs|copied" ] || fail "contents holds two: $(entry_value "$out" contents)"
    has_pattern "$out" '/tmp/*' || fail "the temporary files leave as a pattern on their content: $(grep '^exclude_' "$out")"
    has_pattern "$out" '/.well-known' || fail "the hidden entry leaves whole: $(grep '^exclude_' "$out")"
    has_pattern "$out" '/contents/videos_sources' || fail "the mount leaves whole: $(grep '^exclude_' "$out")"
    has_pattern "$out" '/admin/data/tmp/*' || fail "admin/data/tmp pattern: $(grep '^exclude_' "$out")"
    has_pattern "$out" '/admin/smarty/template-c/*' || fail "compiled templates pattern: $(grep '^exclude_' "$out")"
    has_pattern "$out" '/admin/logs/debug_sql_post.txt' || fail "the query log leaves as a file pattern: $(grep '^exclude_' "$out")"
    [ "$(grep -c '^exclude_' "$out")" -eq 6 ] || fail "six patterns, got $(grep -c '^exclude_' "$out")"
    grep -q '^entry_1=\.well-known|' "$out" || fail "the entries come in C order, hidden first: $(grep '^entry_1=' "$out")"
    grep -Fxq "server_1=Local Videos|$site/contents/videos|0|inside|https://www.example.com/contents/videos" "$out" || fail "a local server inside the site: $(grep '^server_' "$out")"
    grep -Fxq "server_2=Disk 2|/mnt/disk2/videos|0|outside|https://www.example.com/videos2" "$out" || fail "a local server outside the site: $(grep '^server_' "$out")"
    grep -Fxq "server_3=CDN|/var/storage|1|outside|https://cdn.example.com/" "$out" || fail "a remote server: $(grep '^server_' "$out")"
    grep -q 'MYSQL_PWD=\[' "$STUB_LOG" || fail "the server query goes through the same password handling"
    pass "detect reports the entries, what stays behind and the storage servers"
}

test_excluded_and_included_paths_change_what_travels() {
    local site="$TMP_ROOT/choice-site"
    local out="$TMP_ROOT/choice.out"
    local err="$TMP_ROOT/choice.err"
    local archive="$TMP_ROOT/choice.tar"

    make_site_with_extras "$site"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --exclude contents/videos_sources --exclude=backup/ --include .well-known \
        --include admin/logs/debug_sql_post.txt detect "$site" ||
        fail "detect with choices must succeed: $(cat "$err")"
    assert_key "$out" site_total_mb 14
    assert_key "$out" site_size_mb 9
    [ "$(entry_value "$out" contents/videos_sources)" = "1|kvs|excluded" ] || fail "an excluded bucket: $(entry_value "$out" contents/videos_sources)"
    [ "$(entry_value "$out" backup)" = "1|extra|excluded" ] || fail "an excluded extra: $(entry_value "$out" backup)"
    [ "$(entry_value "$out" .well-known)" = "1|hidden|copied" ] || fail "an included hidden entry: $(entry_value "$out" .well-known)"
    [ "$(entry_value "$out" admin/logs/debug_sql_post.txt)" = "1|debuglog|copied" ] || fail "an included query log: $(entry_value "$out" admin/logs/debug_sql_post.txt)"
    has_pattern "$out" '/tmp/*' || fail "patterns: $(grep '^exclude_' "$out")"
    has_pattern "$out" '/backup' || fail "patterns: $(grep '^exclude_' "$out")"
    has_pattern "$out" '/contents/videos_sources' || fail "patterns: $(grep '^exclude_' "$out")"
    has_pattern "$out" '/.well-known' && fail "an included entry has no pattern"
    has_pattern "$out" '/admin/logs/debug_sql_post.txt' && fail "an included query log has no pattern"
    [ "$(grep -c '^exclude_' "$out")" -eq 5 ] || fail "five patterns, got $(grep '^exclude_' "$out")"

    # A path that is no listed entry still leaves; a parent excluded with
    # its child counts once.
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --exclude contents/videos/1.mp4 --exclude contents --exclude contents/videos detect "$site" ||
        fail "nested exclusions must succeed: $(cat "$err")"
    assert_key "$out" site_size_mb 7
    [ "$(entry_value "$out" contents/videos/1.mp4)" = "1|named|excluded" ] || fail "a named path: $(entry_value "$out" contents/videos/1.mp4)"
    has_pattern "$out" '/contents' || fail "the parent leaves as one pattern: $(grep '^exclude_' "$out")"
    has_pattern "$out" '/contents/videos' && fail "a child of an excluded parent needs no pattern"
    has_pattern "$out" '/contents/videos/1.mp4' && fail "a named child of an excluded parent needs no pattern"

    # The archive leaves the same things behind, the transient directories
    # themselves travel empty.
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" -y -o "$archive" --exclude backup archive "$site" ||
        fail "the archive with exclusions must be written: $(cat "$err")"
    tar -tf "$archive" | grep -Fxq "www/tmp/" || fail "tmp travels as an empty directory: $(tar -tf "$archive")"
    tar -tf "$archive" | grep -Fq "www/tmp/upload.part" && fail "temporary files must not travel"
    tar -tf "$archive" | grep -Fq "www/admin/smarty/template-c/x.php" && fail "compiled templates must not travel"
    tar -tf "$archive" | grep -Fq "www/admin/logs/debug_sql_post.txt" && fail "the query log must not travel"
    tar -tf "$archive" | grep -Fxq "www/admin/logs/cron.txt" || fail "the other logs travel"
    tar -tf "$archive" | grep -Fq "www/backup" && fail "an excluded directory must not travel"
    tar -tf "$archive" | grep -Fq "www/.well-known" && fail "a hidden directory must not travel"
    tar -tf "$archive" | grep -Fxq "www/contents/videos_sources/0/1/s.mp4" || fail "the sources travel when not excluded"
    tar -tf "$archive" | grep -Fxq "www/lib/a.php" || fail "an unknown directory travels"
    grep -q "backup .*excluded" "$err" || fail "the summary lists what stays behind: $(cat "$err")"
    grep -q "Entries, largest first" "$err" || fail "the summary has the entry table"

    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --exclude "../etc" detect "$site" && fail "a path leaving the site must be refused"
    grep -q "must be a plain path" "$err" || fail "the refusal must explain: $(cat "$err")"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --exclude "a b" detect "$site" && fail "a path with a space must be refused"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --exclude / detect "$site" && fail "the whole site cannot be excluded"
    pass "excluded and included paths change what travels"
}

test_the_size_walk_can_be_skipped() {
    local site="$TMP_ROOT/nosize-site"
    local out="$TMP_ROOT/nosize.out"
    local err="$TMP_ROOT/nosize.err"

    make_site "$site"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --no-size detect "$site" ||
        fail "detect without the size must succeed: $(cat "$err")"
    assert_key "$out" site_size_status skipped
    assert_key "$out" site_size_mb 0
    [[ "$(detect_value "$out" site_fs_used_mb)" =~ ^[0-9]+$ ]] || fail "the filesystem usage stands in for the size"
    grep -q "^du argv:" "$STUB_LOG" && fail "no du may run with --no-size"
    grep -q "not measured" "$err" || fail "skipping the size must be said: $(cat "$err")"

    # Beyond the walk, the query log is still sized, on its own, and
    # leaves nothing from a size that was not measured.
    make_site_with_extras "$TMP_ROOT/nosize-extras"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --no-size detect "$TMP_ROOT/nosize-extras" ||
        fail "detect without the size must succeed on a site with extras: $(cat "$err")"
    assert_key "$out" site_size_mb 0
    [ "$(entry_value "$out" admin/logs/debug_sql_post.txt)" = "2|debuglog|excluded" ] || fail "the query log is sized on its own: $(entry_value "$out" admin/logs/debug_sql_post.txt)"
    [ "$(entry_value "$out" tmp)" = "|transient|excluded" ] || fail "a directory beyond the walk has no size: $(entry_value "$out" tmp)"

    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --size-timeout abc detect "$site" && fail "a budget that is not a number must be refused"
    grep -q "size-timeout needs a number" "$err" || fail "the refusal must name the option: $(cat "$err")"
    pass "the size walk can be skipped"
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
    argv_lines | grep -Fq -- '[--no-autocommit]' || fail "the dump must batch INSERT statements during replay"
    argv_lines | grep -Fq -- '[--extended-insert]' || fail "system options must not disable grouped INSERT statements"
    argv_lines | grep -Fq -- '[--disable-keys]' || fail "the dump must defer non-unique MyISAM index maintenance"
    argv_lines | grep -Fq -- '[--net-buffer-length=1048576]' || fail "system options must not shrink the INSERT statement buffer"
    argv_lines | grep -Fq -- '[--opt]' && fail "the grouped options must not override the selected locking mode"
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
    assert_key "$out" rsync_version 3.0.9

    run_export "$EXTRA_BIN:$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" || fail "the dump must succeed"
    argv_lines | grep -Fq -- 'zstd argv: [-T0] [-3] [-q] [-c]' ||
        fail "zstd must be called with the streaming options: $(argv_lines)"
    grep -Fq -- '-- Dump completed' "$out" || fail "the stub compressor passes the dump through unchanged"

    run_export "$EXTRA_BIN:$STUB_BIN:$MIN_BIN" "$out" "$err" --gzip detect "$site" || fail "detect must succeed"
    assert_key "$out" compressor gzip

    # zstd 1.1.2 (Debian 9) has no -T option: it prints its usage, exits 1
    # and the dump pipeline leaves a truncated file.
    mkdir -p "$TMP_ROOT/bin-old-zstd"
    cat > "$TMP_ROOT/bin-old-zstd/zstd" <<'EOF'
#!/bin/bash
{
    printf 'zstd argv:%s\n' "$(printf ' [%s]' "$@")"
} >> "${STUB_LOG:-/dev/null}"
for arg in "$@"; do
    if [ "$arg" = -T0 ]; then
        echo "Usage: zstd [args] [FILE(s)] [-o file]" >&2
        exit 1
    fi
done
exec cat
EOF
    chmod +x "$TMP_ROOT/bin-old-zstd/zstd"
    run_export "$TMP_ROOT/bin-old-zstd:$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" ||
        fail "the dump must succeed with a zstd that has no -T option: $(cat "$err")"
    argv_lines | grep -Fq -- 'zstd argv: [-3] [-q] [-c]' ||
        fail "a zstd without -T must compress on one thread: $(argv_lines)"
    grep -Fq -- '-- Dump completed' "$out" || fail "the dump must pass through the one-thread zstd"
    pass "the dump uses the compressor that is installed"
}

test_a_server_without_utf8mb4_is_dumped_as_utf8() {
    local site="$TMP_ROOT/utf8-site"
    local out="$TMP_ROOT/utf8.out"
    local err="$TMP_ROOT/utf8.err"

    make_site "$site"
    # The stock MySQL 5.1 of CentOS 6 has no utf8mb4, and its mysqldump stops
    # on the name: "Character set 'utf8mb4' is not a compiled character set".
    STUB_UTF8MB4=0 run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" dump "$site" ||
        fail "the dump must succeed on a server without utf8mb4: $(cat "$err")"
    argv_lines | grep -Fq -- '[--default-character-set=utf8]' ||
        fail "a server without utf8mb4 must be dumped as utf8: $(argv_lines)"
    grep -q "no utf8mb4" "$err" || fail "the utf8 fallback must be announced: $(cat "$err")"
    STUB_UTF8MB4=0 run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "detect must succeed"
    assert_key "$out" db_utf8mb4 no

    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "detect must succeed"
    assert_key "$out" db_utf8mb4 yes
    pass "a server without utf8mb4 is dumped as utf8"
}

test_native_format_selection_and_bundle_integrity() {
    local site="$TMP_ROOT/native-site" out="$TMP_ROOT/native.out" err="$TMP_ROOT/native.err"
    local native_bin="$TMP_ROOT/native-bin" extracted="$TMP_ROOT/native-extracted"
    local test_uid test_gid category

    make_site "$site"
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "auto detection must succeed with an older dump tool"
    assert_key "$out" db_dump_format sql
    grep -q 'does not support --dir' "$out" || fail "SQL fallback must name the missing capability"
    if run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format directory dump "$site"; then
        fail "forced native export must refuse an older dump client"
    fi
    [ ! -s "$out" ] || fail "a refused native export must not emit a partial stream"

    # The fixture process represents the mysql OS user, without changing
    # accounts or filesystem ownership on the machine running this test.
    mkdir "$native_bin" "$extracted"
    test_uid=$(id -u)
    test_gid=$(id -g)
    cat > "$native_bin/id" <<EOF
#!/bin/bash
case \$1 in
    -u)
        if [ "\${2:-}" = mysql ]; then printf '%s\\n' '$test_uid'
        else printf '%s\\n' "\${STUB_NATIVE_OWNER_UID:-$test_uid}"; fi
        ;;
    -g) printf '%s\\n' '$test_gid' ;;
    *) exit 1 ;;
esac
EOF
    cat > "$native_bin/chown" <<'EOF'
#!/bin/bash
printf 'chown argv:%s\n' "$*" >> "$STUB_LOG"
EOF
    # Every read of the staged files by a checksum pass shows in the log.
    cat > "$native_bin/sha256sum" <<EOF
#!/bin/bash
printf 'sha256sum argv:%s\n' "\$(printf ' [%s]' "\$@")" >> "\$STUB_LOG"
exec "$(command -v sha256sum)" "\$@"
EOF
    chmod +x "$native_bin/id" "$native_bin/chown" "$native_bin/sha256sum"
    export STUB_NATIVE_CAPABLE=yes
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" ||
        fail "native prerequisites must be checked: $(cat "$err")"
    assert_key "$out" db_dump_format directory
    # A tar that cannot hand members to a command cannot checksum the bundle
    # while it streams: auto keeps the SQL format and says why.
    mkdir "$TMP_ROOT/plain-tar-bin"
    cat > "$TMP_ROOT/plain-tar-bin/tar" <<EOF
#!/bin/bash
[ "\${1:-}" != --help ] || { echo 'Usage: tar [options]'; exit 0; }
exec "$(command -v tar)" "\$@"
EOF
    chmod +x "$TMP_ROOT/plain-tar-bin/tar"
    run_export "$TMP_ROOT/plain-tar-bin:$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" ||
        fail "detect must succeed without GNU tar: $(cat "$err")"
    assert_key "$out" db_dump_format sql
    grep -q 'GNU tar' "$out" || fail "the fallback must name the tools the native stream needs"
    # Each of those tools is required, not just one of them.
    cp -a "$MIN_BIN" "$TMP_ROOT/no-mkfifo-bin"
    rm "$TMP_ROOT/no-mkfifo-bin/mkfifo"
    run_export "$native_bin:$STUB_BIN:$TMP_ROOT/no-mkfifo-bin" "$out" "$err" detect "$site" ||
        fail "detect must succeed without mkfifo: $(cat "$err")"
    assert_key "$out" db_dump_format sql
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory --gzip dump "$site" ||
        fail "native export must produce a bundle: $(cat "$err")"
    tar -xzf "$out" -C "$extracted"
    (cd "$extracted" && sha256sum -c SHA256SUMS >/dev/null) || fail "native checksums must verify after extraction"
    # The staged export is read once, by the archive: the checksums come from
    # the stream (one sha256sum on stdin per member) and close the archive.
    [ "$(argv_lines | grep -c '^sha256sum argv:')" -eq 3 ] || fail "each bundle member must be hashed once: $(argv_lines | grep sha256sum)"
    argv_lines | grep '^sha256sum argv:' | grep -qvFx 'sha256sum argv: []' &&
        fail "the staged files must not be read by a separate checksum pass: $(argv_lines | grep sha256sum)"
    [ "$(tar -tzf "$out" | tail -n 1)" = SHA256SUMS ] || fail "SHA256SUMS must close the streamed bundle: $(tar -tzf "$out")"
    assert_key "$extracted/kvs-native-export.manifest" format 2
    assert_key "$extracted/kvs-native-export.manifest" complete yes
    assert_key "$extracted/kvs-native-export.manifest" source_database oldsite
    assert_key "$extracted/kvs-native-export.manifest" tables 1
    [ -f "$extracted/data/ktvs_options.sql" ] && [ -f "$extracted/data/ktvs_options.txt" ] || fail "native data must use the flat bundle layout"
    argv_lines | grep -Fq '[--parallel=0]' || fail "native source reads must share one consistent connection"
    argv_lines | grep -Fq 'mariadb-dump argv: [--no-defaults]' || fail "native exports must not inherit filtering or formatting options"
    grep -Fq '[--socket=/tmp/fixture.sock]' "$STUB_LOG" || fail "native exports must preserve the resolved local socket"
    argv_lines | grep -Fq '[--default-character-set=binary]' || fail "native data must preserve original character bytes"
    # A member the stream could not hash would leave an empty digest: the
    # export fails instead of shipping checksums the import rejects.
    mkdir "$TMP_ROOT/broken-hash-bin"
    cat > "$TMP_ROOT/broken-hash-bin/sha256sum" <<EOF
#!/bin/bash
[ "\$#" -eq 0 ] || exec "$(command -v sha256sum)" "\$@"
cat > /dev/null
exit 1
EOF
    chmod +x "$TMP_ROOT/broken-hash-bin/sha256sum"
    if run_export "$TMP_ROOT/broken-hash-bin:$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory --gzip dump "$site"; then
        fail "a member that could not be hashed must stop the native export"
    fi
    grep -q 'could not be checksummed' "$err" || fail "the failed hash must be reported: $(cat "$err")"

    make_site "$TMP_ROOT/native-domain-site" https://source.example localhost
    sed -i 's/oldsite/source-site.example/' "$TMP_ROOT/native-domain-site/admin/include/setup_db.php"
    export STUB_NATIVE_DATABASE_DIRECTORY=source@002dsite@002eexample
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory --gzip dump "$TMP_ROOT/native-domain-site" ||
        fail "native export must accept MariaDB-encoded database directory names: $(cat "$err")"
    tar -xOf "$out" kvs-native-export.manifest > "$extracted/domain.manifest"
    assert_key "$extracted/domain.manifest" source_database source-site.example
    unset STUB_NATIVE_DATABASE_DIRECTORY

    export STUB_NATIVE_SECONDARY_AI_COLUMN='unsupported column'
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail 'native compatibility inspection failed'
    assert_key "$out" db_dump_format sql
    grep -Fq 'unsupported_identifiers=1' "$out" || fail 'secondary AUTO_INCREMENT mappings must be checked before export'
    unset STUB_NATIVE_SECONDARY_AI_COLUMN

    export STUB_NATIVE_GENERATED=5 STUB_NATIVE_LOCAL_FKS=17
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" ||
        fail "generated columns and internal foreign keys must retain native export: $(cat "$err")"
    assert_key "$out" db_dump_format directory
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory --gzip dump "$site" ||
        fail "supported extended schema metadata must allow native export: $(cat "$err")"
    tar -xOf "$out" kvs-native-export.manifest > "$extracted/extended.manifest"
    assert_key "$extracted/extended.manifest" format 2
    argv_lines | grep -Fq '[--single-transaction]' || fail "extended native schemas must keep one source transaction"
    argv_lines | grep -Fq '[--parallel=0]' || fail "extended native schemas must not split source snapshots"
    unset STUB_NATIVE_GENERATED STUB_NATIVE_LOCAL_FKS

    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory --gzip -y \
        -o "$TMP_ROOT/native-archive.tar" archive "$site" || fail "native data must also work inside a full archive: $(cat "$err")"
    tar -xOf "$TMP_ROOT/native-archive.tar" kvs-export.manifest > "$extracted/outer.manifest"
    assert_key "$extracted/outer.manifest" dump database.mariadb.tar.gz
    assert_key "$extracted/outer.manifest" db_dump_format directory
    tar -xOf "$TMP_ROOT/native-archive.tar" database.mariadb.tar.gz | tar -tzf - >/dev/null || fail "the archived native payload must be readable"

    make_site "$TMP_ROOT/native-tcp-site" https://tcp.example.com localhost:3307
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory dump "$TMP_ROOT/native-tcp-site" ||
        fail "an explicit local TCP connection must be preserved: $(cat "$err")"
    grep -Fq '[--protocol=tcp] [-h] [localhost] [-P] [3307]' "$STUB_LOG" || fail "native export must preserve the configured TCP endpoint"
    grep -Fq '[--socket=' "$STUB_LOG" && fail "native export must not replace a TCP endpoint with a socket"

    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=sql detect "$site" || fail "explicit SQL format must stay available"
    assert_key "$out" db_dump_format sql
    argv_lines | grep -Fq 'INTO OUTFILE' && fail "explicit SQL format must not probe native filesystem access"

    export STUB_NATIVE_FILE_ACCESS=no
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "auto must fall back without FILE access"
    assert_key "$out" db_dump_format sql
    grep -q 'FILE access' "$out" || fail "the fallback must explain unavailable FILE access"
    export STUB_NATIVE_OWNER_UID=0 STUB_NATIVE_ROOT_ACCESS=yes
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory --gzip dump "$site" ||
        fail "root socket access must support native export without granting FILE to the site: $(cat "$err")"
    grep -Fq '[--protocol=socket] [--socket=/tmp/fixture.sock] [-u] [root] [--skip-password] [oldsite]' "$STUB_LOG" ||
        fail "the dump must use the verified native root socket connection"
    grep -Fq 'mariadb-dump env: MYSQL_PWD=[]' "$STUB_LOG" || fail "root dumps must not inherit the site password"
    argv_lines | grep -Eq 'GRANT |ALTER USER' && fail "native exports must not change grants or authentication"

    export STUB_NATIVE_ROOT_INSTANCE=another-instance
    if run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory dump "$site"; then
        fail "root socket access must refuse a different instance"
    fi
    grep -Fq 'metadata differs' "$err" || fail "instance mismatch must be diagnosed"
    [ ! -s "$out" ] || fail "an instance mismatch must not stream data"
    unset STUB_NATIVE_ROOT_INSTANCE
    export STUB_NATIVE_ROOT_HIDDEN_TRIGGERS=1
    if run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory dump "$site"; then
        fail "root must not export objects missing from site metadata"
    fi
    grep -Fq 'metadata differs' "$err" || fail "root schema visibility mismatch must be diagnosed"
    unset STUB_NATIVE_ROOT_HIDDEN_TRIGGERS

    export STUB_NATIVE_PARTIAL_PROBE=yes
    if run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory dump "$site"; then
        fail "a failed partial probe must stop native export"
    fi
    grep -Fq 'No space left on device' "$err" || fail "a root retry must not mask the original failure"
    grep -Fq 'File already exists' "$err" || fail "a failed root retry must retain its own diagnostic"
    unset STUB_NATIVE_PARTIAL_PROBE

    export STUB_NATIVE_ROOT_ACCESS=no
    if run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory dump "$site"; then
        fail "forced native export must fail when neither account can export"
    fi
    grep -Fq 'ERROR 1045' "$err" || fail "native failures must retain the database error"
    grep -Fq 'local root socket login failed' "$err" || fail "unavailable root authentication must be explicit"
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --gzip dump "$site" || fail "auto must preserve SQL fallback with the site account"
    argv_lines | grep -F 'mariadb-dump argv:' | grep -Fq '[-u] [kvs]' || fail "SQL fallback must retain the original site account"
    grep -Fq "mariadb-dump env: MYSQL_PWD=[$REAL_PASSWORD]" "$STUB_LOG" || fail "SQL fallback must retain the original site password"
    unset STUB_NATIVE_OWNER_UID STUB_NATIVE_ROOT_ACCESS
    unset STUB_NATIVE_FILE_ACCESS

    mkdir "$TMP_ROOT/native-datadir" "$TMP_ROOT/native-allowed"
    STUB_NATIVE_DATADIR_HEX=$(printf '%s' "$TMP_ROOT/native-datadir" | od -An -tx1 | tr -d ' \n')
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory detect "$site" || fail "native export must use the actual datadir"
    argv_lines | grep -Fq "$TMP_ROOT/native-datadir/.kvs-native-export." || fail "the native probe must avoid the general TMPDIR"
    export STUB_NATIVE_DIRECTORY_HEX
    STUB_NATIVE_DIRECTORY_HEX=$(printf '%s' "$TMP_ROOT/native-allowed" | od -An -tx1 | tr -d ' \n')
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory detect "$site" || fail "secure_file_priv must remain supported"
    argv_lines | grep -Fq "$TMP_ROOT/native-allowed/.kvs-native-export." || fail "secure_file_priv must take precedence over datadir"
    unset STUB_NATIVE_DIRECTORY_HEX

    export STUB_NATIVE_PROBE_ERROR="ERROR 1 (HY000): Can't create/write to file (Errcode: 13 Permission denied); $REAL_PASSWORD"
    if run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory dump "$site"; then
        fail "native export must refuse a server filesystem write failure"
    fi
    grep -Fq 'Permission denied' "$err" || fail "filesystem failures must retain the precise cause"
    grep -Fq "$REAL_PASSWORD" "$err" && fail "native diagnostics must redact credentials"
    unset STUB_NATIVE_PROBE_ERROR
    export STUB_NATIVE_PROBE_INVISIBLE=yes
    if run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory dump "$site"; then
        fail "server-only files must not pass the shared-directory check"
    fi
    grep -Fq 'exporter cannot read' "$err" || fail "namespace mismatch must be distinct from FILE denial"
    unset STUB_NATIVE_PROBE_INVISIBLE
    STUB_NATIVE_DATADIR_HEX=$(printf '%s' "$TMP_ROOT" | od -An -tx1 | tr -d ' \n')
    export STUB_NATIVE_TRIGGERS=1
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "auto must preserve unsupported schema with SQL format"
    assert_key "$out" db_dump_format sql
    assert_key "$out" db_directory_reason 'SQL format required by source schema: triggers=1'
    argv_lines | grep -Fq 'INTO OUTFILE' && fail "unsupported schemas must not start native filesystem probes"
    unset STUB_NATIVE_TRIGGERS
    export STUB_NATIVE_EXTERNAL_FKS=2 STUB_NATIVE_ROUTINES=1
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "multiple unsupported schema kinds must retain SQL fallback"
    assert_key "$out" db_directory_reason 'SQL format required by source schema: external_foreign_keys=2, routines=1'
    if run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory dump "$site"; then
        fail "explicit native export must not bypass unsupported schema checks"
    fi
    [ ! -s "$out" ] || fail "a schema refusal must not emit an incomplete dump"
    unset STUB_NATIVE_EXTERNAL_FKS STUB_NATIVE_ROUTINES

    export STUB_NATIVE_INVISIBLE=1 STUB_NATIVE_GENERATED=5 STUB_NATIVE_LOCAL_FKS=17
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "invisible columns must retain SQL fallback"
    assert_key "$out" db_dump_format sql
    assert_key "$out" db_directory_reason 'SQL format required by source schema: invisible_columns=1'
    unset STUB_NATIVE_INVISIBLE STUB_NATIVE_GENERATED STUB_NATIVE_LOCAL_FKS

    export STUB_NATIVE_GENERATED=5 STUB_NATIVE_LOCAL_FKS=17
    for category in GENERATED_TABLE_COLUMN FK_CONSTRAINT FK_COLUMN FK_REF_COLUMN; do
        export "STUB_NATIVE_$category=not-supported"
        run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "unsupported $category metadata must fall back before dumping"
        assert_key "$out" db_dump_format sql
        assert_key "$out" db_directory_reason 'SQL format required by source schema: unsupported_identifiers=1'
        argv_lines | grep -Fq 'INTO OUTFILE' && fail "unsupported identifiers must be rejected before filesystem probes"
        if run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format=directory dump "$site"; then
            fail "explicit native export must refuse unsupported $category identifiers"
        fi
        [ ! -s "$out" ] || fail "unsupported identifiers must not emit an incomplete dump"
        unset "STUB_NATIVE_$category"
    done
    unset STUB_NATIVE_GENERATED STUB_NATIVE_LOCAL_FKS

    export STUB_NATIVE_NONSTANDARD=1 STUB_NATIVE_EVENTS=1
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "unsupported table kinds and events must retain SQL fallback"
    assert_key "$out" db_dump_format sql
    assert_key "$out" db_directory_reason 'SQL format required by source schema: events=1, nonstandard_tables=1'
    unset STUB_NATIVE_NONSTANDARD STUB_NATIVE_EVENTS

    export STUB_NATIVE_UNSUPPORTED=invalid
    run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" detect "$site" || fail "an invalid schema count must fall back safely"
    assert_key "$out" db_dump_format sql
    assert_key "$out" db_directory_reason 'the source schema compatibility counts could not be verified'
    unset STUB_NATIVE_UNSUPPORTED

    export STUB_NATIVE_DUMP_FAIL=yes
    if run_export "$native_bin:$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format directory dump "$site"; then
        fail "a failed native dump must not appear successful"
    fi
    [ ! -s "$out" ] || fail "the native dump must finish before streaming starts"
    unset STUB_NATIVE_DUMP_FAIL STUB_NATIVE_CAPABLE
    [ -z "$(find "$TMP_ROOT" -name '.kvs-native-export.*' -print -quit)" ] || fail "private native staging must be removed after success and failure"
    pass "native selection validates prerequisites and streams only a complete checksummed bundle"
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

test_the_dump_is_staged_next_to_the_archive_and_outside_the_site() {
    local site="$TMP_ROOT/staging-site"
    local work="$TMP_ROOT/staging-work"
    local out="$TMP_ROOT/staging.out"
    local err="$TMP_ROOT/staging.err"
    local status=0

    make_site "$site"
    mkdir -p "$work"
    # TMPDIR is often a small tmpfs: the dump goes next to the archive, on
    # the filesystem the free space check looked at, and leaves no trace.
    run_export "$EXTRA_BIN:$STUB_BIN:$MIN_BIN" "$out" "$err" -y -o "$work/export.tar" archive "$site" ||
        fail "the archive must be written: $(cat "$err")"
    grep -Eq "^zstd stdout: \[$work/\.kvs-export\.[^/]+/database\.sql\.zst\]$" "$STUB_LOG" ||
        fail "the dump must be staged next to the archive: $(grep 'stdout:' "$STUB_LOG")"
    find "$work" -maxdepth 1 -name '.kvs-export.*' | grep -q . && fail "the staging directory must be removed: $(ls -A "$work")"
    tar -tf "$work/export.tar" | grep -Fxq "database.sql.zst" || fail "the archive must hold the dump"

    # An archive or a dump inside the site would be served by its web server.
    status=0
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" -y -o "$site/export.tar" archive "$site" || status=$?
    [ "$status" -eq 1 ] || fail "an archive inside the site must be refused, got $status"
    grep -q "inside the site" "$err" || fail "the refusal must explain: $(cat "$err")"
    [ ! -e "$site/export.tar" ] || fail "nothing must be written inside the site"
    status=0
    run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" -y --dump-only -o "$site/contents/dump.sql.gz" "$site" || status=$?
    [ "$status" -eq 1 ] || fail "a dump inside the site must be refused, got $status"
    [ ! -e "$site/contents/dump.sql.gz" ] || fail "no dump may be written inside the site"
    pass "the dump is staged next to the archive and outside the site"
}

test_array_expansions_are_guarded_for_old_bash() {
    local bare

    # bash 4.2 (CentOS 7) and 4.3 (Ubuntu 16.04, Debian 8) stop on "${a[@]}"
    # of an empty array under set -u; the guarded form expands to nothing.
    bare=$(grep -nE '^[^#]*(^|[^+])"\$\{[A-Za-z_][A-Za-z_0-9]*\[@\]\}"' "$EXPORT_SCRIPT" || true)
    [ -z "$bare" ] || fail "array expansions must be written \${a[@]+\"\${a[@]}\"} for bash 4.2 and 4.3: $bare"
    pass "array expansions are guarded for old bash"
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
    grep -q "set IMPORT_REMOTE_DIR" "$err" ||
        fail "detect runs for the kvs-install setup, whose variable names the directory: $(cat "$err")"
    status=0
    KVS_EXPORT_SEARCH_ROOTS="$roots/empty-root" \
        run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" archive || status=$?
    [ "$status" -eq 2 ] || fail "no site must exit 2 for the archive too, got $status"
    grep -q "KVS_SITE_DIR or KVS_EXPORT_SEARCH_ROOTS" "$err" ||
        fail "the archive command must name its own variables: $(cat "$err")"

    # Control panels put the site seven levels under the root: ISPConfig
    # (/var/www/clients/client1/web1/web), DirectAdmin and Hestia under /home.
    make_site "$roots/panel/clients/client1/web1/web" "https://panel.example.com"
    KVS_EXPORT_SEARCH_ROOTS="$roots/panel" \
        run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" detect ||
        fail "a site seven levels under the root must be found: $(cat "$err")"
    assert_key "$out" site_dir "$roots/panel/clients/client1/web1/web"
    grep -q '^KVS_DEFAULT_SEARCH_ROOTS=.*:/www/wwwroot"' "$EXPORT_SCRIPT" ||
        fail "the aaPanel root /www/wwwroot must be searched by default"

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
    if run_export "$STUB_BIN:$MIN_BIN" "$out" "$err" --database-format invalid; then
        fail "an unknown database format must be refused"
    fi
    pass "the usage is available and bad options are refused"
}

make_stubs
make_min_bin
make_extra_bin

test_detect_reports_the_installation_as_key_value_lines
test_detect_reports_the_encoding_and_the_web_server_configuration
test_the_size_walk_stops_at_its_time_budget
test_the_size_walk_can_be_skipped
test_a_full_temporary_directory_does_not_shrink_the_site_size
test_detect_reports_the_entries_and_what_stays_behind
test_excluded_and_included_paths_change_what_travels
test_the_password_reaches_the_client_only_through_the_environment
test_the_connection_follows_the_host_written_in_setup_db
test_an_unreachable_database_is_reported_without_stopping_detect
test_the_dump_uses_the_compressor_that_is_installed
test_a_server_without_utf8mb4_is_dumped_as_utf8
test_native_format_selection_and_bundle_integrity
test_column_statistics_is_passed_only_to_a_tool_that_knows_it
test_gtid_state_is_left_out_by_a_tool_that_records_it
test_non_transactional_tables_switch_the_dump_to_table_locks
test_the_mysql_tools_are_used_when_the_mariadb_ones_are_absent
test_the_archive_holds_the_site_the_dump_and_the_manifest
test_the_archive_can_be_written_on_stdout
test_dump_only_writes_a_dump_next_to_the_archive
test_the_dump_is_staged_next_to_the_archive_and_outside_the_site
test_array_expansions_are_guarded_for_old_bash
test_the_site_is_searched_under_the_configured_roots
test_a_site_without_its_config_files_is_refused
test_the_script_works_when_bash_reads_it_from_stdin
test_an_unattended_run_asks_nothing
test_a_full_filesystem_stops_the_archive
test_the_usage_is_available_and_bad_options_are_refused

echo "All $TESTS_RUN export tests passed."
