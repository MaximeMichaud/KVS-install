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
    extract_function remove_env_value setup.sh
    extract_function set_env_value setup.sh
    extract_function detect_ioncube setup.sh
    extract_function select_ioncube setup.sh
    extract_function import_site_ioncube lib/import.sh
} > "$TEST_DIR/functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/functions.sh"
declare -F detect_ioncube select_ioncube import_site_ioncube > /dev/null ||
    fail 'setup.sh must define detect_ioncube and select_ioncube, lib/import.sh import_site_ioncube'
RED='' CYAN='' GREEN='' YELLOW='' NC=''

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

    sed '/^IONCUBE=/d' "$TEST_DIR/start.env" > "$expected"
    sed '/^IONCUBE=/d' .env > "$TEST_DIR/other-settings"
    cmp -s "$expected" "$TEST_DIR/other-settings" ||
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

# The immediate loader question must see the newly detected encoding,
# regardless of what IONCUBE contained before this setup invocation.
awk '
    /^# IonCube version selection \(only if IonCube detected\)/ { capture = 1 }
    /^# Reload .env to get user/ { exit }
    capture { print }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/loader-choice.sh"
for source in imported site archive index; do
    for encoding in plain encoded; do
        for initial in YES NO; do
            for choice in 1 2; do
                work
                IMPORT_SITE_IONCUBE=''
                site="$TEST_DIR/no-site"
                rm -rf "$TEST_DIR/site"
                case "$source" in
                    imported)
                        IMPORT_SITE_IONCUBE=no
                        [ "$encoding" != encoded ] || IMPORT_SITE_IONCUBE=yes
                        ;;
                    site)
                        site="$TEST_DIR/site"
                        php_file "$encoding" "$site/admin/include/functions_base.php"
                        ;;
                    archive) zip_site "$encoding" "$TEST_DIR/work/kvs-archive/KVS_7.0.2_[example.com].zip" ;;
                    index) zip_site "$encoding" "$TEST_DIR/work/kvs-archive/KVS_7.0.2_[example.com].zip" admin/index.php ;;
                esac
                sed -i "s/^IONCUBE=YES\$/IONCUBE=$initial/" .env
                DOMAIN=example.com
                IONCUBE=$initial
                IONCUBE_CHOICE=$choice
                detect_ioncube "$site" > "$TEST_DIR/detected-output" 2>&1 ||
                    fail "detection failed for $source/$encoding/$initial"
                detected=NO
                [ "$encoding" != encoded ] || detected=YES
                [ "$IONCUBE" = "$detected" ] ||
                    fail "$source/$encoding retained stale IONCUBE=$IONCUBE from $initial"
                # Exercise the production decision before its later reload.
                # shellcheck source=/dev/null
                source "$TEST_DIR/loader-choice.sh" > "$TEST_DIR/choice-output" 2>&1
                expected=NO
                if [ "$encoding" = encoded ] && [ "$choice" = 1 ]; then
                    expected=YES
                fi
                if [ "$encoding" = encoded ]; then
                    grep -Fq 'IonCube Loader' "$TEST_DIR/choice-output" ||
                        fail "$source did not offer the loader choice for newly detected encoded files"
                elif grep -Fq 'IonCube Loader' "$TEST_DIR/choice-output"; then
                    fail "$source offered the loader choice after detecting plain PHP"
                fi
                # shellcheck disable=SC2016
                saved=$(env -u IONCUBE -u BASH_ENV bash -c 'source .env; printf "%s" "$IONCUBE"')
                [ "$saved" = "$expected" ] ||
                    fail "$source/$encoding/$initial/choice-$choice saved IONCUBE=$saved instead of $expected"
            done
        done
    done
done
IMPORT_SITE_IONCUBE=''
echo 'PASS: the loader choice follows newly detected encoding and persists the selected value'

# Saved syntax must not change the detected or explicitly selected loader
# value, nor any neighboring setting, after a fresh environment load.
seed_loader_setting() {
    local form="$1" initial="$2"

    printf 'KEEP=stable\n' > .env
    case "$form" in
        shared-first|shared-last) ;;
        *) printf 'EXTRA=neighbor\n' >> .env ;;
    esac
    case "$form" in
        plain|multiline) printf 'IONCUBE=%s\n' "$initial" >> .env ;;
        exported) printf 'export IONCUBE=%s\n' "$initial" >> .env ;;
        indented) printf '  IONCUBE=%s\n' "$initial" >> .env ;;
        shared-first) printf 'export IONCUBE="%s" EXTRA="neighbor"\n' "$initial" >> .env ;;
        shared-last) printf 'export EXTRA="neighbor" IONCUBE="%s"\n' "$initial" >> .env ;;
        duplicate) printf 'IONCUBE=YES\nexport IONCUBE=%s\n' "$initial" >> .env ;;
        interpolated)
            # shellcheck disable=SC2016
            printf 'LOADER_SEED=%s\nIONCUBE="${LOADER_SEED}"\n' "$initial" >> .env
            ;;
    esac
    expected_keep=stable
    if [ "$form" = multiline ]; then
        expected_keep=$'first\nIONCUBE=YES\nlast'
        printf 'KEEP="%s"\n' "$expected_keep" >> .env
    fi
    chmod 0600 .env
}

assert_saved_loader() {
    local expected="$1" description="$2"
    local -a saved

    # shellcheck disable=SC2016
    env -u IONCUBE -u KEEP -u EXTRA -u BASH_ENV bash -c \
        'source .env; printf "%s\0%s\0%s\0" "${IONCUBE:-}" "$KEEP" "${EXTRA:-}"' > "$TEST_DIR/saved-loader"
    mapfile -d '' -t saved < "$TEST_DIR/saved-loader"
    [ "${saved[0]}" = "$expected" ] || fail "$description did not persist IONCUBE=$expected"
    [ "${saved[1]}" = "$expected_keep" ] || fail "$description changed an unrelated multiline value"
    [ "${saved[2]}" = neighbor ] || fail "$description lost a shared export"
    [ "$(stat -c %a .env)" = 600 ] || fail "$description changed environment permissions"
}

for source in imported site archive index selection; do
    for value in YES NO; do
        for form in plain exported indented multiline absent shared-first shared-last duplicate interpolated; do
            work
            initial=YES
            [ "$value" != YES ] || initial=NO
            seed_loader_setting "$form" "$initial"
            IONCUBE=$initial
            encoding=plain
            [ "$value" != YES ] || encoding=encoded
            IMPORT_SITE_IONCUBE=''
            site="$TEST_DIR/no-site"
            rm -rf "$TEST_DIR/site"
            case "$source" in
                imported)
                    IMPORT_SITE_IONCUBE=no
                    [ "$value" != YES ] || IMPORT_SITE_IONCUBE=yes
                    ;;
                site)
                    site="$TEST_DIR/site"
                    php_file "$encoding" "$site/admin/include/functions_base.php"
                    ;;
                archive) zip_site "$encoding" "$TEST_DIR/work/kvs-archive/KVS_7.0.2_[example.com].zip" ;;
                index) zip_site "$encoding" "$TEST_DIR/work/kvs-archive/KVS_7.0.2_[example.com].zip" admin/index.php ;;
            esac
            if [ "$source" = selection ]; then
                IONCUBE_CHOICE=2
                [ "$value" != YES ] || IONCUBE_CHOICE=1
                select_ioncube > "$TEST_DIR/syntax-output" 2>&1 || fail "selection failed for $form/$value"
            else
                detect_ioncube "$site" > "$TEST_DIR/syntax-output" 2>&1 || fail "$source detection failed for $form/$value"
            fi
            assert_saved_loader "$value" "$source/$form/$value"
        done
    done
done
IMPORT_SITE_IONCUBE=''
echo 'PASS: detected and selected loader settings survive fresh loads without changing neighboring values'

# A failed save must return its error after removing the files extracted
# solely for detection. The production caller uses errexit as this driver does.
cat > "$TEST_DIR/detection-write-failure.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
RED='' GREEN='' YELLOW='' CYAN='' NC=''
IMPORT_SITE_IONCUBE=''
# shellcheck source=/dev/null
source "$1/functions.sh"
# shellcheck source=/dev/null
source .env
set_env_value() {
    printf '%s\n' "$TEMP_DIR" > "$DETECTION_PATH"
    return 23
}
detect_ioncube "$1/no-site"
echo 'UNEXPECTED_CONTINUATION'
EOF
for source in archive index; do
    for encoding in plain encoded; do
        work
        archive_file=admin/include/functions_base.php
        [ "$source" != index ] || archive_file=admin/index.php
        zip_site "$encoding" "$TEST_DIR/work/kvs-archive/KVS_7.0.2_[example.com].zip" "$archive_file"
        cp .env "$TEST_DIR/before-write-failure.env"
        export DETECTION_PATH="$TEST_DIR/extraction-path"
        : > "$DETECTION_PATH"
        if bash "$TEST_DIR/detection-write-failure.sh" "$TEST_DIR" > "$TEST_DIR/write-failure-output" 2>&1; then
            fail "$source/$encoding continued after a failed loader setting write"
        else
            failure_status=$?
        fi
        extraction_dir=$(cat "$DETECTION_PATH")
        [ -n "$extraction_dir" ] || fail "$source/$encoding did not reach the failing write"
        if [ -e "$extraction_dir" ]; then
            # Clean only the directory reported by this owned test process.
            rm -rf -- "$extraction_dir"
            fail "$source/$encoding left extracted files after the failed write"
        fi
        [ "$failure_status" -eq 23 ] || fail "$source/$encoding lost the persistence error"
        cmp -s .env "$TEST_DIR/before-write-failure.env" || fail "$source/$encoding changed the failed configuration"
        if grep -Fq UNEXPECTED_CONTINUATION "$TEST_DIR/write-failure-output"; then
            fail "$source/$encoding continued past the failed detection"
        fi
    done
done
echo 'PASS: failed detection writes preserve their error and clean extracted files'

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
