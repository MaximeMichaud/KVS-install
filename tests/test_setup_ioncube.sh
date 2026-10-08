#!/bin/bash
# shellcheck disable=SC2034  # Variables are consumed by extracted production functions.
# IONCUBE in docker/.env decides whether the ionCube loader runs. setup.sh
# writes it from the encoding of the site, on the .env made from
# .env.example: only the IONCUBE line may change, whatever the comments
# above it say. And since a container keeps the environment it was created
# with, the comments must name docker compose up -d for a change, not a
# restart.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-setup-ioncube.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

extract_function() {
    awk -v signature="$1() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$ROOT_DIR/docker/$2"
}

{
    extract_function detect_ioncube setup.sh
    extract_function select_ioncube setup.sh
    extract_function import_site_ioncube lib/import.sh
} > "$TEST_DIR/functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/functions.sh"
declare -F detect_ioncube select_ioncube import_site_ioncube > /dev/null ||
    fail 'setup.sh must define detect_ioncube and select_ioncube, lib/import.sh import_site_ioncube'
CYAN='' GREEN='' YELLOW='' NC=''

# php_file <encoded|plain> <file>: a KVS PHP file, ionCube encoded or not.
php_file() {
    mkdir -p "$(dirname "$2")"
    if [ "$1" = encoded ]; then
        printf "<?php //0046b\nif(!extension_loaded('ionCube Loader')){die('loader');}\n" > "$2"
    else
        printf '<?php\nfunction kvs_base() { return 1; }\n' > "$2"
    fi
}

# zip_site <encoded|plain> <zip> [file]: a KVS archive holding that file,
# admin/include/functions_base.php by default.
zip_site() {
    local stage="$TEST_DIR/stage"

    rm -rf "$stage"
    php_file "$1" "$stage/${3:-admin/include/functions_base.php}"
    (cd "$stage" && zip -q -r "$2" admin)
}

# The .env of each case starts as docker/.env.example does, with one more
# comment that names the setting, as the one an unanchored rewrite once
# mangled did: only the IONCUBE line may change, whatever a comment says.
work() {
    rm -rf "$TEST_DIR/work"
    mkdir -p "$TEST_DIR/work/kvs-archive"
    {
        echo '# IONCUBE=YES runs the loader, IONCUBE=NO turns it off.'
        cat "$ROOT_DIR/docker/.env.example"
    } > "$TEST_DIR/start.env"
    cp "$TEST_DIR/start.env" "$TEST_DIR/work/.env"
    cd "$TEST_DIR/work"
}

# only_ioncube_changed <value> <description>: .env differs from what it
# started as by the IONCUBE line alone, which now holds the value.
only_ioncube_changed() {
    local expected="$TEST_DIR/expected"

    sed "s/^IONCUBE=YES\$/IONCUBE=$1/" "$TEST_DIR/start.env" > "$expected"
    cmp -s "$expected" .env ||
        fail "$2 changed more than the IONCUBE line of .env.example: $(diff "$TEST_DIR/start.env" .env || true)"
    if ! { [ "$(grep -c '^IONCUBE=' .env)" -eq 1 ] && grep -Fxq "IONCUBE=$1" .env; }; then
        fail "$2 must leave one IONCUBE=$1 line: $(grep -n 'IONCUBE' .env || true)"
    fi
}

grep -Fxq 'IONCUBE=YES' "$ROOT_DIR/docker/.env.example" || fail '.env.example must hold IONCUBE=YES'

# Every path of detect_ioncube that writes the value: the imported site,
# the site in place, the archive and its admin/index.php fallback. Then the
# question.
for source in imported site archive index; do
    for value in NO YES; do
        work
        encoding=plain
        [ "$value" = YES ] && encoding=encoded
        IMPORT_SITE_IONCUBE=''
        site="$TEST_DIR/no-site"
        rm -rf "$TEST_DIR/site"
        case "$source" in
            imported)
                IMPORT_SITE_IONCUBE=no
                [ "$value" = YES ] && IMPORT_SITE_IONCUBE=yes
                ;;
            site)
                site="$TEST_DIR/site"
                php_file "$encoding" "$site/admin/include/functions_base.php"
                ;;
            archive) zip_site "$encoding" "$TEST_DIR/work/kvs-archive/KVS_7.0.2_[example.com].zip" ;;
            index) zip_site "$encoding" "$TEST_DIR/work/kvs-archive/KVS_7.0.2_[example.com].zip" admin/index.php ;;
        esac
        # From the opposite value, so that the line really changes.
        sed -i "s/^IONCUBE=YES\$/IONCUBE=$([ "$value" = YES ] && echo NO || echo YES)/" .env
        # A subshell: detect_ioncube sources .env when it read an archive.
        ( DOMAIN=example.com detect_ioncube "$site" ) > "$TEST_DIR/out" 2>&1 ||
            fail "detect_ioncube failed: $(cat "$TEST_DIR/out")"
        grep -q 'detected' "$TEST_DIR/out" || fail "detect_ioncube ($source, $value) did not decide: $(cat "$TEST_DIR/out")"
        only_ioncube_changed "$value" "detect_ioncube ($source, $value)"
    done
done
IMPORT_SITE_IONCUBE=''

for choice in 2 1; do
    work
    value=YES
    [ "$choice" = 2 ] && value=NO
    IONCUBE_CHOICE=$choice select_ioncube > "$TEST_DIR/out" 2>&1 || fail "select_ioncube failed: $(cat "$TEST_DIR/out")"
    only_ioncube_changed "$value" "select_ioncube (choice $choice)"
done

# No IONCUBE rewrite of setup.sh may match anything but the IONCUBE line,
# whatever its quotes, branch or delimiter.
unanchored=$(grep -E '(^|[^[:alnum:]_])sed ' "$ROOT_DIR/docker/setup.sh" |
    grep -oE 's[/|#][^/|#]*IONCUBE=' | grep -vE '^s[/|#]\^IONCUBE=$' || true)
[ -z "$unanchored" ] ||
    fail "every rewrite of IONCUBE in setup.sh must be anchored to the start of the line: $unanchored"
echo 'PASS: setup.sh rewrites the IONCUBE line of .env and nothing else'

# comment_above <file> <line>: the comment lines right above that exact line.
comment_above() {
    awk -v want="$2" '
        /^[[:space:]]*#/ { block = block $0 "\n"; next }
        $0 == want { printf "%s", block; found = 1; exit }
        { block = "" }
        END { exit !found }
    ' "$1"
}

for spec in "docker/.env.example|IONCUBE=YES" "docker/docker-compose.yml|      - IONCUBE=\${IONCUBE:-YES}"; do
    file=${spec%%|*}
    line=${spec#*|}
    comment=$(comment_above "$ROOT_DIR/$file" "$line") || fail "$file has no line '$line'"
    grep -Fq 'docker compose up -d' <<< "$comment" ||
        fail "the comment on IONCUBE in $file must name docker compose up -d: $comment"
    grep -Fq 'docker compose restart does not recreate' <<< "$comment" ||
        fail "the comment on IONCUBE in $file must say that a restart keeps the old value: $comment"
done
# Any comment on an IONCUBE line, in .env.example, the compose file or the
# site template, that speaks of a restart says that one does not apply a
# change.
for file in docker/.env.example docker/docker-compose.yml docker/multi-site/docker-compose.site.yml.template; do
    comments=$(awk '
        /^[[:space:]]*#/ { block = block $0 "\n"; next }
        /^[[:space:]]*(- )?IONCUBE=/ { printf "%s", block }
        { block = "" }
    ' "$ROOT_DIR/$file")
    if grep -Eiq 'is a restart|takes a restart|needs a restart|restart (applies|picks|is enough)' <<< "$comments"; then
        fail "a comment on IONCUBE in $file calls a change a restart: $comments"
    fi
    if grep -iq 'restart' <<< "$comments" &&
        ! { grep -Fq 'docker compose up -d' <<< "$comments" && grep -Fq 'docker compose restart does not recreate' <<< "$comments"; }; then
        fail "a comment on IONCUBE in $file that speaks of a restart must say that docker compose up -d applies a change and a restart does not: $comments"
    fi
done
echo 'PASS: the IONCUBE comments name docker compose up -d'
