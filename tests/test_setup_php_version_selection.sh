#!/bin/bash
# shellcheck disable=SC2034  # Variables are consumed by extracted production functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d -t kvs-setup-php.XXXXXX)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

extract_function() {
    local name="$1"

    awk -v signature="${name}() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$ROOT_DIR/docker/setup.sh"
}

functions_file="$TEST_DIR/functions.sh"
{
    grep -m1 '^readonly SUPPORTED_PHP_VERSIONS=' "$ROOT_DIR/docker/setup.sh"
    extract_function php_version_is_supported
    extract_function kvs_documented_php_version
    extract_function refuse_unbuildable_kvs_php
    extract_function select_php_version
} > "$functions_file"
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
# shellcheck source=/dev/null
source "$functions_file"

RED=''
GREEN=''
YELLOW=''
CYAN=''
NC=''

# The production function persists through set_env_value; record instead.
set_env_value() {
    printf '%s=%s\n' "$1" "$2" > "$TEST_DIR/applied"
}

applied_version() {
    [ -f "$TEST_DIR/applied" ] || return 1
    cut -d= -f2- < "$TEST_DIR/applied"
}

# Each case runs in its own directory holding only the archive under test.
seed_archive() {
    local version="$1"

    rm -rf "$TEST_DIR/work"
    mkdir -p "$TEST_DIR/work/kvs-archive"
    : > "$TEST_DIR/work/kvs-archive/KVS_${version}_[example.com].zip"
    rm -f "$TEST_DIR/applied"
    cd "$TEST_DIR/work"
}

run_case() {
    local description="$1"
    local expected="$2"
    shift 2

    if ! ( "$@" ) > "$TEST_DIR/out" 2>&1; then
        cat "$TEST_DIR/out" >&2
        fail "$description: selection exited non-zero"
    fi
    local actual
    actual=$(applied_version) ||
        fail "$description: no PHP version was applied"
    [ "$actual" = "$expected" ] ||
        fail "$description: expected PHP $expected, got $actual"
}

# refused <description> <KVS version> <command...>: the selection stops on a
# KVS that needs PHP 7.4, which the images cannot be built for, naming the
# version found and the reason, with nothing written.
refused() {
    local description="$1" kvs="$2"
    shift 2

    if ( "$@" ) > "$TEST_DIR/out" 2>&1; then
        fail "$description: KVS $kvs was accepted although it needs PHP 7.4: $(cat "$TEST_DIR/out")"
    fi
    grep -Fq "ERROR: KVS $kvs needs PHP 7.4, which this Docker installation does not build." "$TEST_DIR/out" ||
        fail "$description: the refusal must name KVS $kvs and PHP 7.4: $(cat "$TEST_DIR/out")"
    grep -Fq 'Debian 11, which lacks packages the PHP-FPM and cron' "$TEST_DIR/out" ||
        fail "$description: the refusal must say why: $(cat "$TEST_DIR/out")"
    grep -Fq 'Nothing was stopped or built.' "$TEST_DIR/out" ||
        fail "$description: the refusal must say that nothing changed: $(cat "$TEST_DIR/out")"
    [ ! -f "$TEST_DIR/applied" ] || fail "$description: a PHP version was written: $(cat "$TEST_DIR/applied")"
}

# 1. An encoded archive is pinned to the version KVS documents for it. KVS
# 6.2.0 and older documents PHP 7.4, whose images cannot be built (Debian 11
# lacks packages they install): such an archive is refused.
seed_archive 7.0.2
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
run_case "encoded 7.0.2" 8.1 select_php_version

# Issue #33: PHP 8.2-encoded 7.0.3 files need a newer runtime than 8.1.
for version in 7.0.3 7.0.10 7.1.0 8.0.0; do
    seed_archive "$version"
    IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
    run_case "encoded $version" 8.3 select_php_version
done
seed_archive 7.0.3
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=''
run_case "encoded 7.0.3 stays non-interactive" 8.3 select_php_version < /dev/null
IONCUBE=NO HEADLESS=y
run_case "unencoded 7.0.3 default" 8.3 select_php_version
HEADLESS=''
run_case "unencoded 7.0.3 empty answer" 8.3 select_php_version <<< ""
IONCUBE=YES KVS_PHP_VERSION=8.2 HEADLESS=y
run_case "encoded 7.0.3 explicit PHP 8.2" 8.2 select_php_version
if grep -Fq 'refuse every encoded file' "$TEST_DIR/out"; then
    fail "a PHP 8.2 override for 7.0.3 must not be described as incompatible"
fi

seed_archive 6.2.0
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
refused "encoded 6.2.0" 6.2.0 select_php_version

seed_archive 5.5.0
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
refused "encoded 5.5.0" 5.5.0 select_php_version

seed_archive 6.2.1
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
run_case "encoded 6.2.1" 8.1 select_php_version

# KVS_PHP_VERSION still names the version explicitly: an encoded archive
# gets the warning about the loader, an unencoded one the version asked.
seed_archive 6.2.0
IONCUBE=YES KVS_PHP_VERSION=8.1 HEADLESS=y
run_case "encoded 6.2.0 with KVS_PHP_VERSION" 8.1 select_php_version
grep -q "WARNING: the archive is IonCube encoded" "$TEST_DIR/out" ||
    fail "an encoded 6.2.0 archive run on PHP 8.1 must be warned about"
seed_archive 6.1.2
IONCUBE=NO KVS_PHP_VERSION=8.2 HEADLESS=y
run_case "unencoded 6.1.2 with KVS_PHP_VERSION" 8.2 select_php_version
# Without it, an unencoded archive is refused too, and no prompt is shown.
seed_archive 6.1.2
IONCUBE=NO KVS_PHP_VERSION='' HEADLESS=''
refused "unencoded 6.1.2" 6.1.2 select_php_version <<< "8.1"
grep -Fq 'KVS_PHP_VERSION set' "$TEST_DIR/out" ||
    fail "an unencoded archive must be told about KVS_PHP_VERSION: $(cat "$TEST_DIR/out")"
if grep -Fq 'PHP version to build' "$TEST_DIR/out"; then
    fail "the refused unencoded archive was asked for a version: $(cat "$TEST_DIR/out")"
fi
# PHP 7.4 is not offered at all.
seed_archive 6.2.0
IONCUBE=NO KVS_PHP_VERSION=7.4 HEADLESS=y
if ( select_php_version ) > "$TEST_DIR/out" 2>&1; then
    fail "KVS_PHP_VERSION=7.4 was accepted"
fi
if ! { grep -Fq 'Unsupported PHP version: 7.4' "$TEST_DIR/out" &&
    grep -Fq 'Supported versions: 8.1 8.2 8.3 8.4' "$TEST_DIR/out"; }; then
    fail "KVS_PHP_VERSION=7.4 must be refused with the supported versions: $(cat "$TEST_DIR/out")"
fi
[ ! -f "$TEST_DIR/applied" ] || fail "KVS_PHP_VERSION=7.4 was written to .env"

# 1b. An imported site without an archive says its version itself.
seed_no_archive() {
    rm -rf "$TEST_DIR/work"
    mkdir -p "$TEST_DIR/work/kvs-archive"
    rm -f "$TEST_DIR/applied"
    cd "$TEST_DIR/work"
}
seed_no_archive
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y IMPORT_MODE=true IMPORT_SITE_VERSION=6.2.0
refused "imported 6.2.0 without an archive" 6.2.0 select_php_version
seed_no_archive
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y IMPORT_MODE=true IMPORT_SITE_VERSION=7.0.2
run_case "imported 7.0.2 without an archive" 8.1 select_php_version
grep -q "Detected KVS version: 7.0.2" "$TEST_DIR/out" ||
    fail "the imported site's version must be the one detected"
seed_no_archive
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y IMPORT_MODE=true IMPORT_SITE_VERSION=7.0.3
run_case "imported 7.0.3 without an archive" 8.3 select_php_version
seed_no_archive
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y IMPORT_MODE=false IMPORT_SITE_VERSION=7.0.2
run_case "no archive outside an import" 8.1 select_php_version
grep -q "Could not read the KVS version" "$TEST_DIR/out" ||
    fail "outside an import the site version must not be used"
IMPORT_MODE='' IMPORT_SITE_VERSION=''

# 1c. A site in place, imported without the archive or installed from one
# since removed, says its version itself on a re-run.
seed_no_archive
mkdir -p "$TEST_DIR/site/admin/include"
cat > "$TEST_DIR/site/admin/include/version.php" <<'EOF'
<?php
$config['project_version'] = "6.2.0";
EOF
marker=$(kvs_documented_php_version "$TEST_DIR/site") ||
    fail "a site in place must give its version"
[ "$marker" = $'6.2.0\t7.4\tsite' ] ||
    fail "the version of the site in place decides the PHP release: $marker"
sed -i 's/6.2.0/7.0.3/' "$TEST_DIR/site/admin/include/version.php"
marker=$(kvs_documented_php_version "$TEST_DIR/site") ||
    fail "a 7.0.3 site in place must give its version"
[ "$marker" = $'7.0.3\t8.3\tsite' ] ||
    fail "a 7.0.3 site in place must select PHP 8.3: $marker"
rm -f "$TEST_DIR/site/admin/include/version.php"
kvs_documented_php_version "$TEST_DIR/site" > /dev/null 2>&1 &&
    fail "without version.php the site in place gives nothing"

# 1d. X2: outside an import, the site in place decides before the name of an
# archive left in kvs-archive/. kvs-init never extracts an archive over a
# site, and a site updated from the KVS admin panel runs a newer release than
# the archive it was installed from: a 7.0.2 archive name used to rebuild PHP
# 8.1 under a 7.0.3 site, and a 6.2.0 one to refuse a 6.2.1 site. The archive
# still decides for a new installation. An import takes the version of the
# imported site first, then the archive, then the copied site. A 6.2.0 site
# in place is refused even with a newer archive left, and the refusal names
# the site, since that archive is never extracted over it.
# The functions read /var/www/<domain>; these copies read a fixture instead.
# shellcheck source=/dev/null
source <(for name in kvs_documented_php_version refuse_unbuildable_kvs_php select_php_version; do
    extract_function "$name"
done | sed "s|/var/www/|$TEST_DIR/www/|g")
DOMAIN=site.example
seed_site() {
    local archive="$1" site="$2"

    seed_no_archive
    [ -z "$archive" ] || : > "kvs-archive/KVS_${archive}_[example.com].zip"
    rm -rf "$TEST_DIR/www"
    if [ -n "$site" ]; then
        mkdir -p "$TEST_DIR/www/$DOMAIN/admin/include"
        printf '%s\n' '<?php' "\$config['project_version'] = \"$site\";" > "$TEST_DIR/www/$DOMAIN/admin/include/version.php"
    fi
}
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y IMPORT_MODE=false IMPORT_SITE_VERSION=''
seed_site 7.0.2 7.0.3
run_case "site 7.0.3 in place, archive 7.0.2 left" 8.3 select_php_version
grep -q "Detected KVS version: 7.0.3" "$TEST_DIR/out" ||
    fail "the site in place must decide over a stale archive name: $(cat "$TEST_DIR/out")"
seed_site 7.0.3 7.0.2
run_case "site 7.0.2 in place, archive 7.0.3 left" 8.1 select_php_version
seed_site 6.2.0 6.2.1
run_case "site 6.2.1 in place, archive 6.2.0 left" 8.1 select_php_version
seed_site 6.2.0 ''
refused "new installation from a 6.2.0 archive" 6.2.0 select_php_version
grep -Fq 'Use an archive, or for an import a site, of KVS 6.2.1 or newer' "$TEST_DIR/out" ||
    fail "a 6.2.0 archive must be told to use a newer archive: $(cat "$TEST_DIR/out")"
seed_site 6.2.1 6.2.0
refused "site 6.2.0 in place, archive 6.2.1 left" 6.2.0 select_php_version
grep -Fq "The site in $TEST_DIR/www/$DOMAIN is KVS 6.2.0, and kvs-init does not extract an archive" "$TEST_DIR/out" ||
    fail "the refusal must name the site in place that decided: $(cat "$TEST_DIR/out")"
grep -Fq 'update that site itself to KVS 6.2.1 or newer' "$TEST_DIR/out" ||
    fail "the refusal must say to update the site in place: $(cat "$TEST_DIR/out")"
grep -Fq 'KVS_PHP_VERSION set' "$TEST_DIR/out" ||
    fail "the refusal must keep the KVS_PHP_VERSION way out: $(cat "$TEST_DIR/out")"
if grep -Fq 'Use an archive' "$TEST_DIR/out"; then
    fail "an archive is already there and is not extracted over the site: $(cat "$TEST_DIR/out")"
fi
seed_site 7.0.3 ''
run_case "new installation from a 7.0.3 archive" 8.3 select_php_version
# An import: its own version first, then the archive, then the copied site.
seed_site 7.0.2 7.0.2
IMPORT_MODE=true IMPORT_SITE_VERSION=7.0.3
run_case "import of a 7.0.3 site" 8.3 select_php_version
seed_site 7.0.3 7.0.2
IMPORT_MODE=true IMPORT_SITE_VERSION=''
run_case "import without a version, 7.0.3 archive" 8.3 select_php_version
# The copied site of an import is the import itself: another site is the way out.
seed_site '' 6.2.0
IMPORT_MODE=true IMPORT_SITE_VERSION=''
refused "import of a copied 6.2.0 site" 6.2.0 select_php_version
grep -Fq 'Use an archive, or for an import a site, of KVS 6.2.1 or newer' "$TEST_DIR/out" ||
    fail "an import must be told to import a newer site: $(cat "$TEST_DIR/out")"
IMPORT_MODE='' IMPORT_SITE_VERSION='' DOMAIN=''
rm -rf "$TEST_DIR/www"
# shellcheck source=/dev/null
source <(for name in kvs_documented_php_version refuse_unbuildable_kvs_php select_php_version; do
    extract_function "$name"
done)

# 2. An encoded archive must not silently consume a stray interactive answer.
seed_archive 7.0.2
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=''
run_case "encoded stays non-interactive" 8.1 select_php_version < /dev/null

# 3. The explicit override stays available, but it must warn first.
seed_archive 7.0.2
IONCUBE=YES KVS_PHP_VERSION=8.3 HEADLESS=y
run_case "encoded override" 8.3 select_php_version
grep -q "WARNING: the archive is IonCube encoded" "$TEST_DIR/out" ||
    fail "overriding an encoded archive did not warn about the loader"

# 4. Without IonCube the documented version is only the default.
seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION='' HEADLESS=y
run_case "unencoded default" 8.1 select_php_version

seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION=8.4 HEADLESS=y
run_case "unencoded override" 8.4 select_php_version

# 5. Interactively, an empty answer keeps the default and a version is taken.
seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION='' HEADLESS=''
run_case "unencoded empty answer" 8.1 select_php_version <<< ""

seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION='' HEADLESS=''
run_case "unencoded interactive answer" 8.3 select_php_version <<< "8.3"

# 6. Unsupported versions are rejected before anything is written.
seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION=8.9 HEADLESS=y
if ( select_php_version ) > "$TEST_DIR/out" 2>&1; then
    fail "an unsupported PHP version was accepted"
fi
grep -q "Unsupported PHP version: 8.9" "$TEST_DIR/out" ||
    fail "rejecting an unsupported version did not explain why"
[ ! -f "$TEST_DIR/applied" ] ||
    fail "an unsupported version was written to .env"

seed_archive 7.0.2
IONCUBE=YES KVS_PHP_VERSION=5.6 HEADLESS=y
if ( select_php_version ) > "$TEST_DIR/out" 2>&1; then
    fail "an unsupported PHP version was accepted for an encoded archive"
fi
[ ! -f "$TEST_DIR/applied" ] ||
    fail "an unsupported version was written for an encoded archive"

seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION='' HEADLESS=''
if ( select_php_version ) > "$TEST_DIR/out" 2>&1 <<< "8.9"; then
    fail "an unsupported interactive answer was accepted"
fi
[ ! -f "$TEST_DIR/applied" ] ||
    fail "an unsupported interactive answer was written to .env"

# 7. A missing or unreadable archive falls back without failing the install.
rm -rf "$TEST_DIR/work"
mkdir -p "$TEST_DIR/work/kvs-archive"
rm -f "$TEST_DIR/applied"
cd "$TEST_DIR/work"
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
run_case "missing archive" 8.1 select_php_version

seed_archive 7.0.2
mv "kvs-archive/KVS_7.0.2_[example.com].zip" "kvs-archive/KVS_unreleased.zip"
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
run_case "unparsable archive name" 8.1 select_php_version

# 8. Wiring: a KVS that needs PHP 7.4 is refused as soon as its version can
# be known, before the import is confirmed or recorded, and before anything
# of a running stack is removed, stopped or built.
setup="$ROOT_DIR/docker/setup.sh"

# line_of <line>: the number of the one line of setup.sh that is exactly it.
line_of() {
    local found

    found=$(grep -nxF -- "$1" "$setup" | cut -d: -f1)
    [ -n "$found" ] || fail "setup.sh has no line '$1'"
    [ "$(printf '%s\n' "$found" | wc -l)" -eq 1 ] || fail "setup.sh has more than one line '$1'"
    printf '%s\n' "$found"
}

# first_line_with <text>: the number of the first line of setup.sh holding it.
first_line_with() {
    local found

    found=$(grep -nF -m 1 -- "$1" "$setup" | cut -d: -f1)
    [ -n "$found" ] || fail "setup.sh has no line holding '$1'"
    printf '%s\n' "$found"
}

# line_in_function <function> <line>: the number of that exact line in the
# body of the function.
line_in_function() {
    local found

    found=$(awk -v signature="$1() {" -v want="$2" '
        $0 == signature { inside = 1 }
        inside && $0 == want { print NR; exit }
        inside && /^}$/ { exit }
    ' "$setup")
    [ -n "$found" ] || fail "$1 in setup.sh has no line '$2'"
    printf '%s\n' "$found"
}

# comes_before <first> <second> <message>
comes_before() {
    [ "$1" -lt "$2" ] || fail "$3 (line $1 is not before line $2)"
}

refusal=$(line_of 'refuse_unbuildable_kvs_php || exit 1')
comes_before "$(line_of 'select_import_source')" "$refusal" \
    "the refusal must come once the import source, and so the site version, is known"
comes_before "$(line_of 'import_check_leftover_dump')" "$refusal" \
    "the refusal must come after the check of a leftover dump"
comes_before "$refusal" "$(line_of 'retirement_prepare_identity || exit 1')" \
    "the refusal must come before preparing the changed-domain identity"
comes_before "$refusal" "$(line_of 'retirement_finish || exit 1')" \
    "the refusal must come before the containers of an earlier stack are removed"
comes_before "$refusal" "$(line_of 'choose_mariadb_version')" \
    "the refusal must come before the MariaDB series is chosen"
comes_before "$refusal" "$(line_of 'configure_mode || exit $?')" \
    "the refusal must come before the mode is configured"
# shellcheck disable=SC2016  # The literal line of setup.sh.
comes_before "$refusal" "$(line_of 'COMPOSE_FILE=$(compose_files_for "$MODE") require_compose_config || exit 1')" \
    "the refusal must come before Compose reads the files and the choices that remove containers"
comes_before "$refusal" "$(first_line_with 'echo "Stopping existing containers..."')" \
    "the refusal must come before the running containers are stopped"
comes_before "$refusal" "$(first_line_with 'docker compose build')" \
    "the refusal must come before anything is built"

in_import=$(line_in_function select_import_source '    refuse_unbuildable_kvs_php || exit 1')
comes_before "$(line_in_function select_import_source '    import_check_kvs_archive_version')" "$in_import" \
    "an import is refused once its site has been inspected"
comes_before "$in_import" "$(line_in_function select_import_source '    import_record_source_domain')" \
    "an import is refused before .env records its source"
comes_before "$in_import" "$(line_in_function select_import_source '    import_confirm')" \
    "an import is refused before the operator is asked to confirm it"

in_selection=$(line_in_function select_php_version '    refuse_unbuildable_kvs_php || exit 1')
# shellcheck disable=SC2016  # The literal line of setup.sh.
comes_before "$in_selection" "$(line_in_function select_php_version '        set_env_value PHP_VERSION "$documented"')" \
    "the selection refuses before it writes the documented version"

cd "$ROOT_DIR"
echo "PASS: Setup PHP version selection"
