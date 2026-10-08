#!/bin/bash
# shellcheck disable=SC2034  # Variables are consumed by extracted production functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-setup-php.XXXXXX)

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
[ "$marker" = $'6.2.0\t7.4' ] ||
    fail "the version of the site in place decides the PHP release: $marker"
rm -f "$TEST_DIR/site/admin/include/version.php"
kvs_documented_php_version "$TEST_DIR/site" > /dev/null 2>&1 &&
    fail "without version.php the site in place gives nothing"

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
comes_before "$refusal" "$(first_line_with 'Removing the containers of')" \
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
