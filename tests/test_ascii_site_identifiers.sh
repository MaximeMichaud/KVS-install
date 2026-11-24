#!/bin/bash
# shellcheck disable=SC2015  # Any failed part of an assertion must call fail.
# shellcheck disable=SC2016,SC2034,SC2329  # Match literal shell code; extracted functions use fixture variables and stubs.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

# C.UTF-8 does not reproduce language-specific collation on glibc.
language=en_US.UTF-8
if ! LC_ALL="$language" locale charmap 2>/dev/null | grep -iq '^UTF-8$'; then
    mkdir locales
    if ! localedef --no-archive -i en_US -f UTF-8 "$work/locales/$language" 2>/dev/null; then
        echo 'SKIP: en_US.UTF-8 is unavailable and cannot be generated locally.'
        exit 0
    fi
    export LOCPATH="$work/locales"
fi
export LC_ALL="$language"

locales=(C "$language")
if LC_ALL=ja_JP.UTF-8 locale charmap 2>/dev/null | grep -iq '^UTF-8$'; then
    locales+=(ja_JP.UTF-8)
fi

extract() { sed -n "/^\(function \)\?$2() {/,/^}/p" "$root/$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
log_error() { :; }
MAX_DOMAIN_LENGTH=64 MAX_SITE_PREFIX_LENGTH=235
# shellcheck source=/dev/null
source "$root/docker/lib/host-validation.sh"
for file in docker/setup.sh docker/reconfigure.sh docker/multi-site/site-manager.sh kvs-install.sh; do
    fn=validate_domain
    if [ "$file" = kvs-install.sh ]; then fn=validate_kvs_domain; fi
    # shellcheck source=/dev/null
    source <(extract "$file" "$fn")
    for domain in café.example.test münchen.test Kvs.test; do
        if "$fn" "$domain"; then fail "$file accepted $domain"; fi
    done
    "$fn" xn--mnchen-3ya.test || fail "$file refused ASCII punycode"
    [ "$LC_ALL" = "$language" ] || fail "$file changed the caller locale"
done
for file in docker/setup.sh docker/multi-site/site-manager.sh; do
    # shellcheck source=/dev/null
    source <(extract "$file" validate_site_prefix)
    for prefix in kvs-é kvs-münchen kvs-ß; do
        if validate_site_prefix "$prefix"; then fail "$file accepted $prefix"; fi
    done
    validate_site_prefix kvs-site_1 || fail "$file refused an ASCII project name"
done

# An early Unicode case conversion can turn the Kelvin sign into ASCII k
# before the domain reaches its validator.
# shellcheck source=/dev/null
source <(extract kvs-install.sh archive_domain_from_name)
[ "$(archive_domain_from_name 'KVS_7.0.2_[Kvs.test].zip')" = Kvs.test ] || fail "archive reader folded Unicode"
# shellcheck source=/dev/null
source <(extract docker/setup.sh lowercase_domain)
domain_setup=$(sed -n '/^if \[ -n "\$KVS_DOMAIN_OVERRIDE" \]; then/,/^if \[ "\$KVS_EMAIL_OVERRIDE_SET" = true \]; then/{ /^if \[ "\$KVS_EMAIL_OVERRIDE_SET" = true \]; then/!p; }' "$root/docker/setup.sh")
KVS_DOMAIN_OVERRIDE=Kvs.test
eval "$domain_setup"
[ "$DOMAIN" = Kvs.test ] || fail "setup folded Unicode before validation"
KVS_DOMAIN_OVERRIDE=SITE.TEST
eval "$domain_setup"
[ "$DOMAIN" = site.test ] || fail "setup did not lowercase ASCII"

# Exercise the interactive normalization too. The first answer must prompt
# again; the second remains a valid ASCII name.
# shellcheck source=/dev/null
source <(extract docker/setup.sh validate_domain)
prompt_read() {
    if [ -e asked ]; then DOMAIN=SITE.TEST; else touch asked; DOMAIN=Kvs.test; fi
}
DOMAIN=example.com HEADLESS='' RED='' NC=''
eval "$(sed -n '/^# Prompt for domain$/,/^fi$/p' "$root/docker/setup.sh")" > prompt.log
[ "$DOMAIN" = site.test ] || fail "setup accepted the first interactive answer"

# Both installer entry points must pass the original input to validation.
# shellcheck source=/dev/null
source <(extract kvs-install.sh validate_kvs_domain; extract kvs-install.sh whatisdomain)
find_kvs_archive() { echo 'KVS_7.0.2_[Kvs.test].zip'; }
unzip() { :; }
set_site_hostnames() { :; }
URL=unused DOMAIN=''
if (whatisdomain) > native.log 2>&1; then fail "standalone folded Unicode before validation"; fi
grep -Fq "Invalid or empty domain extracted" native.log || fail "unexpected standalone refusal"
# shellcheck source=/dev/null
source <(extract kvs-install.sh saved_site_domain)
touch .env
green='' yellow='' normal='' archive_domain='' DOMAIN=Kvs.test
saved_domain=$(saved_site_domain ./.env)
wrapper_domain=$(extract kvs-install.sh docker_install_locked | sed -n '/^  # An explicit DOMAIN from the environment wins/,/^  # Email,/{/^  # Email,/!p;}')
[ -n "$wrapper_domain" ] || fail "missing domain selection in the Docker wrapper"
eval "$wrapper_domain" > wrapper.log
[ ! -s wrapper.log ] || fail "Docker wrapper accepted a Unicode domain"
[ "$DOMAIN" = Kvs.test ] || fail "Docker wrapper folded Unicode before validation"

legacy_warning() {
    grep -Fq 'non-ASCII' "$1" && grep -Fq 'already uses' "$1" &&
        grep -Fq 'tables' "$1" && grep -Fq 'setup.php' "$1" && grep -Fq '.env' "$1"
}
# A fresh import is refused. Existing readers must retain the spelling.
# shellcheck source=/dev/null
source <(extract docker/setup.sh kvs_tables_prefix)
IMPORT_MODE=true IMPORT_TABLES_PREFIX=café_
if kvs_tables_prefix > value 2> warning; then fail "setup accepted a new Unicode prefix"; fi
KVS_PATH="$work/site"
mkdir -p "$KVS_PATH/admin/include"
echo "\$config['tables_prefix']='café_';" > "$KVS_PATH/admin/include/setup.php"
# shellcheck source=/dev/null
source <(extract kvs-install.sh kvs_tables_prefix)
for lang in "${locales[@]}"; do
    [ "$(LC_ALL=$lang kvs_tables_prefix 2> warning)" = café_ ] && legacy_warning warning || fail "standalone lost its prefix under $lang"
done
(
    # shellcheck source=/dev/null
    source <(extract kvs-install.sh configure_kvs_system_settings; extract kvs-install.sh configure_kvs_servers; extract kvs-install.sh configure_kvs_servers_tls; extract kvs-install.sh provision_kvs_database)
    # shellcheck source=/dev/null
    source <(extract kvs-install.sh kvs_storage_port_pattern; extract kvs-install.sh kvs_local_storage_origin)
    DOMAIN=site.test URL=site.test CERTIFICATE_MODE=public
    origin=$(kvs_local_storage_origin) || fail "cannot read the local storage origin"
    [[ https://site.test:8443 =~ ${origin}$ ]] || fail "local storage origin does not match the site and port"
    [[ ! https://other.test:8443 =~ ${origin}$ ]] || fail "local storage origin matches another site"
    mariadb() { echo called >> queries; return 1; }
    kvs_tables_prefix() { return 1; }
    for operation in configure_kvs_system_settings configure_kvs_servers configure_kvs_servers_tls provision_kvs_database; do
        if "$operation" "$KVS_PATH" site.test fixture; then fail "$operation ignored the prefix reader"; fi
        [ ! -e queries ] || fail "$operation ran SQL after the prefix reader failed"
    done
)
# shellcheck source=/dev/null
source <(extract docker/multi-site/site-manager.sh env_file_value; extract docker/multi-site/site-manager.sh site_tables_prefix; extract docker/multi-site/site-manager.sh archive_tables_prefix)
echo 'TABLES_PREFIX=café_' > .env
for lang in "${locales[@]}"; do
    [ "$(LC_ALL=$lang site_tables_prefix 2> warning)" = café_ ] && legacy_warning warning || fail "multi-site lost its prefix under $lang"
done
unzip() { cat "$KVS_PATH/admin/include/setup.php"; }
if archive_tables_prefix site.zip > value 2> warning; then fail "multi-site accepted a Unicode archive prefix"; fi

# Run the saved-state checks up to the next preflight step.
# shellcheck source=/dev/null
source <(extract docker/setup.sh validate_domain)
saved_checks=$(sed -n '/^    if ! validate_domain "\${DOMAIN:-}"/,/^    check_mariadb_stop_grace_period/{/check_mariadb_stop_grace_period/!p;}' "$root/docker/setup.sh")
saved() { eval "$saved_checks"; }
DOMAIN=site.test TABLES_PREFIX=ktvs_ COMPOSE_PROJECT_NAME=kvs-site
saved || fail "resume refused ASCII settings"
for lang in "${locales[@]}"; do
    LC_ALL=$lang TABLES_PREFIX=café_ saved 2> warning && legacy_warning warning || fail "resume lost its prefix under $lang"
done
if COMPOSE_PROJECT_NAME=kvs-é saved 2>/dev/null; then fail "resume accepted a Unicode project name"; fi
remote_checks=$(extract docker/setup.sh import_inspect_remote | sed -n '/^    if \[ -z "\$IMPORT_SITE_VERSION" \]/,/^    multi=/{/^    multi=/!p;}')
IMPORT_SITE_VERSION=7.0.0 IMPORT_OLD_PATH=/fixture prefix=café_
if (eval "$remote_checks") >/dev/null; then fail "remote import accepted a Unicode table prefix"; fi

# Read the site configuration through the same readers used by directory
# imports, archive preflight, setup and the container's initialization.
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
# shellcheck source=/dev/null
source "$root/docker/lib/native-import.sh"
# shellcheck source=/dev/null
source "$root/docker/init/lib/common.sh"
# shellcheck source=/dev/null
source "$root/docker/lib/import-resume.sh"
for lang in "${locales[@]}"; do
    LC_ALL=$lang import_resume_identifiers site.test café_ || fail "invalid recovery prefix under $lang"
    if LC_ALL=$lang import_resume_identifiers café.test ktvs_ 2>/dev/null; then fail "accepted non-ASCII recovery database"; fi
done
KVS_PATH="$work/site"
# shellcheck source=/dev/null
source <(extract docker/setup.sh kvs_tables_prefix; extract docker/setup.sh setup_kvs_archive; extract docker/setup.sh setup_php_config_value; extract docker/setup.sh set_env_value; extract docker/setup.sh remove_env_value)
touch "$KVS_PATH/admin/include/setup_db.php"
echo "\$config['project_version']='7.0.2';" > "$KVS_PATH/admin/include/version.php"
for prefix in café_ Site42_; do
    printf "%s\n" "\$config['project_path']='/site';" "\$config['tables_prefix']='$prefix';" > "$KVS_PATH/admin/include/setup.php"
    if [ "$prefix" = café_ ]; then
        if import_validate_site "$KVS_PATH" > site.info 2> site.err; then fail "accepted a Unicode import prefix"; fi
        [ "$(get_tables_prefix 2> warning)" = café_ ] && legacy_warning warning || fail "init lost its installed prefix"
        for lang in "${locales[@]}"; do
            [ "$(LC_ALL=$lang get_tables_prefix 2> warning)" = café_ ] && legacy_warning warning || fail "init changed prefix under $lang"
        done
        import_validate_site "$KVS_PATH" café_ > site.info && [ "$(import_field "$(cat site.info)" 3)" = café_ ] || fail "resume rejected its installed site"
        if import_validate_site "$KVS_PATH" other_ >/dev/null 2>&1; then fail "resume accepted another prefix"; fi
        (
            IMPORT_MODE=false
            mkdir -p kvs-archive
            # Map only the webroot into this fixture, including on systems without /var/www.
            # shellcheck source=/dev/null
            source <(extract docker/setup.sh kvs_tables_prefix | sed 's@/var/www/@$work/@g')
            DOMAIN=site
            for state in php-only saved-only both; do
                case $state in
                    php-only) unset TABLES_PREFIX; : > .env ;;
                    saved-only) DOMAIN=unmounted.test; echo TABLES_PREFIX=café_ > .env ;;
                    both) DOMAIN=site; echo TABLES_PREFIX=café_ > .env ;;
                esac
                # shellcheck source=/dev/null
                source ./.env
                eval "$(sed -n '/^TABLES_PREFIX=$(kvs_tables_prefix)/,+1p' "$root/docker/setup.sh")" 2> warning
                grep -Fxq TABLES_PREFIX=café_ .env && legacy_warning warning || fail "setup lost $state legacy prefix"
            done
            for lang in "${locales[@]}"; do
                [ "$(LC_ALL=$lang kvs_tables_prefix 2> warning)" = café_ ] && legacy_warning warning || fail "setup changed prefix under $lang"
            done
            TABLES_PREFIX=other_
            if kvs_tables_prefix > value 2> warning; then fail "accepted divergent installed prefixes"; fi
            grep -Fq 'differs' warning || fail "missing conflict diagnostic"

            # Exercise receipt cleanup with the actual saved database and prefix.
            # shellcheck source=/dev/null
            source <(extract docker/setup.sh import_check_leftover_dump | sed 's@/var/www/@$work/@g')
            # shellcheck source=/dev/null
            source <(extract docker/setup.sh import_remove_transfers; extract docker/setup.sh import_protect_supplied_dump)
            mkdir -p mariadb/init
            touch mariadb/init/10-kvs-import.sql
            run_root_mariadb() { echo "$*" >> queries; }
            KVS_IMPORT_COMPLETED=previous
            # The clean child requires an ASCII hostname; map that name to the fixture.
            ln -s site "$work/site.test"
            printf '%s\n' DOMAIN=site.test TABLES_PREFIX=other_ > .env
            if (import_check_leftover_dump) > value 2> warning; then fail "cleaned a conflicting site"; fi
            [ ! -e queries ] && [ -f mariadb/init/10-kvs-import.sql ] && grep -Fq differs warning || fail "checked conflict after cleanup"
            echo TABLES_PREFIX=café_ >> .env
            for lang in "${locales[@]}"; do
                touch mariadb/init/10-kvs-import.sql
                (LC_ALL=$lang import_check_leftover_dump) > value 2> warning || fail "cleanup refused its saved prefix under $lang"
                grep -Fq 'DELETE FROM café_options ' queries || fail "cleanup used the wrong prefix"
                rm queries
            done

            echo "\$config['tables_prefix']=SITE_TABLE_PREFIX;" > "$KVS_PATH/admin/include/setup.php"
            [ "$(kvs_tables_prefix)" = other_ ] || fail "treated an unknown PHP expression as a conflicting prefix"
            echo "\$config['tables_prefix']='other' . '_';" > "$KVS_PATH/admin/include/setup.php"
            [ "$(kvs_tables_prefix)" = other_ ] || fail "treated part of a PHP expression as its prefix"
            DOMAIN=empty.test
            mkdir -p kvs-archive
            touch kvs-archive/KVS_7.0.2_empty.test.zip
            unzip() { echo "\$config['tables_prefix']='ktvs_';"; }
            [ "$(kvs_tables_prefix)" = ktvs_ ] || fail "saved prefix overrode the selected archive"
        )
    else
        import_validate_site "$KVS_PATH" > site.info || fail "refused ASCII import prefix"
        IMPORT_TABLES_PREFIX=$(import_field "$(cat site.info)" 3)
        [ "$IMPORT_TABLES_PREFIX" = "$prefix" ] && [ "$(kvs_tables_prefix)" = "$prefix" ] &&
            [ "$(get_tables_prefix)" = "$prefix" ] || fail "site, setup and init prefixes differ"
    fi
done
for database in site.test café.test; do
    printf '%s\n' format=1 complete=yes "source_database=$database" tables_prefix=Site42_ kvs_version=7.0.2 tables=1 > manifest
    if native_import_metadata manifest Site42_; then
        [ "$database" = site.test ] || fail "accepted Unicode native source database"
    else
        [ "$database" = café.test ] || fail "rejected ASCII native source database"
    fi
done
if native_import_prepare unused Site42_ 7.0.2 /old /new stage token café.test > refusal.log 2>&1; then
    fail "accepted Unicode native destination database"
fi
grep -Fq 'invalid destination database name' refusal.log || fail "did not validate native destination database"

# Run a real reconfiguration entry point. Stop at the database boundary.
mkdir -p instance/docker/lib
cp "$root/docker/reconfigure.sh" instance/docker/
mkdir -p "instance/docker/lib"
cp "$root/docker/lib/host-validation.sh" "instance/docker/lib/"
touch instance/docker/docker-compose.yml
echo 'database_wait_ready() { echo runtime-reached; echo "runtime-prefix=$TABLES_PREFIX"; }' > instance/docker/lib/database.sh
for project in kvs-site_1 kvs-é; do
    printf '%s\n' DOMAIN=site.test MARIADB_PASSWORD=fixture "SITE_PREFIX=$project" > instance/docker/.env
    if (cd instance/docker && bash reconfigure.sh --import-status) > project.log 2>&1; then
        [ "$project" = kvs-site_1 ] || fail "accepted $project"
        grep -Fxq runtime-reached project.log || fail "accepted $project"
    else
        [ "$project" = kvs-é ] || fail "refused $project"
        grep -Fq 'existing Compose project name' project.log &&
            grep -Fq 'SITE_PREFIX is invalid in .env' project.log || fail "unexpected project refusal"
    fi
done

printf '%s\n' DOMAIN=café.test SITE_PREFIX=kvs-site MARIADB_PASSWORD=fixture > instance/docker/.env
if (cd instance/docker && bash reconfigure.sh --import-status) > project.log 2>&1; then fail "accepted saved Unicode domain"; fi
grep -Fq 'DOMAIN' project.log && grep -Fq 'punycode' project.log && grep -Fq '.env' project.log || fail "missing saved domain guidance"
printf '%s\n' DOMAIN=site.test SITE_PREFIX=kvs-site MARIADB_PASSWORD=fixture > instance/docker/.env
if (cd instance/docker && TABLES_PREFIX=café_ bash reconfigure.sh --import-status) > project.log 2>&1; then fail "accepted an inherited Unicode prefix"; fi
echo TABLES_PREFIX=café_ >> instance/docker/.env
for lang in "${locales[@]}"; do
    (cd instance/docker && LC_ALL=$lang bash reconfigure.sh --import-status) > project.log 2>&1 || fail "reconfigure refused its installed prefix under $lang"
    legacy_warning project.log && grep -Fxq runtime-prefix=café_ project.log && grep -Fxq TABLES_PREFIX=café_ instance/docker/.env && grep -Fxq runtime-reached project.log ||
        fail "reconfigure lost its legacy prefix under $lang"
done

# Exercise both the URL reader and the direct host from an SSH report.
# shellcheck source=/dev/null
source <(extract docker/setup.sh import_check_domain; extract docker/setup.sh import_record_source_domain; extract docker/setup.sh set_env_value; extract docker/setup.sh remove_env_value)
for host in SITE.TEST café.test Kvs.test; do
    for input in url report; do
        echo 'IMPORT_SOURCE_DOMAIN=stale.test' > .env
        if [ "$input" = url ]; then
            IMPORT_DETECTED_DOMAIN=$(import_url_domain "https://www.$host:443/path")
            if [ "$host" != SITE.TEST ] && [ -n "$IMPORT_DETECTED_DOMAIN" ]; then fail "URL accepted $host"; fi
        else
            IMPORT_DETECTED_DOMAIN=$host
        fi
        import_record_source_domain || fail "could not update source domain"
        if [ "$input" = report ]; then
            DOMAIN=new.test HEADLESS=y YELLOW='' NC='' import_check_domain > notice
            if [ "$host" = SITE.TEST ]; then
                grep -Fq 'storage URLs on site.test become https://new.test' notice || fail "lost ASCII rewrite notice"
            else
                grep -Fq "Storage URLs on $host are kept unchanged" notice || fail "promised to rewrite Unicode source"
            fi
        fi
        if [ "$host" = SITE.TEST ]; then
            grep -Fxq 'IMPORT_SOURCE_DOMAIN=site.test' .env || fail "lost ASCII source domain"
        elif grep -q '^IMPORT_SOURCE_DOMAIN=' .env; then
            fail "recorded $host from $input"
        fi
    done
done

# Reach both native export checks with a local metadata result, stopping
# before the exporter tries to open a database socket or write a bundle.
# shellcheck source=/dev/null
source <(extract kvs-export.sh kvs_select_database_format)
DB_PASSWORD='' OPT_DATABASE_FORMAT=directory DB_OK=yes DB_DUMP_TOOL=help_dump DB_HOST_RAW=localhost
KVS_VERSION=7.0.0 DB_NAME=site.test TABLES_PREFIX=ktvs_
help_dump() { echo '--dir --parallel'; }
kvs_tool_advertises() { return 0; }
id() { echo 0; }
kvs_directory_query() { printf 'table\t%s\n' "$table"; }
kvs_directory_refuse() { echo "$1"; return 1; }
refusal() {
    local reason
    if reason=$(kvs_select_database_format); then fail "native export accepted unsupported metadata"; fi
    [ "$reason" = "$1" ] || fail "unexpected native export decision: $reason"
}
table=ktvs_options
DB_NAME=café.test refusal 'the database name or table prefix is not supported by the native bundle'
TABLES_PREFIX=café_ refusal 'the database name or table prefix is not supported by the native bundle'
table=café_options refusal 'a table name is not supported by the native bundle'
refusal 'the source schema compatibility counts could not be verified'

# The import progress query takes the prefix as SQL text: the same values
# must reach it under every locale, and none that is not ASCII. Another
# prefix loses the table count alone; the rows that do not use it still run
# and the progress line says "? tables created" with their figures.
# shellcheck source=/dev/null
source <(extract docker/lib/database.sh database_import_snapshot; extract docker/lib/database.sh database_progress_line; extract docker/lib/database.sh database_size_text)
database_root_query() {
    cat > snapshot.sql
    ! grep -q "^SELECT 'tables'" snapshot.sql || printf 'tables\t7\n'
    grep -q "^SELECT 'pool'" snapshot.sql && grep -q "^SELECT 'active'" snapshot.sql || return 1
    printf 'pool\t134217728\nactive\t1\n'
}
long_prefix=$(printf 'x%.0s' {1..33})
for lang in "${locales[@]}"; do
    for prefix in café_ ｋ_ a²_ a™_ 'a b_' "a'_" "$long_prefix"; do
        rm -f snapshot.sql
        snapshot=$(TABLES_PREFIX=$prefix LC_ALL=$lang DOMAIN=site.test database_import_snapshot) ||
            fail "the import progress query was dropped for prefix '$prefix' under $lang"
        ! grep -Fq -- "$prefix" snapshot.sql || fail "prefix '$prefix' reached the SQL text under $lang"
        ! grep -q "information_schema.tables" snapshot.sql || fail "tables were counted for prefix '$prefix' under $lang"
        line=$(LC_ALL=$lang database_progress_line 5 "$snapshot" '')
        [[ "$line" == *'; ? tables created; buffer pool 128.0 MiB; 1 active SQL sessions'* ]] ||
            fail "wrong progress line for prefix '$prefix' under $lang: $line"
    done
    for prefix in ktvs_ Abc_9 ''; do
        rm -f snapshot.sql
        snapshot=$(TABLES_PREFIX=$prefix LC_ALL=$lang DOMAIN=site.test database_import_snapshot) ||
            fail "the import progress query refused prefix '$prefix' under $lang"
        grep -Fq "LENGTH('${prefix:-ktvs_}'))='${prefix:-ktvs_}'" snapshot.sql ||
            fail "the import progress query lost prefix '$prefix' under $lang"
        line=$(LC_ALL=$lang database_progress_line 5 "$snapshot" '')
        [[ "$line" == *'; 7 tables created; buffer pool 128.0 MiB'* ]] || fail "wrong progress line for '$prefix' under $lang: $line"
    done
done
echo 'ASCII domain, project and database identifier checks passed.'
