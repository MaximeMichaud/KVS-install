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
    extract_function version_at_least
    extract_function saved_php_version
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

# The production function persists through set_env_value; record instead,
# or append to .env where a case reads back what a run saves.
set_env_value() {
    if [ "${APPEND_TO_ENV:-}" = yes ]; then
        printf '%s=%s\n' "$1" "$2" >> .env
    else
        printf '%s=%s\n' "$1" "$2" > "$TEST_DIR/applied"
    fi
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
source <(for name in saved_php_version kvs_documented_php_version refuse_unbuildable_kvs_php select_php_version; do
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

# 1e. U4: a re-run keeps the series the site in place runs, saved in .env,
# unless KVS_PHP_VERSION or the prompt names another one. A headless re-run
# used to write the documented series back (8.4 to 8.1 for an unencoded
# 7.0.2 site, 8.2 to 8.1 for an encoded one installed with KVS_PHP_VERSION),
# and an unencoded 6.1 site moved to PHP 8.2 was refused on every re-run.
# For encoded files a newer documented series still wins (Issue #33). A run
# saves the base of the series it selected beside it (set_php_bases): a
# PHP_VERSION without the PHP_FPM_BASE of its series was not selected by a
# run, and is not kept.
# seed_rerun <site version> <.env content>: a site in place, installed by an
# earlier run whose .env this run reads.
seed_rerun() {
    seed_site '' "$1"
    : > "$TEST_DIR/www/$DOMAIN/admin/include/setup.php"
    printf '%b' "$2" > .env
}
# saved <series>: the lines a run that selected the series leaves in .env.
saved() {
    printf 'PHP_VERSION=%s\nPHP_FPM_BASE=%s\n' "$1" "$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get php-fpm "$1")"
}
# setup.sh reads .env again right before the selection, so PHP_VERSION holds
# the saved value there (or nothing).
setup_selects() {
    PHP_VERSION=
    # shellcheck source=/dev/null
    source ./.env
    select_php_version
}
IMPORT_MODE=false IMPORT_SITE_VERSION='' KVS_PHP_VERSION='' HEADLESS=y
IONCUBE=NO
seed_rerun 7.0.2 "$(saved 8.4)\nIONCUBE=NO\n"
run_case "re-run of an unencoded 7.0.2 site on PHP 8.4" 8.4 setup_selects
grep -Fq 'The site runs PHP 8.4 (PHP_VERSION in .env), the default.' "$TEST_DIR/out" ||
    fail "the kept series must be named: $(cat "$TEST_DIR/out")"
HEADLESS=''
run_case "Enter on a re-run of an unencoded site on PHP 8.4" 8.4 setup_selects <<< ""
grep -Fq '(default: 8.4)' "$TEST_DIR/out" ||
    fail "the prompt must offer the saved series as its default: $(cat "$TEST_DIR/out")"
run_case "an answer on a re-run of an unencoded site" 8.2 setup_selects <<< "8.2"
HEADLESS=y KVS_PHP_VERSION=8.3
run_case "KVS_PHP_VERSION on a re-run of an unencoded site" 8.3 setup_selects
KVS_PHP_VERSION=''
# The value saved in .env decides, quoted as .env may write it, not a
# PHP_VERSION of the shell: the early refusal runs before setup.sh reads
# .env again.
seed_rerun 7.0.2 "PHP_VERSION=\"8.2\"\nPHP_FPM_BASE=\"$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get php-fpm 8.2)\"\n"
run_case "a quoted saved series" 8.2 setup_selects
PHP_VERSION=8.4 run_case "a shell PHP_VERSION is not the saved series" 8.2 select_php_version
seed_rerun 7.0.2 'IONCUBE=NO\n'
PHP_VERSION=8.4 run_case "a .env without PHP_VERSION saves no series" 8.1 select_php_version
seed_rerun 6.1.2 'IONCUBE=NO\n'
PHP_VERSION=8.2 refused "a 6.1.2 site with no saved series" 6.1.2 refuse_unbuildable_kvs_php
seed_rerun 7.0.2 'PHP_VERSION=7.4\nPHP_FPM_BASE=php:7.4-fpm\n'
run_case "a saved series this stack does not build" 8.1 setup_selects
# A PHP_VERSION no run selected: the fallback of .env.example, copied by
# setup.sh or by kvs-install.sh before it starts setup.sh (its PHP_FPM_BASE
# is empty), one changed by hand since the base was saved, or a .env of a
# release before 26.10.0, which saved no base.
grep -qx 'PHP_FPM_BASE=' "$ROOT_DIR/docker/.env.example" ||
    fail ".env.example must leave PHP_FPM_BASE empty: no run selected its PHP_VERSION"
seed_rerun 7.0.3 ''
sed "s/^DOMAIN=.*/DOMAIN=$DOMAIN/" "$ROOT_DIR/docker/.env.example" > .env
run_case "a .env copied from .env.example" 8.3 setup_selects
seed_rerun 7.0.2 "PHP_VERSION=8.4\nPHP_FPM_BASE=$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get php-fpm 8.1)\n"
run_case "a PHP_VERSION changed by hand since" 8.1 setup_selects
# A PHP_FPM_BASE of the shell is not the one saved either.
seed_rerun 7.0.2 'PHP_VERSION=8.4\nIONCUBE=NO\n'
PHP_FPM_BASE=$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get php-fpm 8.4) \
    run_case "a .env from a release before 26.10.0" 8.1 setup_selects
# Only a re-run on a site in place: a new installation, or an import,
# selects as before.
seed_rerun 7.0.3 "$(saved 8.1)\n"
rm -f "$TEST_DIR/www/$DOMAIN/admin/include/setup.php"
run_case "no site in place" 8.3 setup_selects
seed_rerun 7.0.3 "$(saved 8.1)\n"
IMPORT_MODE=true IMPORT_SITE_VERSION=7.0.3
run_case "an import" 8.3 setup_selects
IMPORT_MODE=false IMPORT_SITE_VERSION=''
# 6.1 needs PHP 7.4: a site an earlier run moved to 8.2 with KVS_PHP_VERSION
# stays there, before and inside the selection; without that run it is
# refused as before.
seed_rerun 6.1.2 "$(saved 8.2)\nIONCUBE=NO\n"
( refuse_unbuildable_kvs_php ) > "$TEST_DIR/out" 2>&1 ||
    fail "an unencoded 6.1.2 site on PHP 8.2 was refused on a re-run: $(cat "$TEST_DIR/out")"
run_case "re-run of an unencoded 6.1.2 site on PHP 8.2" 8.2 setup_selects
seed_rerun 6.1.2 ''
sed "s/^DOMAIN=.*/DOMAIN=$DOMAIN/" "$ROOT_DIR/docker/.env.example" > .env
refused "a 6.1.2 site with a .env copied from .env.example" 6.1.2 setup_selects
seed_rerun 6.1.2 'PHP_VERSION=8.2\n'
refused "a 6.1.2 site whose PHP_VERSION no run selected" 6.1.2 setup_selects
seed_rerun 6.1.2 "$(saved 8.2)\n"
rm -f "$TEST_DIR/www/$DOMAIN/admin/include/setup.php"
refused "a 6.1.2 archive with no site in place" 6.1.2 setup_selects
# Encoded files: the saved series stays while the documented one is not
# newer, with the warning of an explicit override; a newer one wins.
IONCUBE=YES
seed_rerun 7.0.2 "$(saved 8.2)\nIONCUBE=YES\n"
run_case "re-run of an encoded 7.0.2 site on PHP 8.2" 8.2 setup_selects
grep -Fq 'PHP 8.2 must be compatible' "$TEST_DIR/out" ||
    fail "keeping a series for encoded files must warn about the loader: $(cat "$TEST_DIR/out")"
seed_rerun 7.0.3 "$(saved 8.4)\n"
run_case "re-run of an encoded 7.0.3 site on PHP 8.4" 8.4 setup_selects
seed_rerun 7.0.3 "$(saved 8.1)\n"
run_case "an encoded site updated to 7.0.3 leaves PHP 8.1" 8.3 setup_selects
grep -Fq 'The site ran PHP 8.1: KVS 7.0.3 needs PHP 8.3 for its encoded files.' "$TEST_DIR/out" ||
    fail "leaving the saved series must be said: $(cat "$TEST_DIR/out")"
seed_rerun 7.0.3 "$(saved 8.2)\n"
run_case "an encoded site updated to 7.0.3 leaves PHP 8.2" 8.3 setup_selects
seed_rerun 7.0.2 "$(saved 8.4)\n"
KVS_PHP_VERSION=8.1
run_case "KVS_PHP_VERSION on a re-run of an encoded site" 8.1 setup_selects
KVS_PHP_VERSION=''
seed_rerun 6.1.2 ''
sed "s/^DOMAIN=.*/DOMAIN=$DOMAIN/" "$ROOT_DIR/docker/.env.example" > .env
refused "an encoded 6.1.2 site with a .env copied from .env.example" 6.1.2 setup_selects
rm -f .env

# 1f. What saved_php_version reads is what a run writes: set_php_bases, run
# as written with the resolver of the repository, saves for every series
# setup.sh offers a base saved_php_version takes for that series, right
# after the selection.
# shellcheck source=/dev/null disable=SC2016  # The literal text of setup.sh.
source <(extract_function set_php_bases |
    sed 's|"$SETUP_SCRIPT_DIR/bin/resolve-bases.sh"|"$ROOT_DIR/docker/bin/resolve-bases.sh"|')
grep -Fq "\"\$ROOT_DIR/docker/bin/resolve-bases.sh\"" <(declare -f set_php_bases) ||
    fail "set_php_bases must run the resolver of the repository"
DOMAIN=site.example
for series in $SUPPORTED_PHP_VERSIONS; do
    seed_rerun 7.0.2 "PHP_VERSION=$series\n"
    PHP_VERSION=$series
    ( APPEND_TO_ENV=yes set_php_bases ) > "$TEST_DIR/out" 2>&1 || fail "set_php_bases failed for PHP $series: $(cat "$TEST_DIR/out")"
    [ "$(saved_php_version)" = "$series" ] ||
        fail "the base set_php_bases saves for PHP $series is not taken for that series: $(cat .env)"
done
rm -f .env
selection=$(grep -nx 'select_php_version' "$ROOT_DIR/docker/setup.sh" | cut -d: -f1)
[ "$(sed -n "$((selection + 1)),$((selection + 2))p" "$ROOT_DIR/docker/setup.sh")" = $'kvsctl_note_php_change "$PHP_VERSION_BEFORE_SETUP" || exit 1\nset_php_bases' ] ||
    fail "setup.sh must save the base of the series right after the selection"

# 1g. Through kvs-install.sh, which copies .env.example to .env before it
# starts setup.sh when there is none: its PHP_VERSION is not a series a run
# selected. The setup.sh it starts here runs the selection of setup.sh on the
# .env it finds, with the site in place under the domain of the archive name.
# Like setup.sh (KVS_DOMAIN_OVERRIDE), it takes a DOMAIN of the environment
# over the one .env saves: kvs-install.sh passes the domain of the archive
# name that way while .env saves none, and leaves the placeholder of
# .env.example in it. It names the domain it selects for, which must be the
# site's: under another one no site is in place, and a .env copied from
# .env.example would select the documented series whatever saved_php_version
# trusts.
if command -v unzip > /dev/null 2>&1 && command -v python3 > /dev/null 2>&1; then
    {
        echo "source \"$ROOT_DIR/docker/lib/import.sh\""
        grep -m1 '^readonly SUPPORTED_PHP_VERSIONS=' "$ROOT_DIR/docker/setup.sh"
        for name in php_version_is_supported version_at_least saved_php_version kvs_documented_php_version \
            refuse_unbuildable_kvs_php select_php_version; do
            extract_function "$name"
        done | sed "s|/var/www/|$TEST_DIR/www/|g"
        cat <<'SH'
RED='' GREEN='' YELLOW='' CYAN='' NC=''
set_env_value() { printf '%s=%s\n' "$1" "$2" > "$APPLIED"; }
KVS_PHP_VERSION=${KVS_PHP_VERSION:-}
KVS_DOMAIN_OVERRIDE=${DOMAIN:-}
PHP_VERSION=
source .env
[ -z "$KVS_DOMAIN_OVERRIDE" ] || DOMAIN=$KVS_DOMAIN_OVERRIDE
echo "Selecting for DOMAIN=$DOMAIN"
IONCUBE=$SITE_IONCUBE
select_php_version
SH
    } > "$TEST_DIR/installer-setup.sh"
    # installer <IONCUBE> <site version> <.env or ''>: kvs-install.sh on an
    # installation whose site is in place; prints the series selected.
    installer() {
        local work="$TEST_DIR/installer"

        rm -rf "$work" "$TEST_DIR/www" "$TEST_DIR/applied"
        mkdir -p "$work/kvs/.git" "$work/kvs/docker/kvs-archive" "$work/backup" "$TEST_DIR/www/site.example/admin/include"
        : > "$TEST_DIR/www/site.example/admin/include/setup.php"
        printf '%s\n' '<?php' "\$config['project_version'] = \"$2\";" > "$TEST_DIR/www/site.example/admin/include/version.php"
        cp "$ROOT_DIR/docker/.env.example" "$work/kvs/docker/.env.example"
        [ -z "$3" ] || printf '%b' "$3" > "$work/kvs/docker/.env"
        python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.writestr("index.php", "x\n"); z.close()' \
            "$work/kvs/docker/kvs-archive/KVS_${2}_[site.example].zip"
        cp "$TEST_DIR/installer-setup.sh" "$work/kvs/docker/setup.sh"
        # A shell of its own: this one holds the readonly variables of
        # setup.sh that kvs-install.sh sets too.
        # shellcheck disable=SC2016  # The script expands its own arguments.
        env -u DOMAIN -u PHP_VERSION -u KVS_PHP_VERSION KVS_INSTALL_DIR="$work/kvs" KVS_BACKUP_DIR="$work/backup" \
            HEADLESS=y SITE_IONCUBE="$1" APPLIED="$TEST_DIR/applied" bash -c '
                # shellcheck source=/dev/null
                source "$1"
                docker() { return 0; }
                refuse_during_kvsctl_run() { return 0; }
                recover_kvsctl_data() { return 0; }
                refuse_kvsctl_managed_install() { return 0; }
                ensure_docker_prerequisites() { return 0; }
                update_kvs_install() { return 0; }
                dockerInstall
            ' _ "$ROOT_DIR/kvs-install.sh" > "$TEST_DIR/out" 2>&1
    }
    # installer_site <case>: the selection ran for the site in place.
    installer_site() {
        grep -Fxq 'Selecting for DOMAIN=site.example' "$TEST_DIR/out" ||
            fail "kvs-install.sh $1: the selection must run for site.example, the site in place: $(grep -a 'Selecting for' "$TEST_DIR/out" || cat "$TEST_DIR/out")"
    }
    installer NO 7.0.3 '' || fail "kvs-install.sh on an unencoded 7.0.3 site failed: $(cat "$TEST_DIR/out")"
    installer_site "on an unencoded 7.0.3 site"
    grep -Fq 'Created .env from .env.example' "$TEST_DIR/out" || fail "kvs-install.sh must have created .env: $(cat "$TEST_DIR/out")"
    [ "$(applied_version)" = 8.3 ] ||
        fail "kvs-install.sh on an unencoded 7.0.3 site must select PHP 8.3, not the 8.1 of .env.example: $(cat "$TEST_DIR/out")"
    if installer YES 6.1.2 ''; then
        fail "kvs-install.sh on an encoded 6.1.2 site was not refused: $(cat "$TEST_DIR/out")"
    fi
    installer_site "on an encoded 6.1.2 site"
    grep -Fq 'ERROR: KVS 6.1.2 needs PHP 7.4, which this Docker installation does not build.' "$TEST_DIR/out" ||
        fail "kvs-install.sh on an encoded 6.1.2 site must be refused for PHP 7.4: $(cat "$TEST_DIR/out")"
    [ ! -f "$TEST_DIR/applied" ] || fail "a PHP version was written for an encoded 6.1.2 site: $(cat "$TEST_DIR/applied")"
    installer NO 7.0.2 "DOMAIN=site.example\n$(saved 8.4)\n" ||
        fail "kvs-install.sh on a saved series failed: $(cat "$TEST_DIR/out")"
    installer_site "on a saved series"
    [ "$(applied_version)" = 8.4 ] ||
        fail "kvs-install.sh must keep the series an earlier run saved: $(cat "$TEST_DIR/out")"
    rm -rf "$TEST_DIR/installer" "$TEST_DIR/www" "$TEST_DIR/applied"
else
    echo "ok - unzip or python3 is not installed here, the kvs-install.sh case is left to the CI runner"
fi

IMPORT_MODE='' IMPORT_SITE_VERSION='' DOMAIN=''
rm -rf "$TEST_DIR/www"
# shellcheck source=/dev/null
source <(for name in saved_php_version kvs_documented_php_version refuse_unbuildable_kvs_php select_php_version; do
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
