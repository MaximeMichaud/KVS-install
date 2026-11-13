#!/bin/bash
# Import sources: archives (zip, 7z, tar) analysed, extracted and settled
# into the site directory, the tools installed on demand, and the SSH
# plumbing of the remote source run through a fake ssh that executes the
# remote command locally.
# shellcheck disable=SC2016  # Fixture content holds literal dollar signs.
# shellcheck disable=SC2030,SC2031  # PATH is changed inside subshells on purpose.
set -euo pipefail

# Existing cases exercise the single-stream compatibility path explicitly.
export IMPORT_TRANSFER_JOBS=1

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d -t kvs-import-sources-test.XXXXXX)
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

# shellcheck source=/dev/null
source "$REPO_ROOT/docker/lib/import.sh"

SEVEN_ZIP=""
for candidate in 7zz 7z 7za; do
    if command -v "$candidate" >/dev/null 2>&1; then
        SEVEN_ZIP=$candidate
        break
    fi
done

make_site() {
    local dir="$1"
    local project_path="$2"

    mkdir -p "$dir/admin/include" "$dir/contents/videos" "$dir/_INSTALL"
    cat > "$dir/admin/include/setup.php" <<EOF
<?php
\$config['project_path']="$project_path";
\$config['project_url']="https://www.old.example.com";
\$config['tables_prefix']="ktvs_";
EOF
    echo "<?php define('DB_HOST','localhost');" > "$dir/admin/include/setup_db.php"
    printf '<?php\n$config['"'"'project_version'"'"'] = "7.0.2";\n' > "$dir/admin/include/version.php"
    echo "video" > "$dir/contents/videos/1.mp4"
    echo "CREATE TABLE \`ktvs_stock\` (id int);" > "$dir/_INSTALL/install_db.sql"
}

make_dump() {
    local file="$1"
    {
        echo "CREATE TABLE \`ktvs_options\` (\`variable\` varchar(255) NOT NULL, \`value\` text NOT NULL, PRIMARY KEY (\`variable\`));"
        echo "INSERT INTO \`ktvs_options\` VALUES ('INITIAL_VERSION','7.0.2');"
        echo "-- Dump completed on 2026-09-23 10:00:00"
    } > "$file"
}

# make_layout <name> <site prefix inside the archive> <dump member>
# A directory tree ready to be archived from inside.
make_layout() {
    local name="$1"
    local prefix="$2"
    local dump="$3"
    local layout="$TMP_ROOT/layout-$name"

    rm -rf "$layout"
    mkdir -p "$layout/$prefix" "$layout/$(dirname "$dump")"
    make_site "$layout/${prefix%/}" /home/old/www
    case "$dump" in
        *.gz) make_dump "$layout/plain.sql"; gzip -c "$layout/plain.sql" > "$layout/$dump"; rm -f "$layout/plain.sql" ;;
        *.zst) make_dump "$layout/plain.sql"; zstd -q -f "$layout/plain.sql" -o "$layout/$dump"; rm -f "$layout/plain.sql" ;;
        *) make_dump "$layout/$dump" ;;
    esac
    printf '%s\n' "$layout"
}

# archive_of <layout dir> <output file>: pack the layout with the tool the name asks for.
archive_of() {
    local layout="$1"
    local output="$2"

    rm -f "$output"
    case "$output" in
        *.zip) (cd "$layout" && zip -q -r -y "$output" .) ;;
        *.7z) (cd "$layout" && "$SEVEN_ZIP" a -bd -bso0 "$output" . >/dev/null) ;;
        *.tar) tar -cf "$output" -C "$layout" . ;;
        *.tar.gz) tar -czf "$output" -C "$layout" . ;;
        *.tar.zst) tar --zstd -cf "$output" -C "$layout" . ;;
        *) fail "unknown archive type for $output" ;;
    esac
}

test_archive_names_map_to_kinds_tools_and_packages() {
    [ "$(import_archive_kind site.zip)" = zip ] || fail "zip kind"
    [ "$(import_archive_kind SITE.7Z)" = 7z ] || fail "7z kind, case insensitive"
    [ "$(import_archive_kind site.tar)" = tar ] || fail "tar kind"
    [ "$(import_archive_kind site.tar.gz)" = tar ] || fail "tar.gz kind"
    [ "$(import_archive_kind site.tgz)" = tar ] || fail "tgz kind"
    [ "$(import_archive_kind site.tar.zst)" = tar ] || fail "tar.zst kind"
    [ "$(import_archive_kind site.tar.xz)" = tar ] || fail "tar.xz kind"
    [ "$(import_archive_kind site.tar.bz2)" = tar ] || fail "tar.bz2 kind"
    import_archive_kind site.rar 2>/dev/null && fail "rar must be refused"
    import_archive_kind site.sql.gz 2>/dev/null && fail "a dump is not an archive"

    [ "$(import_compressor_for site.tar.gz)" = gzip ] || fail "gzip compressor"
    [ "$(import_compressor_for site.tar.zst)" = zstd ] || fail "zstd compressor"
    [ "$(import_compressor_for dump.sql.xz)" = xz ] || fail "xz compressor"
    [ "$(import_compressor_for site.tar.bz2)" = bzip2 ] || fail "bzip2 compressor"
    [ -z "$(import_compressor_for site.tar)" ] || fail "plain tar needs no compressor"

    [ "$(import_tool_package unzip)" = unzip ] || fail "unzip package"
    [ "$(import_tool_package 7zz)" = 7zip ] || fail "7zip package"
    [ "$(import_tool_package xz)" = xz-utils ] || fail "xz package"
    [ "$(import_tool_package rsync)" = rsync ] || fail "rsync package"
    import_tool_package pv 2>/dev/null && fail "pv is not something the import installs"
    pass "archive names map to kinds, tools and packages"
}

# A bin directory with the commands the functions need plus a stub apt-get
# that "installs" a package by creating the command it provides.
make_apt_sandbox() {
    local bin="$1"
    local fail_package="${2:-}"
    local tool

    mkdir -p "$bin"
    for tool in bash sh awk sed grep tail head cat printf tr find mkdir rm mv cp chmod ln dirname basename readlink du df sort uniq wc; do
        if command -v "$tool" >/dev/null 2>&1 && [ ! -e "$bin/$tool" ]; then
            ln -s "$(command -v "$tool")" "$bin/$tool"
        fi
    done
    cat > "$bin/apt-get" <<EOF
#!/bin/bash
echo "\$*" >> "$bin/apt.log"
package=""
for arg in "\$@"; do package=\$arg; done
[ "\$1" = update ] && exit 0
if [ "\$package" = "$fail_package" ]; then echo "E: Unable to locate package \$package" >&2; exit 100; fi
case "\$package" in
    7zip) printf '#!/bin/bash\nexit 0\n' > "$bin/7zz"; chmod +x "$bin/7zz" ;;
    p7zip-full) printf '#!/bin/bash\nexit 0\n' > "$bin/7z"; chmod +x "$bin/7z" ;;
    xz-utils) printf '#!/bin/bash\nexit 0\n' > "$bin/xz"; chmod +x "$bin/xz" ;;
    *) printf '#!/bin/bash\nexit 0\n' > "$bin/\$package"; chmod +x "$bin/\$package" ;;
esac
EOF
    chmod +x "$bin/apt-get"
}

test_only_the_missing_tool_is_installed() {
    local bin="$TMP_ROOT/apt-bin"
    make_apt_sandbox "$bin"

    (
        PATH="$bin"
        [ "$(import_archive_tools /x/site.tar.zst 2>/dev/null)" = tar ] || exit 1
        grep -q -- '--no-install-recommends zstd$' "$bin/apt.log" || exit 2
        [ "$(grep -c install "$bin/apt.log")" = 1 ] || exit 3
        [ "$(import_archive_tools /x/site.zip 2>/dev/null)" = unzip ] || exit 4
        grep -q -- '--no-install-recommends unzip$' "$bin/apt.log" || exit 5
        [ "$(import_archive_tools /x/site.tar 2>/dev/null)" = tar ] || exit 6
        [ "$(grep -c install "$bin/apt.log")" = 2 ] || exit 7
        [ "$(import_archive_tools /x/site.tar.zst 2>/dev/null)" = tar ] || exit 8
        [ "$(grep -c install "$bin/apt.log")" = 2 ] || exit 9
        import_archive_tools /x/site.rar 2>/dev/null && exit 10
        exit 0
    ) || fail "tools must be installed one at a time and only when missing (case $?)"

    rm -rf "$bin"
    make_apt_sandbox "$bin"
    (
        PATH="$bin"
        [ "$(import_archive_tools /x/site.7z 2>/dev/null)" = 7zz ] || exit 1
        grep -q -- ' 7zip$' "$bin/apt.log" || exit 2
        grep -q p7zip "$bin/apt.log" && exit 3
        exit 0
    ) || fail "a 7z archive installs 7zip and nothing else (case $?)"

    rm -rf "$bin"
    make_apt_sandbox "$bin" 7zip
    (
        PATH="$bin"
        [ "$(import_archive_tools /x/site.7z 2>/dev/null)" = 7z ] || exit 1
        grep -q -- ' p7zip-full$' "$bin/apt.log" || exit 2
        exit 0
    ) || fail "p7zip-full is the fallback when 7zip is not packaged (case $?)"

    rm -rf "$bin"
    make_apt_sandbox "$bin" unzip
    (
        PATH="$bin"
        import_archive_tools /x/site.zip 2>/dev/null && exit 1
        grep -q -- '^update' "$bin/apt.log" || exit 2
        exit 0
    ) || fail "a failed install refreshes the index once and then gives up (case $?)"
    pass "only the missing tool is installed, with the 7zip fallback"
}

test_listings_are_normalized_for_every_archive_kind() {
    local layout archive listing

    layout=$(make_layout list www/ database.sql.gz)
    echo "spaced" > "$layout/www/contents/a b  c.txt"
    ln -s contents/videos/1.mp4 "$layout/www/link.mp4"
    echo "hard" > "$layout/www/contents/hardsrc.txt"
    ln "$layout/www/contents/hardsrc.txt" "$layout/www/contents/hard.txt"
    for archive in "$TMP_ROOT/list.zip" "$TMP_ROOT/list.tar" "$TMP_ROOT/list.tar.gz" "$TMP_ROOT/list.tar.zst" "$TMP_ROOT/list.7z"; do
        case "$archive" in
            *.7z) [ -n "$SEVEN_ZIP" ] || continue ;;
        esac
        archive_of "$layout" "$archive"
        listing=$(import_archive_list "$archive" "$(import_archive_tools "$archive")")
        grep -q $'^f\t[0-9]*\twww/admin/include/setup.php$' <<< "$listing" || fail "$archive: setup.php must be listed as a file"
        grep -q $'^d\t0\twww/admin$' <<< "$listing" || fail "$archive: directories must be listed with type d and no size, got: $(grep 'www/admin$' <<< "$listing")"
        grep -q $'^f\t[1-9][0-9]*\tdatabase.sql.gz$' <<< "$listing" || fail "$archive: the dump must be listed with its size"
        grep -q $'^f\t6\twww/contents/videos/1.mp4$' <<< "$listing" || fail "$archive: sizes must be the uncompressed bytes"
        grep -q '^\./\|/$' <<< "$listing" && fail "$archive: names must lose the leading ./ and trailing /"
        grep -q $'\twww/contents/a b  c.txt$' <<< "$listing" || fail "$archive: a name with spaces must survive: $(grep 'a b' <<< "$listing")"
        grep -q $'\twww/contents/hard.txt$' <<< "$listing" || fail "$archive: a hard link is listed by its own name: $(grep hard <<< "$listing")"
        case "$archive" in
            *.tar*) grep -q $'^l\t0\twww/link.mp4$' <<< "$listing" || fail "$archive: a symlink is listed as such without its target: $(grep link <<< "$listing")" ;;
        esac
    done
    pass "listings are normalized for every archive kind"
}

test_analysis_finds_the_site_root_and_the_dump() {
    local layout archive listing result

    layout=$(make_layout top "" database.sql.gz)
    archive_of "$layout" "$TMP_ROOT/top.tar"
    import_archive_list "$TMP_ROOT/top.tar" tar > "$TMP_ROOT/top.list"
    result=$(import_archive_analyze "$TMP_ROOT/top.list") || fail "a site at the top level must be accepted"
    [ "$(import_field "$result" 1)" = "" ] || fail "top level site has an empty root, got '$(import_field "$result" 1)'"
    [ "$(import_field "$result" 2)" = database.sql.gz ] || fail "the dump next to the site must be found"
    [ "$(import_field "$result" 4)" = 1 ] || fail "the size is rounded up to megabytes, got '$(import_field "$result" 4)'"

    layout=$(make_layout nested www/ database.sql.zst)
    echo "format=1" > "$layout/kvs-export.manifest"
    archive_of "$layout" "$TMP_ROOT/nested.zip"
    import_archive_list "$TMP_ROOT/nested.zip" unzip > "$TMP_ROOT/nested.list"
    result=$(import_archive_analyze "$TMP_ROOT/nested.list") || fail "the exporter layout must be accepted"
    [ "$(import_field "$result" 1)" = "www/" ] || fail "nested root must be www/, got '$(import_field "$result" 1)'"
    [ "$(import_field "$result" 2)" = database.sql.zst ] || fail "zstd dump must be found"
    [ "$(import_field "$result" 3)" = kvs-export.manifest ] || fail "the manifest must be found"

    layout=$(make_layout native www/ database.mariadb.tar.gz)
    archive_of "$layout" "$TMP_ROOT/native.tar"
    import_archive_list "$TMP_ROOT/native.tar" tar > "$TMP_ROOT/native.list"
    result=$(import_archive_analyze "$TMP_ROOT/native.list") || fail "a native database bundle next to the site must be accepted"
    [ "$(import_field "$result" 2)" = database.mariadb.tar.gz ] || fail "the native bundle must be selected as the database"

    layout=$(make_layout deep example.com/public_html/ dump/site.sql)
    archive_of "$layout" "$TMP_ROOT/deep.tar.gz"
    import_archive_list "$TMP_ROOT/deep.tar.gz" tar > "$TMP_ROOT/deep.list"
    result=$(import_archive_analyze "$TMP_ROOT/deep.list") || fail "a site two levels down with the dump in a folder must be accepted"
    [ "$(import_field "$result" 1)" = "example.com/public_html/" ] || fail "deep root, got '$(import_field "$result" 1)'"
    [ "$(import_field "$result" 2)" = dump/site.sql ] || fail "dump in a folder, got '$(import_field "$result" 2)'"

    layout=$(make_layout junk www/ database.sql.gz)
    mkdir -p "$layout/__MACOSX/www"
    echo junk > "$layout/__MACOSX/www/._setup.php"
    echo junk > "$layout/.DS_Store"
    echo junk > "$layout/www/.DS_Store"
    archive_of "$layout" "$TMP_ROOT/junk.zip"
    import_archive_list "$TMP_ROOT/junk.zip" unzip > "$TMP_ROOT/junk.list"
    result=$(import_archive_analyze "$TMP_ROOT/junk.list") || fail "macOS listing junk must be ignored"
    [ "$(import_field "$result" 1)" = "www/" ] || fail "junk must not change the root"
    [ -z "$(import_field "$result" 5)" ] || fail "listing junk is not reported as ignored: got '$(import_field "$result" 5)'"
    pass "analysis finds the site root and the dump in every layout"
}

test_analysis_refuses_what_would_pollute_the_webroot() {
    local layout result

    layout=$(make_layout extra www/ database.sql.gz)
    echo "notes" > "$layout/notes.txt"
    mkdir -p "$layout/vhost"
    echo "server {}" > "$layout/vhost/example.conf"
    archive_of "$layout" "$TMP_ROOT/extra.tar"
    import_archive_list "$TMP_ROOT/extra.tar" tar > "$TMP_ROOT/extra.list"
    result=$(import_archive_analyze "$TMP_ROOT/extra.list") || fail "files next to the site are ignored, not refused"
    [ "$(import_field "$result" 1)" = "www/" ] || fail "extras must not change the root"
    grep -q 'notes.txt' <<< "$(import_field "$result" 5)" || fail "the ignored entries must be listed: got '$(import_field "$result" 5)'"
    grep -q 'vhost' <<< "$(import_field "$result" 5)" || fail "an ignored directory is listed once by its name"

    layout=$(make_layout twodumps www/ database.sql.gz)
    make_dump "$layout/other.sql"
    archive_of "$layout" "$TMP_ROOT/twodumps.tar"
    import_archive_list "$TMP_ROOT/twodumps.tar" tar > "$TMP_ROOT/twodumps.list"
    import_archive_analyze "$TMP_ROOT/twodumps.list" 2> "$TMP_ROOT/twodumps.err" && fail "two dumps must be refused"
    grep -q '2 database dumps' "$TMP_ROOT/twodumps.err" || fail "the refusal must count the dumps"

    layout=$(make_layout nodump www/ database.sql.gz)
    rm "$layout/database.sql.gz"
    archive_of "$layout" "$TMP_ROOT/nodump.tar"
    import_archive_list "$TMP_ROOT/nodump.tar" tar > "$TMP_ROOT/nodump.list"
    import_archive_analyze "$TMP_ROOT/nodump.list" 2>/dev/null && fail "an archive without a dump must be refused"

    layout=$(make_layout nosite www/ database.sql.gz)
    rm "$layout/www/admin/include/setup.php"
    archive_of "$layout" "$TMP_ROOT/nosite.tar"
    import_archive_list "$TMP_ROOT/nosite.tar" tar > "$TMP_ROOT/nosite.list"
    import_archive_analyze "$TMP_ROOT/nosite.list" 2>/dev/null && fail "an archive without a site must be refused"

    layout=$(make_layout twosites www/ database.sql.gz)
    make_site "$layout/other" /home/other
    archive_of "$layout" "$TMP_ROOT/twosites.tar"
    import_archive_list "$TMP_ROOT/twosites.tar" tar > "$TMP_ROOT/twosites.list"
    import_archive_analyze "$TMP_ROOT/twosites.list" 2>/dev/null && fail "two sites must be refused"

    printf 'f\t10\t../evil\nf\t10\twww/admin/include/setup.php\nf\t10\tdatabase.sql\n' > "$TMP_ROOT/traversal.list"
    import_archive_analyze "$TMP_ROOT/traversal.list" 2> "$TMP_ROOT/traversal.err" && fail "a member with .. must be refused"
    grep -q '\.\.' "$TMP_ROOT/traversal.err" || fail "the refusal must mention the traversal"
    printf 'f\t10\t/etc/passwd\nf\t10\twww/admin/include/setup.php\nf\t10\tdatabase.sql\n' > "$TMP_ROOT/absolute.list"
    import_archive_analyze "$TMP_ROOT/absolute.list" 2>/dev/null && fail "an absolute member must be refused"
    printf 'f\t10\twww/admin/include/setup.php\nf\t10\tdatabase.sql\nf\t10\twww/x/../y\n' > "$TMP_ROOT/inner.list"
    import_archive_analyze "$TMP_ROOT/inner.list" 2>/dev/null && fail "a .. inside a path must be refused"
    pass "analysis refuses what would pollute the webroot or escape it"
}

test_peek_reads_the_config_before_extraction() {
    local layout archive peek

    layout=$(make_layout peek www/ database.sql.gz)
    for archive in "$TMP_ROOT/peek.zip" "$TMP_ROOT/peek.tar.zst" "$TMP_ROOT/peek.7z"; do
        case "$archive" in
            *.7z) [ -n "$SEVEN_ZIP" ] || continue ;;
        esac
        archive_of "$layout" "$archive"
        peek="$TMP_ROOT/peek-out-$(basename "$archive")"
        import_archive_peek "$archive" "$(import_archive_tools "$archive")" "www/" "$peek" || fail "$archive: peek must succeed"
        [ "$(import_read_kvs_version "$peek")" = 7.0.2 ] || fail "$archive: the peeked version.php must be readable"
        [ "$(import_read_php_config_value "$peek/admin/include/setup.php" project_path)" = /home/old/www ] || fail "$archive: the peeked setup.php must be readable"
        [ ! -e "$peek/contents" ] || fail "$archive: the peek must not extract the site"
    done
    import_archive_peek "$TMP_ROOT/peek.zip" unzip "elsewhere/" "$TMP_ROOT/peek-wrong" 2>/dev/null && fail "a wrong root must fail the peek"
    pass "peek reads the config before extraction"
}

test_extraction_settles_the_site_and_takes_the_dump_out() {
    local layout archive stage destination staging result

    layout=$(make_layout settle www/ database.sql.zst)
    echo "format=1" > "$layout/kvs-export.manifest"
    echo "notes" > "$layout/notes.txt"
    for archive in "$TMP_ROOT/settle.zip" "$TMP_ROOT/settle.tar" "$TMP_ROOT/settle.7z"; do
        case "$archive" in
            *.7z) [ -n "$SEVEN_ZIP" ] || continue ;;
        esac
        archive_of "$layout" "$archive"
        destination="$TMP_ROOT/settle-dest-$(basename "$archive")"
        stage=$(import_stage_dir_for "$destination")
        [ "$stage" = "$TMP_ROOT/.kvs-import-settle-dest-$(basename "$archive")" ] || fail "the stage sits next to the destination: $stage"
        staging="$TMP_ROOT/settle-staging-$(basename "$archive")"
        mkdir -p "$stage"
        import_archive_extract "$archive" "$(import_archive_tools "$archive")" "$stage" || fail "$archive: extraction must succeed"
        [ -f "$stage/www/admin/include/setup.php" ] || fail "$archive: the archive is extracted as stored into the stage"
        [ ! -e "$destination" ] || fail "$archive: nothing reaches the destination before the settle"
        result=$(import_archive_settle "$stage" "www/" database.sql.zst kvs-export.manifest "$staging" "$destination") || fail "$archive: settle must succeed"
        [ -f "$destination/admin/include/setup.php" ] || fail "$archive: the site must move into the destination"
        [ -f "$destination/contents/videos/1.mp4" ] || fail "$archive: the site content must move"
        [ ! -e "$destination/www" ] || fail "$archive: the nested directory must not appear"
        [ ! -e "$destination/notes.txt" ] || fail "$archive: entries outside the site must not reach the destination"
        [ ! -e "$destination/database.sql.zst" ] || fail "$archive: the dump must never sit in the webroot"
        [ ! -e "$destination/kvs-export.manifest" ] || fail "$archive: the manifest must not reach the destination"
        [ ! -e "$stage" ] || fail "$archive: the stage must go"
        [ "$(import_field "$result" 1)" = "$staging/database.sql.zst" ] || fail "$archive: the dump path must be printed"
        [ "$(import_field "$result" 2)" = "$staging/kvs-export.manifest" ] || fail "$archive: the manifest path must be printed"
        [ "$(import_inspect_dump "$staging/database.sql.zst" ktvs_)" = $'1\t7.0.2\t0\tyes\t' ] || fail "$archive: the staged dump must be intact"
    done

    layout=$(make_layout deep example.com/public_html/ dump/site.sql)
    archive_of "$layout" "$TMP_ROOT/deep-settle.tar"
    destination="$TMP_ROOT/deep-dest"
    stage="$TMP_ROOT/deep-stage"
    import_archive_extract "$TMP_ROOT/deep-settle.tar" tar "$stage"
    import_archive_settle "$stage" "example.com/public_html/" dump/site.sql "" "$TMP_ROOT/deep-staging" "$destination" >/dev/null || fail "deep settle must succeed"
    [ -f "$destination/admin/include/setup.php" ] || fail "a site two levels down must move into the destination"
    [ ! -e "$destination/example.com" ] || fail "the outer directory must not appear"
    [ -f "$TMP_ROOT/deep-staging/site.sql" ] || fail "the dump keeps its name in the staging directory"

    layout=$(make_layout top "" database.sql.gz)
    archive_of "$layout" "$TMP_ROOT/top-settle.tar"
    destination="$TMP_ROOT/top-dest"
    stage="$TMP_ROOT/top-stage"
    import_archive_extract "$TMP_ROOT/top-settle.tar" tar "$stage"
    import_archive_settle "$stage" "" database.sql.gz "" "$TMP_ROOT/top-staging" "$destination" >/dev/null || fail "top level settle must succeed"
    [ -f "$destination/admin/include/setup.php" ] || fail "a top level site moves as a whole"
    [ ! -e "$destination/database.sql.gz" ] || fail "the top level dump must not reach the destination"

    # A second pass over a destination filled by an earlier attempt
    # replaces the entries instead of nesting them.
    echo "changed" > "$destination/contents/videos/1.mp4"
    echo "old" > "$destination/leftover.txt"
    import_archive_extract "$TMP_ROOT/top-settle.tar" tar "$stage"
    import_archive_settle "$stage" "" database.sql.gz "" "$TMP_ROOT/top-staging" "$destination" >/dev/null || fail "a repeated settle must succeed"
    [ "$(cat "$destination/contents/videos/1.mp4")" = video ] || fail "a repeated settle replaces the entries"
    [ ! -e "$destination/contents/contents" ] || fail "a repeated settle must not nest directories"
    [ -f "$destination/leftover.txt" ] || fail "a repeated settle leaves what the archive does not hold"

    layout=$(make_layout junk www/ database.sql.gz)
    mkdir -p "$layout/__MACOSX/www"
    echo junk > "$layout/__MACOSX/www/._setup.php"
    echo junk > "$layout/www/.DS_Store"
    archive_of "$layout" "$TMP_ROOT/junk-settle.zip"
    destination="$TMP_ROOT/junk-dest"
    stage="$TMP_ROOT/junk-stage"
    import_archive_extract "$TMP_ROOT/junk-settle.zip" unzip "$stage"
    import_archive_settle "$stage" "www/" database.sql.gz "" "$TMP_ROOT/junk-staging" "$destination" >/dev/null
    [ ! -e "$destination/__MACOSX" ] || fail "__MACOSX must not reach the destination"
    [ ! -e "$destination/.DS_Store" ] || fail ".DS_Store files must go"
    pass "extraction settles the site from a private stage and keeps the dump out of the webroot"
}

test_settle_rejects_linked_import_materials() {
    local layout archive stage destination kind result root dump manifest

    for kind in dump manifest; do
        layout=$(make_layout "linked-$kind" www/ database.sql)
        if [ "$kind" = dump ]; then
            mv "$layout/database.sql" "$TMP_ROOT/outside-$kind"
            ln -s "$TMP_ROOT/outside-$kind" "$layout/database.sql"
        else
            printf 'format=1\n' > "$TMP_ROOT/outside-$kind"
            ln -s "$TMP_ROOT/outside-$kind" "$layout/kvs-export.manifest"
        fi
        chmod 644 "$TMP_ROOT/outside-$kind"
        archive="$TMP_ROOT/linked-$kind.zip"
        archive_of "$layout" "$archive"
        import_archive_list "$archive" unzip > "$TMP_ROOT/linked-$kind.list"
        result=$(import_archive_analyze "$TMP_ROOT/linked-$kind.list") || fail 'the ZIP listing does not distinguish links from regular files'
        root=$(import_field "$result" 1)
        dump=$(import_field "$result" 2)
        manifest=$(import_field "$result" 3)
        stage="$TMP_ROOT/linked-$kind-stage"
        destination="$TMP_ROOT/linked-$kind-dest"
        import_archive_extract "$archive" unzip "$stage" || fail 'the ZIP must extract before checking its member types'
        if import_archive_settle "$stage" "$root" "$dump" "$manifest" "$TMP_ROOT/linked-$kind-db" "$destination" > "$TMP_ROOT/linked-$kind.out" 2> "$TMP_ROOT/linked-$kind.err"; then
            fail "a linked $kind must not be staged as an import material"
        fi
        grep -q 'not a regular file' "$TMP_ROOT/linked-$kind.err" || fail 'the refusal must explain the invalid member type'
        [ -e "$stage/$dump" ] || fail 'material validation must happen before moving the dump'
        [ ! -e "$destination" ] || fail 'invalid materials must be refused before moving site files'
        [ "$(stat -c %a "$TMP_ROOT/outside-$kind")" = 644 ] || fail 'the external file permissions must remain unchanged'
    done
    pass 'settling refuses linked dumps and manifests before moving any import materials'
}

test_settle_preserves_complete_entry_names() {
    local layout archive stage destination name
    local -a files=($'thumbnail\npreview.css' $'trailing.css\n' $'-asset\tname.css')
    local directory=$'directory\nclips'

    layout=$(make_layout entry-names www/ database.sql)
    for name in "${files[@]}"; do
        printf 'synthetic asset: %s\n' "$name" > "$layout/www/$name"
    done
    mkdir "$layout/www/$directory"
    printf 'nested content\n' > "$layout/www/$directory/asset.css"
    archive="$TMP_ROOT/entry-names.tar"
    archive_of "$layout" "$archive"
    import_archive_list "$archive" tar > "$TMP_ROOT/entry-names.list"
    import_archive_analyze "$TMP_ROOT/entry-names.list" >/dev/null || fail "an archive with unusual asset names must pass analysis"

    stage="$TMP_ROOT/entry-names-stage"
    destination="$TMP_ROOT/entry-names-dest"
    mkdir "$destination"
    for name in thumbnail trailing.css directory; do
        printf 'keep %s\n' "$name" > "$destination/$name"
    done
    import_archive_extract "$archive" tar "$stage" || fail "the archive must extract with its original names"
    import_archive_settle "$stage" www/ database.sql "" "$TMP_ROOT/entry-names-db" "$destination" >/dev/null || fail "settling must preserve line breaks and tabs in entry names"
    for name in "${files[@]}"; do
        cmp "$layout/www/$name" "$destination/$name" || fail "every file must keep its complete name and content"
    done
    cmp "$layout/www/$directory/asset.css" "$destination/$directory/asset.css" || fail "directory names must stay intact"
    for name in thumbnail trailing.css directory; do
        [ "$(cat "$destination/$name")" = "keep $name" ] || fail "an unrelated entry matching only part of a name must remain intact"
    done
    [ ! -e "$stage" ] || fail "the completed stage must be removed"
    [ -f "$TMP_ROOT/entry-names-db/database.sql" ] || fail "the dump must stay outside the site"
    pass "settling preserves complete entry names and unrelated destination files"
}

test_stage_directory_follows_the_destination_filesystem() {
    local destination="$TMP_ROOT/stage-dest" stage other

    [ "$(import_stage_dir_for "$destination")" = "$TMP_ROOT/.kvs-import-stage-dest" ] || fail "an absent destination stages next to itself"
    mkdir -p "$destination"
    [ "$(import_stage_dir_for "$destination")" = "$TMP_ROOT/.kvs-import-stage-dest" ] || fail "a destination on the same filesystem stages next to itself"
    ln -s "$destination" "$TMP_ROOT/stage-link"
    [ "$(import_stage_dir_for "$TMP_ROOT/stage-link")" = "$TMP_ROOT/.kvs-import-stage-dest" ] || fail "a symlinked destination stages next to its target"
    (
        # shellcheck disable=SC2329  # Stub consumed by the function under test.
        stat() { if [ "$4" = "$destination" ]; then echo 99; else echo 1; fi; }
        stage=$(import_stage_dir_for "$destination") || exit 1
        [[ "$stage" == "$destination/.kvs-import-stage."* ]] || exit 1
        [ -d "$stage" ] && [ "$(command stat -c %a "$stage")" = 700 ] || exit 1
        other=$(import_stage_dir_for "$destination") || exit 1
        [ "$other" != "$stage" ] && [ -d "$other" ]
    ) || fail "a destination that is a mount point stages inside itself"
    pass "stage directory follows the destination filesystem"
}

test_nested_stage_preserves_site_entries() {
    local layout archive stage destination="$TMP_ROOT/nested-stage-dest"

    layout=$(make_layout nested-stage www/ database.sql)
    mkdir "$layout/www/.kvs-import-stage"
    printf 'archive content\n' > "$layout/www/.kvs-import-stage/asset.css"
    archive="$TMP_ROOT/nested-stage.tar"
    archive_of "$layout" "$archive"
    mkdir -p "$destination/.kvs-import-stage"
    printf 'existing content\n' > "$destination/.kvs-import-stage/existing.css"
    stage=$(
        # shellcheck disable=SC2329  # Exercise the mount-point choice in isolation.
        stat() { if [ "$4" = "$destination" ]; then echo 99; else echo 1; fi; }
        import_stage_dir_for "$destination"
    ) || fail 'a nested stage must be allocated'
    [ "$(cat "$destination/.kvs-import-stage/existing.css")" = 'existing content' ] || fail 'stage allocation must preserve existing entries'
    import_archive_extract "$archive" tar "$stage" || fail 'the collision fixture must extract'
    import_archive_settle "$stage" www/ database.sql '' "$TMP_ROOT/nested-stage-db" "$destination" >/dev/null || fail 'a site entry named like the old stage must settle'
    cmp "$layout/www/.kvs-import-stage/asset.css" "$destination/.kvs-import-stage/asset.css" || fail 'the hidden directory must keep its content'
    [ ! -e "$stage" ] || fail 'the private stage must be removed'

    # Even a name matching the newly allocated stage must never delete it.
    stage="$destination/.kvs-import-stage-collision"
    mkdir -p "$stage/www/${stage##*/}"
    printf 'keep staged content\n' > "$stage/www/${stage##*/}/asset.css"
    printf 'synthetic dump\n' > "$stage/database.sql"
    if import_archive_settle "$stage" www/ database.sql '' "$TMP_ROOT/stage-collision-db" "$destination" > "$TMP_ROOT/stage-collision.out" 2> "$TMP_ROOT/stage-collision.err"; then
        fail 'an exact extraction-stage collision must be refused'
    fi
    [ -f "$stage/www/${stage##*/}/asset.css" ] || fail 'a colliding entry must not delete the stage'
    grep -q 'extraction directory' "$TMP_ROOT/stage-collision.err" || fail 'the collision diagnostic must explain the conflict'
    pass 'a nested extraction stage preserves site entries and refuses an exact collision'
}

test_destination_marker_allows_a_repeat_of_the_same_source_only() {
    local destination="$TMP_ROOT/marker-dest"

    import_destination_ready "$destination" "archive:/root/site.zip" || fail "an absent destination is ready"
    mkdir -p "$destination"
    import_destination_ready "$destination" "archive:/root/site.zip" || fail "an empty destination is ready"
    import_mark_destination "$destination" "archive:/root/site.zip"
    echo x > "$destination/file"
    import_destination_ready "$destination" "archive:/root/site.zip" || fail "the same source may repeat"
    import_destination_ready "$destination" "archive:/root/other.zip" 2>/dev/null && fail "another source must be refused"
    import_destination_ready "$destination" "ssh://root@old:22/var/www/site" 2>/dev/null && fail "a remote source over an archive copy must be refused"
    rm "$destination/.kvs-import-source"
    import_destination_ready "$destination" "archive:/root/site.zip" 2>/dev/null && fail "a used directory without marker must be refused"
    (
        # shellcheck disable=SC2034  # Read by import_marker_file.
        IMPORT_MARKER_DIR="$TMP_ROOT/markers"
        import_mark_destination "$destination" "ssh://root@old:22/var/www/site" || exit 1
        [ "$(cat "$TMP_ROOT/markers/marker-dest.source")" = "ssh://root@old:22/var/www/site" ] || exit 2
        [ ! -e "$destination/.kvs-import-source" ] || exit 3
        import_destination_ready "$destination" "ssh://root@old:22/var/www/site" || exit 4
        import_destination_ready "$destination" "archive:/root/site.zip" 2>/dev/null && exit 5
        exit 0
    ) || fail "with IMPORT_MARKER_DIR the marker lives outside the destination (case $?)"
    pass "destination marker allows a repeat of the same source only"
}

test_take_over_moves_the_files_of_an_earlier_import() {
    local previous="$TMP_ROOT/takeover/dev.example.com" destination="$TMP_ROOT/takeover/example.com"
    local source="ssh://root@old:22/var/www/site"

    (
        # shellcheck disable=SC2034  # Read by import_marker_file.
        IMPORT_MARKER_DIR="$TMP_ROOT/takeover/markers"
        mkdir -p "$previous/contents/videos"
        echo video > "$previous/contents/videos/1.mp4"
        import_take_over_site "$previous" "$destination" "$source" 2>/dev/null && exit 1
        import_mark_destination "$previous" "$source" || exit 2
        import_take_over_site "$previous" "$destination" "ssh://root@other:22/var/www/site" 2>/dev/null && exit 3
        mkdir -p "$destination"
        echo x > "$destination/file"
        import_take_over_site "$previous" "$destination" "$source" 2>/dev/null && exit 4
        rm -rf "$destination"
        import_take_over_site "$previous" "$destination" "$source" > "$TMP_ROOT/takeover/out.txt" || exit 5
        grep -q "taken over as $destination" "$TMP_ROOT/takeover/out.txt" || exit 6
        [ -f "$destination/contents/videos/1.mp4" ] || exit 7
        [ ! -e "$previous" ] || exit 8
        [ "$(cat "$TMP_ROOT/takeover/markers/example.com.source")" = "$source" ] || exit 9
        [ ! -e "$TMP_ROOT/takeover/markers/dev.example.com.source" ] || exit 10
        import_destination_ready "$destination" "$source" || exit 11
        import_take_over_site "$destination" "$destination" "$source" || exit 12
        import_take_over_site "$TMP_ROOT/takeover/absent" "$destination" "$source" 2>/dev/null && exit 13
        exit 0
    ) || fail "the files of an earlier import must be taken over (case $?)"
    pass "the files of an earlier import under another domain are taken over"
}

test_url_domain_and_key_value_helpers() {
    [ "$(import_url_domain "https://www.Example.com/")" = example.com ] || fail "www and case must go"
    [ "$(import_url_domain "http://example.com:8080/path")" = example.com ] || fail "port and path must go"
    [ "$(import_url_domain "https://tube.example.com")" = tube.example.com ] || fail "subdomains stay"
    printf 'kvs_version=7.0.2\ndomain=example.com\nproject_url=https://a=b\n' > "$TMP_ROOT/kv.txt"
    [ "$(import_kv "$TMP_ROOT/kv.txt" kvs_version)" = 7.0.2 ] || fail "key read"
    [ "$(import_kv "$TMP_ROOT/kv.txt" project_url)" = "https://a=b" ] || fail "values keep their equal signs"
    printf 'hostname=old\033[31mred\033[0m\tend\n' > "$TMP_ROOT/kv-escape.txt"
    [ "$(import_kv "$TMP_ROOT/kv-escape.txt" hostname)" = 'old[31mred[0mend' ] || fail "control characters from the old server must be dropped: got '$(import_kv "$TMP_ROOT/kv-escape.txt" hostname)'"
    [ -z "$(import_kv "$TMP_ROOT/kv.txt" missing)" ] || fail "a missing key is empty"
    pass "url domain and key=value helpers"
}

# A fake ssh: records its options, ignores the target and runs the remote
# command locally with the same stdin and stdout. Connection sharing is
# played with a file: a connection that finds none at its control socket
# (-S, or the first ControlPath) authenticates ("auth" in the log) and,
# with ControlPersist, leaves one for the next to reuse ("mux"); -O exit
# removes it ("closed"). FAKE_SSH_INDEPENDENT_FAIL refuses a new
# connection of its own (-S or ControlPath=none), as a server wanting a
# password nobody gives.
make_fake_ssh() {
    local bin="$1"

    mkdir -p "$bin"
    cat > "$bin/ssh" <<EOF
#!/bin/bash
log="$bin/ssh.log"
socket="" master="" persist="" own=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o)
            echo "opt \$2" >> "\$log"
            case "\$2" in
                ControlPath=*) [ -n "\$socket" ] || socket=\${2#ControlPath=} ;;
                ControlMaster=*) [ -n "\$master" ] || master=\${2#ControlMaster=} ;;
                ControlPersist=*) [ -n "\$persist" ] || persist=\${2#ControlPersist=} ;;
            esac
            shift 2 ;;
        -S) echo "socket \$2" >> "\$log"; socket=\$2; own=yes; shift 2 ;;
        -p) echo "port \$2" >> "\$log"; shift 2 ;;
        -i) echo "key \$2" >> "\$log"; shift 2 ;;
        -l) echo "login \$2" >> "\$log"; shift 2 ;;
        -O)
            echo "control \$2" >> "\$log"
            if [ "\$2" = exit ] && [ -f "\$socket" ]; then
                rm -f "\$socket"
                echo "closed \$socket" >> "\$log"
            fi
            exit 0 ;;
        -*) echo "flag \$1" >> "\$log"; shift ;;
        *) break ;;
    esac
done
echo "target \$1" >> "\$log"
shift
echo "command \$*" >> "\$log"
sleep "\${FAKE_SSH_DELAY:-0}"
if [ -n "\${FAKE_SSH_FAIL_COMMAND:-}" ] && [[ "\$*" == *"\$FAKE_SSH_FAIL_COMMAND"* ]]; then exit 1; fi
if [ -n "\$socket" ] && [ "\$socket" != none ] && [ -f "\$socket" ]; then
    echo "mux \$socket" >> "\$log"
else
    if [ "\${FAKE_SSH_INDEPENDENT_FAIL:-}" = yes ] && { [ -n "\$own" ] || [ "\$socket" = none ]; }; then exit 255; fi
    echo "auth \${socket:-none}" >> "\$log"
    if [ -n "\${FAKE_SSH_STARTUP_GUARD:-}" ]; then
        mkdir "\$FAKE_SSH_STARTUP_GUARD" 2>/dev/null || exit 255
        sleep 0.02
        rmdir "\$FAKE_SSH_STARTUP_GUARD"
    fi
    if [ -n "\$socket" ] && [ "\$socket" != none ] && [ -n "\$persist" ] && [ "\${master:-no}" != no ]; then
        : > "\$socket"
    fi
fi
# A real sshd hands the command line to the login shell, which splits it.
# The tar fallback sends its command as a script to sh -s: log it too.
case "\$*" in
    'sh -s'|'sudo -n sh -s')
        script=\$(cat)
        echo "script \$script" >> "\$log"
        exec bash -c "\$*" <<< "\$script"
        ;;
esac
exec bash -c "\$*"
EOF
    chmod +x "$bin/ssh"
    # The remote commands run locally through the fake ssh: id answers
    # with a chosen uid, sudo drops its -n and runs the command, or fails
    # when FAKE_SUDO_FAIL is set.
    cat > "$bin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -u ]; then
    echo "${FAKE_UID:-1000}"
else
    echo "${FAKE_UID:-1000}"
fi
EOF
    cat > "$bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$bin/sudo.log"
if [ -n "\${FAKE_SUDO_FAIL:-}" ]; then
    echo "sudo: a password is required" >&2
    exit 1
fi
[ "\$1" != -n ] || shift
exec "\$@"
EOF
    # df -Pk, the free space of the old server's temporary directory, finds
    # FAKE_DF_AVAILABLE kB there (a roomy disk by default), or no answer
    # with FAKE_DF_FAIL; df -Pm finds FAKE_DF_LOCAL_MB MB under the
    # destination when it is set. Other uses of df get the real one.
    cat > "$bin/df" <<EOF
#!/bin/bash
if [ "\${1:-}" = -Pm ] && [ -n "\${FAKE_DF_LOCAL_MB:-}" ]; then
    echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
    echo "fake 1000000 1 \$FAKE_DF_LOCAL_MB 1% /"
    exit 0
fi
if [ "\${1:-}" = -Pk ]; then
    [ -z "\${FAKE_DF_FAIL:-}" ] || exit 1
    echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
    echo "fake 2147483648 1 \${FAKE_DF_AVAILABLE:-1073741824} 1% /"
    exit 0
fi
PATH=\${PATH//$bin:/}
exec df "\$@"
EOF
    chmod +x "$bin/id" "$bin/sudo" "$bin/df"
}

make_fake_exporter() {
    local file="$1"
    cat > "$file" <<'EOF'
#!/bin/bash
main() {
    while :; do
        case "${1:-}" in
            --size-timeout | --exclude | --include)
                echo "option $1 $2" >> "${FAKE_EXPORTER_LOG:-/dev/null}"
                shift 2
                ;;
            *) break ;;
        esac
    done
    local command="$1"
    local dir="${2:-/detected/site}"
    case "$command" in
        detect)
            printf 'kvs_export=1\nsite_dir=%s\nkvs_version=7.0.2\ndomain=old.example.com\nproject_path=%s\ntables_prefix=ktvs_\ncompressor=gzip\nrsync=yes\n' "$dir" "$dir"
            ;;
        dump)
            printf 'CREATE TABLE `ktvs_options` (id int);\n-- Dump completed on now\n' | gzip -c
            ;;
        *) echo "unknown command" >&2; return 1 ;;
    esac
}
main "$@"; exit $?
EOF
}

test_external_search_plugin_is_recognized() {
    local site="$TMP_ROOT/search-site" plugin

    make_site "$site" /home/old/www
    import_external_search_host "$site" 2>/dev/null && fail "a site without the plugin has no external search"
    plugin="$site/admin/data/plugins/external_search"
    mkdir -p "$plugin"
    printf 'a:4:{s:22:"enable_external_search";i:0;s:15:"display_results";i:1;s:8:"api_call";s:66:"http://search.old.example.com:8080/kvs_sphinx.php?query=%%QUERY%%&from=%%FROM%%";s:12:"outgoing_url";s:23:"https://old.example.com";}' > "$plugin/data.dat"
    import_external_search_host "$site" 2>/dev/null && fail "a disabled plugin must not count"
    printf 'a:4:{s:22:"enable_external_search";i:1;s:15:"display_results";i:1;s:8:"api_call";s:66:"http://search.old.example.com:8080/kvs_sphinx.php?query=%%QUERY%%&from=%%FROM%%";s:12:"outgoing_url";s:23:"https://old.example.com";}' > "$plugin/data.dat"
    [ "$(import_external_search_host "$site")" = search.old.example.com ] || fail "the host of the search API must be reported (got: $(import_external_search_host "$site"))"
    pass "the external search plugin of a site is recognized with its API host"
}

test_ssh_setup_validates_and_builds_the_options() {
    local rsh

    (IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl" import_ssh_setup old.example.com 22 root "" no 2>/dev/null) || fail "a plain host must be accepted"
    (IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl" import_ssh_setup "old example" 22 root "" no 2>/dev/null) && fail "a host with a space must be refused"
    (IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl" import_ssh_setup old.example.com abc root "" no 2>/dev/null) && fail "a non numeric port must be refused"
    (IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl" import_ssh_setup old.example.com 70000 root "" no 2>/dev/null) && fail "a port above 65535 must be refused"
    (IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl" import_ssh_setup old.example.com 22 "root;rm" "" no 2>/dev/null) && fail "a user with shell characters must be refused"
    (IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl" import_ssh_setup old.example.com 22 root "$TMP_ROOT/absent-key" no 2>/dev/null) && fail "an unreadable key must be refused"

    IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl" import_ssh_setup old.example.com 2222 deploy "" yes yes
    [ "$IMPORT_SSH_TARGET" = deploy@old.example.com ] || fail "target user@host"
    [ "$(stat -c %a "$TMP_ROOT/ctl")" = 700 ] || fail "the control directory is private"
    printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^StrictHostKeyChecking=accept-new$' || fail "unknown hosts are accepted only on request"
    printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^ControlMaster=auto$' || fail "one multiplexed connection"
    printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q "^ControlPath=$TMP_ROOT/ctl/ssh-%C$" || fail "control path in the private directory"
    printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^BatchMode=yes$' || fail "batch mode when asked"
    printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^2222$' || fail "the port is passed"
    printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^-i$' && fail "no identity option without a key"

    touch "$TMP_ROOT/my key"
    IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl" import_ssh_setup old.example.com 22 root "$TMP_ROOT/my key" no
    printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^BatchMode=yes$' && fail "no batch mode when not asked"
    printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^StrictHostKeyChecking' && fail "ssh asks about an unknown host key unless told otherwise"
    printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^IdentitiesOnly=yes$' || fail "a given key is the only one tried"
    rsh=$(import_ssh_rsh)
    [[ "$rsh" == "ssh -o ControlMaster=auto -o ControlPath=$TMP_ROOT/ctl/ssh-%C -o ControlPersist=15m -o ServerAliveInterval=30 -o ConnectTimeout=20 -p 22 -i '$TMP_ROOT/my key' -o IdentitiesOnly=yes" ]] ||
        fail "the rsync shell string quotes the key path: $rsh"

    import_remote_path_ok /var/www/example.com || fail "a plain absolute path is fine"
    import_remote_path_ok "relative/path" && fail "a relative path is refused"
    import_remote_path_ok "/var/www/my site" && fail "a space is refused"
    import_remote_path_ok '/var/www/$(id)' && fail "shell characters are refused"
    pass "ssh setup validates its inputs and builds the options"
}

test_a_password_reaches_ssh_through_sshpass() {
    local bin="$TMP_ROOT/sshpass-bin"

    make_fake_ssh "$bin"
    # A fake sshpass: records its mode and the password it was given
    # through the environment, then runs ssh.
    cat > "$bin/sshpass" <<EOF
#!/bin/bash
echo "sshpass \$1 SSHPASS=[\${SSHPASS-}]" >> "$bin/sshpass.log"
[ "\$1" != -e ] || shift
exec "\$@"
EOF
    chmod +x "$bin/sshpass"
    (
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl" import_ssh_setup old.example.com 22 root "" yes no "s3cret pass" || exit 1
        [ "${IMPORT_SSH_COMMAND[*]}" = "sshpass -e ssh" ] || exit 2
        [ "${SSHPASS-}" = "s3cret pass" ] || exit 3
        printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^BatchMode=yes$' && exit 4
        printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^StrictHostKeyChecking=accept-new$' || exit 5
        printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^NumberOfPasswordPrompts=1$' || exit 6
        rsh=$(import_ssh_rsh)
        [[ "$rsh" == "sshpass -e ssh -o ControlMaster=auto"* ]] || exit 7
        [[ "$rsh" != *s3cret* ]] || exit 8
        out=$(import_ssh echo remote-ok < /dev/null) || exit 9
        [ "$out" = remote-ok ] || exit 10
        grep -q '^sshpass -e SSHPASS=\[s3cret pass\]$' "$bin/sshpass.log" || exit 11
        grep -q '^command echo remote-ok$' "$bin/ssh.log" || exit 12
        # Without a password ssh runs bare, batch mode as asked.
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl" import_ssh_setup old.example.com 22 root "" yes no "" || exit 13
        [ "${IMPORT_SSH_COMMAND[*]}" = ssh ] || exit 14
        printf '%s\n' "${IMPORT_SSH_OPTS[@]}" | grep -q '^BatchMode=yes$' || exit 15
        exit 0
    ) || fail "a password must reach ssh through sshpass and its environment only (case $?)"
    pass "a password reaches ssh through sshpass and its environment only"
}

test_the_old_nginx_configuration_is_saved_and_its_rewrites_recovered() {
    local report="$TMP_ROOT/nginx-report.txt" saved="$TMP_ROOT/old-nginx.conf" lines rules

    {
        echo "kvs_export=1"
        echo "nginx_config_lines=3"
        echo "entry_1=contents|1|kvs|copied"
        printf 'nginx_config_1=# configuration file /etc/nginx/nginx.conf:\n'
        printf 'nginx_config_2=http {\tinclude conf.d/*.conf;\001 }\n'
        printf 'nginx_config_3=}\n'
    } > "$report"
    lines=$(import_nginx_config_save "$report" "$saved") || fail "a report with a configuration must be saved"
    [ "$lines" = 3 ] || fail "three lines, got $lines"
    [ "$(stat -c %a "$saved")" = 600 ] || fail "the saved configuration is private"
    [ "$(sed -n 2p "$saved")" = $'http {\tinclude conf.d/*.conf; }' ] || fail "tabs stay, control characters go: $(sed -n 2p "$saved")"
    echo "kvs_export=1" > "$report"
    import_nginx_config_save "$report" "$saved.none" 2>/dev/null && fail "a report without a configuration must fail"
    [ ! -e "$saved.none" ] || fail "no file without a configuration"

    cat > "$saved" <<'EOF'
# configuration file /etc/nginx/nginx.conf:
http {
    include /etc/nginx/conf.d/*.conf;
}
# configuration file /etc/nginx/conf.d/other.conf:
server {
    server_name other.example.com;
    root /var/www/other;
    rewrite ^/other$ /other.php last;
}
# configuration file /etc/nginx/conf.d/site.conf:
server {
    listen 80;
    server_name example.com;
    root /var/www/website/;
    # rewrite ^/commented$ /no.php last;
    rewrite ^/videos/$ /videos.php last;
    rewrite "^/video/([0-9]{1,8})/([^/]+)/$" /view_video.php?id=$1&dir=$2 last;
    location /admin/ {
        root /var/www/website;
    }
    location ~ "^/get_file/([0-9]{1,3})/" {
        internal;
    }
}
server {
    listen 443 ssl;
    server_name example.com;
    root /var/www/website;
    rewrite ^/videos/$ /videos.php last;
    rewrite "^/video/([0-9]{1,8})/([^/]+)/$" /view_video.php?id=$1&dir=$2 last;
    rewrite ^/https-only$ /x.php last;
}
EOF
    rules=$(import_nginx_rewrites_from_config "$saved" /var/www/website)
    [ "$rules" = $'rewrite ^/videos/$ /videos.php last;\nrewrite "^/video/([0-9]{1,8})/([^/]+)/$" /view_video.php?id=$1&dir=$2 last;\nrewrite ^/https-only$ /x.php last;' ] ||
        fail "the rules of the blocks serving the site, once each, nothing from the other site or the comments: $rules"
    rules=$(import_nginx_rewrites_from_config "$saved" /home/elsewhere /var/www/website)
    [[ "$rules" == "rewrite ^/videos/"* ]] || fail "the project path names the site too: $rules"
    [ -z "$(import_nginx_rewrites_from_config "$saved" /var/www/nothing)" ] || fail "no block serving the site, no rules"
    pass "the old nginx configuration is saved and its rewrites recovered"
}

test_the_rewrite_recovery_follows_the_includes_of_the_server_block() {
    local dump="$TMP_ROOT/old-nginx-includes.conf" rules

    cat > "$dump" <<'EOF'
# configuration file /etc/nginx/nginx.conf:
http {
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
# configuration file /etc/nginx/conf.d/other.conf:
server {
    include globals/other.conf;
    rewrite ^/other$ /other.php last;
}
# configuration file /etc/nginx/globals/other.conf:
root /var/www/other;
# configuration file /etc/nginx/sites-enabled/site.conf:
server {
    listen 80;
    server_name example.com;
    include globals/kvs.conf;
    include "/etc/nginx/snippets/admin-?.conf";
}
# configuration file /etc/nginx/globals/kvs.conf:
root /var/www/website;
include 'globals/rewrites/*.conf';
# configuration file /etc/nginx/globals/rewrites/videos.conf:
rewrite ^/videos/$ /videos.php last;
# configuration file /etc/nginx/globals/rewrites/albums.conf:
rewrite ^/albums/$ /albums.php last;
# configuration file /etc/nginx/snippets/admin-a.conf:
rewrite ^/admin/a$ /admin/a.php last;
# configuration file /etc/nginx/snippets/admin-other.conf:
rewrite ^/never$ /never.php last;
EOF
    rules=$(import_nginx_rewrites_from_config "$dump" /var/www/website)
    [ "$rules" = $'rewrite ^/albums/$ /albums.php last;\nrewrite ^/videos/$ /videos.php last;\nrewrite ^/admin/a$ /admin/a.php last;' ] ||
        fail "the root and the rules of the included files count for the block, a pattern names its files in order: $rules"
    [ "$(import_nginx_rewrites_from_config "$dump" /var/www/other)" = 'rewrite ^/other$ /other.php last;' ] ||
        fail "a root kept in an included file qualifies the block"
    # Gathered without nginx, the dump does not start with nginx.conf: a
    # relative include is found by its ending.
    cat > "$dump" <<'EOF'
# configuration file /etc/nginx/sites-enabled/site.conf:
server {
    root /var/www/website;
    include snippets/kvs.conf;
}
# configuration file /etc/nginx/snippets/kvs.conf:
rewrite ^/videos/$ /videos.php last;
EOF
    [ "$(import_nginx_rewrites_from_config "$dump" /var/www/website)" = 'rewrite ^/videos/$ /videos.php last;' ] ||
        fail "a relative include is found by its ending when the dump does not start with nginx.conf"
    pass "the rewrite recovery follows the includes of the server block"
}

# The progress counts whole seconds from the moment its awk starts, and the
# first record reaches awk some milliseconds later, through tr: a pipe
# started late in a second shows it at 0:00:01. Started at the top of a
# second, it shows 0:00:00 unless the record takes most of a second.
start_of_a_second() {
    local left=$((1000000 - 10#${EPOCHREALTIME: -6}))

    sleep "$((left / 1000000)).$(printf '%06d' $((left % 1000000)))"
}

test_the_transfer_is_counted_first_and_shown_against_the_count() {
    local stats out status

    stats=$'\nNumber of files: 3,012 (reg: 3,008, dir: 4)\nNumber of created files: 3,011 (reg: 3,008, dir: 3)\nNumber of deleted files: 0\nNumber of regular files transferred: 3,008\nTotal file size: 38,000,000 bytes\nTotal transferred file size: 38,000,000 bytes\nLiteral data: 0 bytes\n'
    [ "$(import_rsync_stats_totals <<< "$stats")" = $'3008\t38000000\t3008\t38000000\t3012' ] ||
        fail "the statistics of the dry run give the files and bytes to transfer and the site's: $(import_rsync_stats_totals <<< "$stats")"
    [ "$(printf 'Number of files transferred: 12\nTotal transferred file size: 3400 bytes\n' | import_rsync_stats_totals)" = $'12\t3400\t0\t0\t0' ] ||
        fail "the wording of an older rsync is read too"
    [ -z "$(import_rsync_stats_totals <<< "rsync: connection unexpectedly closed")" ] || fail "no statistics, no totals"
    [ "$(import_bytes_text 38000000)" = "36 MB" ] && [ "$(import_bytes_text 4499689472)" = "4.1 GB" ] && [ "$(import_bytes_text 3400)" = "3 kB" ] ||
        fail "sizes for the summary line: $(import_bytes_text 38000000), $(import_bytes_text 4499689472), $(import_bytes_text 3400)"
    [ "$(import_count_text 305965)" = "305,965" ] && [ "$(import_count_text 12)" = "12" ] && [ "$(import_count_text 1000)" = "1,000" ] ||
        fail "counts for the summary line: $(import_count_text 305965)"

    # The progress records of rsync, carriage-return separated, with a
    # message in between, shown as a log (no terminal): the first record
    # against the totals with the scan counted, the message as it is, the
    # end summed up.
    start_of_a_second
    out=$(printf '\r              0   0%%    0.00kB/s    0:00:00 (xfr#0, ir-chk=1000/3012)\r        4000000  10%%    4.03MB/s    0:00:00 (xfr#1, ir-chk=1007/3012)\rskipping non-regular file "x"\n       32042000  84%%    3.91MB/s    0:00:07 (xfr#2029, ir-chk=979/3012)\r       38000000 100%%    3.90MB/s    0:00:09 (xfr#3008, to-chk=0/3012)\n' |
        import_rsync_progress 38000000 3008 no)
    [ "$(head -n 4 <<< "$out")" = "  Copied:  0 B of 36.2 MB (0%), 0 of 3,008 files
  Checked: 2,012 of 3,012 entries found so far, scan running
  Rates:   0 B/s, 0 files/s copied, ? entries/s checked
  Time:    0:00:00 elapsed, time left unknown yet" ] ||
        fail "the first record is shown against the totals, the scan counted: $out"
    grep -q '^skipping non-regular file "x"$' <<< "$out" || fail "what else rsync prints passes through: $out"
    grep -q '^  Transferred 3,008 files, 36.2 MB in 0:00:0[0-9]$' <<< "$out" || fail "the end is summed up: $out"
    grep -q '^  Average .* files/s; 3,012 entries checked$' <<< "$out" || fail "the end counts the checks: $out"
    # Without totals the counts show alone; the scan, once done, is the whole.
    out=$(printf '       38000000 100%%    3.90MB/s    0:00:09 (xfr#3008, to-chk=0/3012)\n' | import_rsync_progress 0 0 no)
    grep -q '^  Copied:  36.2 MB, 3,008 files$' <<< "$out" || fail "without totals the counts show alone: $out"
    grep -q '^  Checked: 3,012 of 3,012 entries (100%)$' <<< "$out" || fail "a scan that is done is the whole: $out"
    grep -q '^  Time:    0:00:0[0-9] elapsed, time left unknown yet$' <<< "$out" || fail "no time left before five seconds: $out"
    # Without a scan figure (a record inside a file) nothing tells what is
    # left.
    start_of_a_second
    out=$(printf '       32768   0%%    0.00kB/s    0:00:00  \n' | import_rsync_progress 0 0 no)
    [ "$(head -n 3 <<< "$out")" = "  Copied:  32 kB, 0 files
  Rates:   0 B/s, 0 files/s copied
  Time:    0:00:00 elapsed, left unknown: no complete count of this site yet" ] || fail "a record without a scan figure: $out"
    # On a terminal the lines are rewritten in place (cursor up one line a
    # line, the rest of the screen cleared) and the end replaces them with
    # its summary.
    out=$(printf '       38000000 100%%    3.90MB/s    0:00:09 (xfr#3008, to-chk=0/3012)\n' | import_rsync_progress 38000000 3008 yes | tr '\r\033' '|^')
    [[ "$out" == "  Copied:  36.2 MB of 36.2 MB (100%), 3,008 of 3,008 files^[K"$'\n'"  Checked: 3,012 of 3,012 entries (100%)^[K"$'\n'"  Rates:   "*"^[K"$'\n'"  Time:    0:00:0"?" elapsed, time left unknown yet^[J|^[3A^[J  Transferred 3,008 files"*$'\n'"  Average "*"; 3,012 entries checked" ]] ||
        fail "on a terminal the lines are rewritten in place: $out"
    # The count of the transfer has a time budget: past it, no totals and
    # status 124 from timeout (which runs rsync by name, so the stub is a
    # program on the PATH).
    mkdir -p "$TMP_ROOT/slow-bin"
    printf '#!/bin/bash\nsleep 3\n' > "$TMP_ROOT/slow-bin/rsync"
    chmod +x "$TMP_ROOT/slow-bin/rsync"
    status=0
    out=$(PATH="$TMP_ROOT/slow-bin:$PATH" IMPORT_SIZE_TIMEOUT=1 import_rsync_totals -a src/ dst/) || status=$?
    [ "$status" -eq 124 ] && [ -z "$out" ] || fail "a count past its budget must give nothing and status 124, got $status: '$out'"
    pass "the transfer is counted first and shown against the count"
}

test_remote_detect_dump_and_files_go_through_one_ssh() {
    local bin="$TMP_ROOT/ssh-bin" exporter="$TMP_ROOT/fake-export.sh" site destination

    make_fake_ssh "$bin"
    make_fake_exporter "$exporter"
    site="$TMP_ROOT/remote-site"
    make_site "$site" "$site"
    mkdir -p "$TMP_ROOT/remote-store"
    echo "stored" > "$TMP_ROOT/remote-store/big.mp4"
    ln -s "$TMP_ROOT/remote-store" "$site/contents/store"
    ln -s videos "$site/contents/inside"
    echo "stale" > "$TMP_ROOT/stale.txt"
    destination="$TMP_ROOT/remote-dest"
    (
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl2" import_ssh_setup old.example.com 22 root "" yes
        FAKE_UID=0 import_remote_privileges || exit 30
        [ "$IMPORT_REMOTE_PRIVILEGES" = root ] || exit 31
        [ "${#IMPORT_REMOTE_PREFIX[@]}" -eq 0 ] || exit 32
        import_remote_detect "$exporter" "" "$TMP_ROOT/detect.txt" || exit 1
        [ "$(import_kv "$TMP_ROOT/detect.txt" kvs_version)" = 7.0.2 ] || exit 2
        [ "$(import_kv "$TMP_ROOT/detect.txt" site_dir)" = /detected/site ] || exit 3
        grep -q '^command bash -s -- detect$' "$bin/ssh.log" || exit 4
        import_remote_detect "$exporter" "$site" "$TMP_ROOT/detect2.txt" || exit 5
        [ "$(import_kv "$TMP_ROOT/detect2.txt" site_dir)" = "$site" ] || exit 6
        import_remote_detect "$exporter" "$site" "$TMP_ROOT/detect-budget.txt" 300 || exit 41
        grep -q "^command bash -s -- --size-timeout 300 detect $site\$" "$bin/ssh.log" || exit 42
        [ "$(import_kv "$TMP_ROOT/detect-budget.txt" site_dir)" = "$site" ] || exit 43
        FAKE_EXPORTER_LOG="$TMP_ROOT/exporter.log" import_remote_detect "$exporter" "$site" "$TMP_ROOT/detect-choice.txt" 300 "contents/videos_sources backup" ".well-known" || exit 44
        grep -q "^command bash -s -- --size-timeout 300 --exclude contents/videos_sources --exclude backup --include .well-known detect $site\$" "$bin/ssh.log" || exit 45
        import_remote_detect "$exporter" "$site" "$TMP_ROOT/detect-bad.txt" 300 "../etc" 2> "$TMP_ROOT/bad.err" && exit 46
        grep -q "plain paths" "$TMP_ROOT/bad.err" || exit 47
        import_remote_detect "$exporter" "$site" "$TMP_ROOT/detect-bad.txt" 300 "" 'a;b' 2> "$TMP_ROOT/bad.err" && exit 48
        import_remote_detect "$exporter" "/var/www/my site" "$TMP_ROOT/detect3.txt" 2>/dev/null && exit 7
        # A site directory the search found can hold a character the
        # transfer refuses; the refusal must say so, not fail in silence.
        import_remote_dump "$exporter" "/var/www/my site" "$TMP_ROOT/refused.sql.gz" 2> "$TMP_ROOT/refused.err" && exit 37
        grep -q '^ERROR: .*/var/www/my site' "$TMP_ROOT/refused.err" || exit 38
        import_remote_files "/var/www/my site" "$TMP_ROOT/refused-dest" yes 2> "$TMP_ROOT/refused.err" && exit 39
        grep -q '^ERROR: .*/var/www/my site' "$TMP_ROOT/refused.err" || exit 40
        grep -q '^target root@old.example.com$' "$bin/ssh.log" || exit 8
        grep -q '^opt BatchMode=yes$' "$bin/ssh.log" || exit 9

        import_remote_dump "$exporter" "$site" "$TMP_ROOT/remote.sql.gz" || exit 10
        [ "$(import_inspect_dump "$TMP_ROOT/remote.sql.gz" ktvs_)" = $'1\t\t0\tyes\t' ] || exit 11

        import_remote_files "$site" "$destination" yes > "$TMP_ROOT/transfer-out.txt" 2>&1 || exit 12
        grep -Eq '^  To transfer:     [0-9,]+ files, [0-9.]+ [kMGT]B of the site'"'"'s [0-9,]+ files, [0-9.]+ [kMGT]B$' "$TMP_ROOT/transfer-out.txt" || exit 41
        grep -Eq '^  Transferred [0-9,]+ files, [0-9.]+ [kMGT]?B in [0-9]+:[0-9]{2}:[0-9]{2}$' "$TMP_ROOT/transfer-out.txt" || exit 42
        [ "$(grep -c '^command rsync --server' "$bin/ssh.log")" -eq 2 ] || exit 43
        [ -f "$destination/admin/include/setup.php" ] || exit 13
        [ -f "$destination/contents/videos/1.mp4" ] || exit 14
        grep -q '^command rsync --server' "$bin/ssh.log" || exit 15
        [ ! -e "$destination/.rsync-partial" ] || exit 23
        [ -d "$destination/contents/store" ] && [ ! -L "$destination/contents/store" ] || exit 33
        [ "$(cat "$destination/contents/store/big.mp4")" = stored ] || exit 34
        [ -L "$destination/contents/inside" ] || exit 35
        cp "$TMP_ROOT/stale.txt" "$destination/stale.txt"
        import_remote_files "$site" "$destination" yes >/dev/null 2>&1 || exit 16
        [ ! -e "$destination/stale.txt" ] || exit 17

        rm -rf "$destination"
        import_remote_files "$site" "$destination" no || exit 19
        [ -f "$destination/admin/include/setup.php" ] || exit 20
        grep -q '^command sh -s$' "$bin/ssh.log" || exit 21
        grep -q "^script exec tar -C '$site' -chf - .\$" "$bin/ssh.log" || exit 21
        [ -f "$destination/contents/store/big.mp4" ] && [ ! -L "$destination/contents/store" ] || exit 36

        # What the exporter reports as staying behind stays behind: the
        # temporary files leave their directory empty, an excluded
        # directory and a hidden one do not arrive, with rsync and with tar.
        mkdir -p "$site/tmp" "$site/backup" "$site/.well-known" "$site/contents/videos_sources"
        echo part > "$site/tmp/upload.part"
        echo old > "$site/backup/old.sql"
        echo token > "$site/.well-known/token"
        echo source > "$site/contents/videos_sources/s.mp4"
        rm -rf "$destination"
        import_remote_files "$site" "$destination" yes '/tmp/*' '/backup' '/.well-known' '/contents/videos_sources' >/dev/null 2>&1 || exit 49
        [ -d "$destination/tmp" ] && [ ! -e "$destination/tmp/upload.part" ] || exit 50
        [ ! -e "$destination/backup" ] && [ ! -e "$destination/.well-known" ] && [ ! -e "$destination/contents/videos_sources" ] || exit 51
        [ -f "$destination/contents/videos/1.mp4" ] || exit 52
        rm -rf "$destination"
        import_remote_files "$site" "$destination" no '/tmp/*' '/backup' '/.well-known' '/contents/videos_sources' || exit 53
        [ -d "$destination/tmp" ] && [ ! -e "$destination/tmp/upload.part" ] || exit 54
        [ ! -e "$destination/backup" ] && [ ! -e "$destination/.well-known" ] && [ ! -e "$destination/contents/videos_sources" ] || exit 55
        [ -f "$destination/contents/videos/1.mp4" ] || exit 56
        grep -q "^script exec tar -C '$site' --wildcards '--exclude=./tmp/\*' --no-wildcards '--exclude=./backup' --no-wildcards '--exclude=./.well-known' --no-wildcards '--exclude=./contents/videos_sources' -chf - .\$" "$bin/ssh.log" || exit 57
        import_remote_files "$site" "$destination" no 'backup' 2>/dev/null && exit 58
        rm -rf "$site/tmp" "$site/backup" "$site/.well-known" "$site/contents/videos_sources"

        import_ssh_close
        grep -q '^control exit$' "$bin/ssh.log" || exit 22
        exit 0
    ) || fail "remote detect, dump and files must go through the ssh plumbing (case $?)"
    pass "remote detect, dump and files go through one ssh connection"
}

# An excluded name is a name, not a pattern, for rsync as for tar: what the
# exporter reported as left behind is what stays behind, and a name a
# wildcard reading would match comes through. A link to a FIFO, a device or
# a socket brings nothing: rsync skips what is neither file, directory nor
# link (--no-devices --no-specials), as it does for one inside the site.
test_excluded_names_are_literal_and_special_files_never_arrive() {
    local bin="$TMP_ROOT/literal-bin" site="$TMP_ROOT/literal-site" destination="$TMP_ROOT/literal-dest" name

    make_fake_ssh "$bin"
    make_site "$site" "$site"
    mkdir -p "$TMP_ROOT/literal-outside"
    echo "root only" > "$TMP_ROOT/literal-outside/secret"
    chmod 600 "$TMP_ROOT/literal-outside/secret"
    for name in '.c[1]' '.c1' 'back\x' 'backx' '.st*r' '.star'; do
        mkdir -p "$site/$name"
        echo kept > "$site/$name/kept.txt"
    done
    ln -s "$TMP_ROOT/literal-outside/secret" "$site/.c[1]/evil"
    mkfifo "$TMP_ROOT/literal-outside/fifo" "$site/contents/pipe"
    ln -s "$TMP_ROOT/literal-outside/fifo" "$site/contents/innocent"
    (
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/literal-ctl" import_ssh_setup old.example.com 22 root "" yes
        FAKE_UID=0 import_remote_privileges || exit 30
        import_remote_files "$site" "$destination" yes '/.c[1]' '/back\x' '/.st*r/*' > "$TMP_ROOT/literal.out" 2>&1 || exit 1
        [ -f "$destination/contents/videos/1.mp4" ] || exit 2
        [ ! -e "$destination/.c[1]" ] || exit 3
        [ -f "$destination/.c1/kept.txt" ] || exit 4
        [ ! -e "$destination/back\x" ] || exit 5
        [ -f "$destination/backx/kept.txt" ] || exit 6
        [ -d "$destination/.st*r" ] && [ ! -e "$destination/.st*r/kept.txt" ] || exit 7
        [ -f "$destination/.star/kept.txt" ] || exit 8
        [ ! -e "$destination/contents/innocent" ] && [ ! -L "$destination/contents/innocent" ] || exit 9
        [ ! -e "$destination/contents/pipe" ] || exit 10
        import_ssh_close
        exit 0
    ) || fail "excluded names must stay behind literally and special files never arrive (case $?): $(cat "$TMP_ROOT/literal.out" 2>/dev/null)"
    pass "excluded names are literal and special files never arrive"
}

test_a_user_with_sudo_runs_the_remote_side_through_it() {
    local bin="$TMP_ROOT/ssh-bin-sudo" exporter="$TMP_ROOT/fake-export-sudo.sh" site destination

    make_fake_ssh "$bin"
    make_fake_exporter "$exporter"
    site="$TMP_ROOT/remote-site-sudo"
    make_site "$site" "$site"
    destination="$TMP_ROOT/remote-dest-sudo"
    (
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl3" import_ssh_setup old.example.com 22 deploy "" yes
        FAKE_UID=1000 import_remote_privileges || exit 1
        [ "$IMPORT_REMOTE_PRIVILEGES" = sudo ] || exit 2
        [ "$IMPORT_REMOTE_SUDO" = yes ] || exit 3
        grep -q '^sudo -n true$' "$bin/sudo.log" || exit 4
        import_remote_detect "$exporter" "$site" "$TMP_ROOT/detect-sudo.txt" || exit 5
        grep -q "^command sudo -n bash -s -- detect $site\$" "$bin/ssh.log" || exit 6
        [ "$(import_kv "$TMP_ROOT/detect-sudo.txt" kvs_version)" = 7.0.2 ] || exit 7
        import_remote_dump "$exporter" "$site" "$TMP_ROOT/remote-sudo.sql.gz" || exit 8
        grep -q "^command sudo -n bash -s -- dump $site\$" "$bin/ssh.log" || exit 9
        import_remote_files "$site" "$destination" yes >/dev/null 2>&1 || exit 10
        grep -q '^sudo -n rsync --server' "$bin/sudo.log" || exit 11
        [ -f "$destination/contents/videos/1.mp4" ] || exit 12
        rm -rf "$destination"
        import_remote_files "$site" "$destination" no || exit 13
        grep -q '^command sudo -n sh -s$' "$bin/ssh.log" || exit 14
        grep -q "^script exec tar -C '$site' -chf - .\$" "$bin/ssh.log" || exit 14
        [ -f "$destination/contents/videos/1.mp4" ] || exit 15

        FAKE_UID=1000 FAKE_SUDO_FAIL=1 import_remote_privileges || exit 16
        [ "$IMPORT_REMOTE_PRIVILEGES" = none ] || exit 17
        [ "${#IMPORT_REMOTE_PREFIX[@]}" -eq 0 ] || exit 18
        [ "$IMPORT_REMOTE_SUDO_ERROR" = "sudo: a password is required" ] || exit 21
        import_remote_detect "$exporter" "$site" "$TMP_ROOT/detect-none.txt" || exit 19
        grep -q "^command bash -s -- detect $site\$" "$bin/ssh.log" || exit 20
        exit 0
    ) || fail "a user with passwordless sudo must run the remote side through it, one without runs plain (case $?)"
    pass "a user with passwordless sudo runs the remote side through it"
}

test_password_protected_archives_are_refused_with_a_reason() {
    local layout stage out

    command -v zip >/dev/null 2>&1 || fail "zip is needed to build the fixtures"
    [ -n "$SEVEN_ZIP" ] || fail "a 7-Zip command is needed to build the fixtures"
    layout=$(make_layout locked www/ database.sql)
    (cd "$layout" && zip -q -r -y -P secret "$TMP_ROOT/locked.zip" .)
    (cd "$layout" && "$SEVEN_ZIP" a -bd -bso0 -psecret "$TMP_ROOT/locked.7z" . >/dev/null)
    (cd "$layout" && "$SEVEN_ZIP" a -bd -bso0 -psecret -mhe=on "$TMP_ROOT/locked-header.7z" . >/dev/null)

    # Listings still work without the password, except with an encrypted header.
    import_archive_list "$TMP_ROOT/locked.zip" unzip | grep -q 'admin/include/setup.php$' || fail "an encrypted zip still lists"
    import_archive_list "$TMP_ROOT/locked.7z" "$SEVEN_ZIP" | grep -q 'admin/include/setup.php$' || fail "an encrypted 7z still lists"
    out=$(import_archive_list "$TMP_ROOT/locked-header.7z" "$SEVEN_ZIP" 2>&1 >/dev/null) && fail "an encrypted 7z header cannot be listed without the password"
    echo "$out" | grep -q 'password protected' || fail "the listing failure must name the password (got: $out)"

    # The configuration cannot come out, the extraction neither, and nothing waits for a prompt.
    out=$(import_archive_peek "$TMP_ROOT/locked.zip" unzip www/ "$TMP_ROOT/peek-locked-zip" 2>&1 >/dev/null) && fail "an encrypted zip must not peek"
    echo "$out" | grep -q 'password protected' || fail "the zip peek failure must name the password (got: $out)"
    out=$(import_archive_peek "$TMP_ROOT/locked.7z" "$SEVEN_ZIP" www/ "$TMP_ROOT/peek-locked-7z" 2>&1 >/dev/null) && fail "an encrypted 7z must not peek"
    echo "$out" | grep -q 'password protected' || fail "the 7z peek failure must name the password (got: $out)"
    stage="$TMP_ROOT/stage-locked"
    out=$(import_archive_extract "$TMP_ROOT/locked.zip" unzip "$stage" 2>&1 >/dev/null) && fail "an encrypted zip must not extract"
    echo "$out" | grep -q 'password protected' || fail "the zip extraction failure must name the password (got: $out)"
    rm -rf "$stage"
    out=$(import_archive_extract "$TMP_ROOT/locked.7z" "$SEVEN_ZIP" "$stage" 2>&1 >/dev/null) && fail "an encrypted 7z must not extract"
    echo "$out" | grep -q 'password protected' || fail "the 7z extraction failure must name the password (got: $out)"
    rm -rf "$stage"
    pass "password protected archives are refused with a reason, without waiting on a prompt"
}

test_links_leaving_the_site_are_listed_and_the_copy_follows_them() {
    local site="$TMP_ROOT/linked-site" store="$TMP_ROOT/linked-store" destination="$TMP_ROOT/linked-dest"

    make_site "$site" /home/old/www
    mkdir -p "$store"
    echo "stored" > "$store/big.mp4"
    ln -s "$store" "$site/contents/store"
    ln -s 1.mp4 "$site/contents/videos/2.mp4"
    ln -s videos "$site/contents/inside"
    # Neither a FIFO of the site nor one a link leads to is copied.
    mkfifo "$site/contents/pipe" "$TMP_ROOT/linked-fifo"
    ln -s "$TMP_ROOT/linked-fifo" "$store/fifo"
    (
        # shellcheck disable=SC2034  # Read by import_marker_file and import_place_site.
        IMPORT_MARKER_DIR="$TMP_ROOT/linked-markers" IMPORT_SITE_LINKS=yes
        import_place_site "$site" "$destination" >/dev/null || exit 1
        [ -d "$destination/contents/store" ] && [ ! -L "$destination/contents/store" ] || exit 2
        [ "$(cat "$destination/contents/store/big.mp4")" = stored ] || exit 3
        [ -L "$destination/contents/inside" ] || exit 4
        [ -L "$destination/contents/videos/2.mp4" ] || exit 5
        [ ! -e "$destination/contents/pipe" ] || exit 6
        [ ! -e "$destination/contents/store/fifo" ] && [ ! -L "$destination/contents/store/fifo" ] || exit 7
        exit 0
    ) || fail "the copy of a directory must bring the targets of the links leaving the site, keep the inside ones and no special file (case $?)"
    pass "the copy of a directory follows the links leading out and copies no special file"
}

# A function of setup.sh, defined here as setup.sh defines it.
setup_function() {
    eval "$(sed -n "/^$1() {/,/^}/p" "$REPO_ROOT/docker/setup.sh")"
}

# copy_from_directory <site> <HEADLESS> <IMPORT_EXTERNAL_LINKS> <answer>
# What setup.sh does with a site directory, from its link check to the
# copy and the search after it, in the directory holding its .env
# (OUT_ENV_DIR); the output lands in $TMP_ROOT/out.txt, the find calls in
# $TMP_ROOT/out-find.log. OUT_BETWEEN, when set, runs between the check
# and the copy, as time passes on a large site.
copy_from_directory() {
    rm -rf "$TMP_ROOT/out-dest" "$TMP_ROOT/out-markers"
    : > "$TMP_ROOT/out-find.log"
    (
        cd "$OUT_ENV_DIR" || exit 99
        PATH="$OUT_FIND_BIN:${OUT_EXTRA_BIN:+$OUT_EXTRA_BIN:}$PATH"
        # shellcheck disable=SC2034  # Read by import_check_site_links, import_confirm_external_links and import_marker_file.
        IMPORT_SOURCE=directory IMPORT_SITE_DIR=$1 DOMAIN=links.example.test IMPORT_MARKER_DIR="$TMP_ROOT/out-markers"
        # shellcheck disable=SC2034
        HEADLESS=$2 IMPORT_EXTERNAL_LINKS=$3 IMPORT_EXPORTER="$REPO_ROOT/kvs-export.sh"
        # shellcheck disable=SC2034
        IMPORT_EXTERNAL_LINKS_ACCEPTED=$(sed -n 's/^IMPORT_EXTERNAL_LINKS_ACCEPTED=//p' .env)
        import_check_site_links
        echo "find calls before the copy: $(wc -l < "$TMP_ROOT/out-find.log")"
        [ -z "${OUT_BETWEEN:-}" ] || eval "$OUT_BETWEEN"
        import_place_site "$IMPORT_SITE_DIR" "$TMP_ROOT/out-dest" > /dev/null
        echo "find calls after the copy: $(wc -l < "$TMP_ROOT/out-find.log")"
        import_recheck_site_links "$TMP_ROOT/out-dest"
        [ -z "${IMPORT_LINKS_SHOWN:-}" ] || echo "the report shown was kept"
    ) > "$TMP_ROOT/out.txt" 2>&1 <<< "$4"
}

# The transfer follows the links leading out of the site and copies what
# they point to, read as root on the source, into files PHP owns here: a
# link planted in the old site to a root-only file handed that file to PHP.
# The setup lists them and asks before the copy, except for a contents
# directory on another disk: a headless run stops unless the same set was
# accepted before or IMPORT_EXTERNAL_LINKS=copy, an interactive one asks,
# a "no" copies nothing, from a directory as from the old server.
test_links_leading_out_are_confirmed_before_the_copy() {
    local site="$TMP_ROOT/out-site" outside="$TMP_ROOT/out-secret" disk="$TMP_ROOT/out-disk"
    local destination="$TMP_ROOT/out-dest" bin="$TMP_ROOT/ssh-bin-out" report="$TMP_ROOT/out-detect.txt"
    local plain="$TMP_ROOT/out-plain" sources="$TMP_ROOT/out-sources" alias="$TMP_ROOT/out-alias"
    local out status tool inspect gate load done_line block digest remember
    # shellcheck disable=SC2034  # The colours of the setup.sh functions run here.
    local RED="" YELLOW="" NC=""

    make_site "$site" "$site"
    mkdir -p "$outside" "$disk" "$TMP_ROOT/out-disk3/x"
    echo "root only" > "$outside/secret"
    chmod 600 "$outside/secret"
    ln -s "$outside/secret" "$site/contents/videos/innocent.txt"
    ln -s "$disk" "$site/contents/store"
    ln -s "$outside/secret" "$disk/nested.txt"
    echo "on the disk" > "$disk/file"
    ln -s file "$disk/inner"
    ln -s "$site/contents/videos/1.mp4" "$disk/back"
    ln -s ../out-secret/missing "$disk/gone"
    # Two links further out, as the copy follows them.
    ln -s "$TMP_ROOT/out-disk3/x" "$disk/a"
    ln -s "$outside/secret" "$TMP_ROOT/out-disk3/x/evil"

    setup_function import_check_site_links
    setup_function import_keep_links_report
    setup_function import_recheck_site_links
    setup_function set_env_value
    setup_function remove_env_value
    OUT_ENV_DIR="$TMP_ROOT/out-env"
    OUT_FIND_BIN="$TMP_ROOT/out-find-bin"
    mkdir -p "$OUT_ENV_DIR" "$OUT_FIND_BIN"
    : > "$OUT_ENV_DIR/.env"
    printf '#!/bin/bash\ncase " $* " in *" -type l "*) echo "find $*" >> %q ;; esac\nexec %q "$@"\n' \
        "$TMP_ROOT/out-find.log" "$(command -v find)" > "$OUT_FIND_BIN/find"
    chmod +x "$OUT_FIND_BIN/find"

    # From a directory.
    status=0
    copy_from_directory "$site" y "" "" || status=$?
    [ "$status" -eq 1 ] || fail "a headless copy must stop on links leading out (status $status): $(cat "$TMP_ROOT/out.txt")"
    [ ! -e "$destination/contents/videos/innocent.txt" ] || fail "nothing may be copied before the operator agrees"
    grep -Fq "file       contents/videos/innocent.txt -> $outside/secret" "$TMP_ROOT/out.txt" || fail "the refusal must list the links: $(cat "$TMP_ROOT/out.txt")"
    grep -Fq "file       contents/store/a/evil -> $outside/secret" "$TMP_ROOT/out.txt" || fail "the links two links away must be listed: $(cat "$TMP_ROOT/out.txt")"
    grep -Fq 'IMPORT_EXTERNAL_LINKS=copy' "$TMP_ROOT/out.txt" || fail "the refusal must name the way to agree: $(cat "$TMP_ROOT/out.txt")"
    grep -q 'did not enter every directory' "$TMP_ROOT/out.txt" && fail "the search must have finished: $(cat "$TMP_ROOT/out.txt")"
    status=0
    copy_from_directory "$site" "" "" n || status=$?
    [ "$status" -eq 0 ] || fail "a no must end the run without an error (status $status)"
    grep -q 'Import cancelled' "$TMP_ROOT/out.txt" || fail "a no must cancel: $(cat "$TMP_ROOT/out.txt")"
    [ ! -e "$destination/contents/videos/innocent.txt" ] || fail "a no must copy nothing"
    status=0
    copy_from_directory "$site" y yes "" || status=$?
    if [ "$status" -ne 1 ] || ! grep -q 'takes copy or nothing' "$TMP_ROOT/out.txt"; then
        fail "another value must be refused: $(cat "$TMP_ROOT/out.txt")"
    fi
    copy_from_directory "$site" "" "" y || fail "a yes must let the copy go on: $(cat "$TMP_ROOT/out.txt")"
    [ "$(cat "$destination/contents/videos/innocent.txt")" = "root only" ] || fail "a yes copies what the link points to"
    [ "$(cat "$destination/contents/store/a/evil")" = "root only" ] || fail "the agreed copy follows the links further out too"
    # The site was searched by the exporter before the copy, which looks no
    # more, and once again after it, to compare.
    out=$(sed -n 's/.*find calls before the copy: //p' "$TMP_ROOT/out.txt")
    if [ "${out:-0}" -eq 0 ] || ! grep -Fq "find calls after the copy: $out" "$TMP_ROOT/out.txt"; then
        fail "the copy must not search the site again: $(cat "$TMP_ROOT/out.txt") $(cat "$TMP_ROOT/out-find.log")"
    fi
    [ "$(grep -c . "$TMP_ROOT/out-find.log")" -eq $((out * 2)) ] ||
        fail "the same search must run once more after the copy: $(cat "$TMP_ROOT/out-find.log")"
    # What was agreed to is remembered, and a later run of the same set
    # goes on headless; a new link asks again.
    digest=$(sed -n 's/^IMPORT_EXTERNAL_LINKS_ACCEPTED=//p' "$OUT_ENV_DIR/.env")
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || fail "the accepted links must be remembered in .env: $(cat "$OUT_ENV_DIR/.env")"
    copy_from_directory "$site" y "" "" || fail "the same links as accepted before must go on headless: $(cat "$TMP_ROOT/out.txt")"
    grep -q 'The same links as an earlier pass accepted' "$TMP_ROOT/out.txt" || fail "the remembered set must be said: $(cat "$TMP_ROOT/out.txt")"
    ln -s "$outside" "$site/contents/videos/more"
    status=0
    copy_from_directory "$site" y "" "" || status=$?
    [ "$status" -eq 1 ] || fail "a new link must stop a headless copy again (status $status): $(cat "$TMP_ROOT/out.txt")"
    rm -f "$site/contents/videos/more"
    copy_from_directory "$site" y copy "" || fail "IMPORT_EXTERNAL_LINKS=copy must let a headless copy go on: $(cat "$TMP_ROOT/out.txt")"
    [ "$(sed -n 's/^IMPORT_EXTERNAL_LINKS_ACCEPTED=//p' "$OUT_ENV_DIR/.env")" = "$digest" ] || fail "the set agreed with copy is remembered too"

    # Named through a link to it, the site is searched where it is: the
    # link inside to a root-only file is listed; without one it goes on.
    ln -s "$site" "$alias"
    : > "$OUT_ENV_DIR/.env"
    status=0
    copy_from_directory "$alias" y "" "" || status=$?
    [ "$status" -eq 1 ] || fail "a site named through a link must stop on its links (status $status): $(cat "$TMP_ROOT/out.txt")"
    grep -Fq "file       contents/videos/innocent.txt -> $outside/secret" "$TMP_ROOT/out.txt" || fail "a site named through a link must list its links: $(cat "$TMP_ROOT/out.txt")"
    make_site "$plain" "$plain"
    rm -f "$alias"
    ln -s "$plain" "$alias"
    copy_from_directory "$alias" y "" "" || fail "a site named through a link, without links, must go on headless: $(cat "$TMP_ROOT/out.txt")"
    [ -f "$destination/contents/videos/1.mp4" ] || fail "the site named through a link must be copied"

    # contents/videos_sources on another disk, the usual layout, goes on
    # headless with nothing set.
    make_site "$sources" "$sources"
    mkdir -p "$TMP_ROOT/out-disk2/src"
    echo source > "$TMP_ROOT/out-disk2/src/s.mp4"
    ln -s "$TMP_ROOT/out-disk2/src" "$sources/contents/videos_sources"
    [ "$(id -u)" -ne 0 ] || chown -R 4242 "$sources" "$TMP_ROOT/out-disk2"
    copy_from_directory "$sources" y "" "" || fail "a contents directory on another disk must go on headless: $(cat "$TMP_ROOT/out.txt")"
    grep -Fq "a contents directory on another disk, copied with what they point to" "$TMP_ROOT/out.txt" || fail "the followed layout must be said: $(cat "$TMP_ROOT/out.txt")"
    [ "$(cat "$destination/contents/videos_sources/s.mp4")" = source ] || fail "the sources must be copied"
    remember=$(sed -n 's/^IMPORT_EXTERNAL_LINKS_ACCEPTED=//p' "$OUT_ENV_DIR/.env")
    [ -z "$remember" ] || fail "nothing is remembered for links that need no question"

    # A link to a FIFO stops it, whatever is set.
    mkfifo "$TMP_ROOT/out-fifo"
    ln -s "$TMP_ROOT/out-fifo" "$sources/contents/fifo"
    status=0
    copy_from_directory "$sources" y copy "" || status=$?
    [ "$status" -eq 1 ] || fail "a link to a FIFO must stop the copy (status $status): $(cat "$TMP_ROOT/out.txt")"
    grep -q 'a device, a FIFO or a socket' "$TMP_ROOT/out.txt" || fail "the refusal must say why: $(cat "$TMP_ROOT/out.txt")"
    [ ! -e "$destination" ] || fail "nothing may be copied with a link to a FIFO"
    rm -f "$sources/contents/fifo"
    # A search that could not run stops it, nothing listed.
    mkdir -p "$TMP_ROOT/out-nomktemp"
    printf '#!/bin/bash\ncase "$*" in *kvs-export-links.*) exit 1 ;; esac\nexec %q "$@"\n' "$(command -v mktemp)" > "$TMP_ROOT/out-nomktemp/mktemp"
    chmod +x "$TMP_ROOT/out-nomktemp/mktemp"
    status=0
    OUT_EXTRA_BIN="$TMP_ROOT/out-nomktemp" copy_from_directory "$sources" y copy "" || status=$?
    [ "$status" -eq 1 ] || fail "a link search that could not run must stop the copy (status $status): $(cat "$TMP_ROOT/out.txt")"
    grep -q 'could not run' "$TMP_ROOT/out.txt" || fail "the stop must say the search did not run: $(cat "$TMP_ROOT/out.txt")"
    [ ! -e "$destination" ] || fail "nothing may be copied without the search"
    # A link to nothing stops it too, with the list.
    ln -s /nowhere/at/all "$sources/contents/gone"
    status=0
    copy_from_directory "$sources" y copy "" || status=$?
    [ "$status" -eq 1 ] || fail "a link to nothing must stop the copy (status $status): $(cat "$TMP_ROOT/out.txt")"
    grep -Fq "contents/gone -> /nowhere/at/all (dangling)" "$TMP_ROOT/out.txt" || fail "the dangling link must be listed: $(cat "$TMP_ROOT/out.txt")"
    rm -f "$sources/contents/gone"

    # From the old server: the exporter's report, shown and then asked about.
    make_fake_ssh "$bin"
    for tool in mariadb mysql mariadb-dump mysqldump; do
        printf '#!/bin/sh\nexit 1\n' > "$bin/$tool"
        chmod +x "$bin/$tool"
    done
    (
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl-out" import_ssh_setup old.example.com 22 root "" yes
        FAKE_UID=0 import_remote_privileges || exit 1
        import_remote_detect "$REPO_ROOT/kvs-export.sh" "$site" "$report" 0 2> "$TMP_ROOT/out-detect.err" || exit 2
    ) || fail "the detection must run (case $?): $(cat "$TMP_ROOT/out-detect.err")"
    [ "$(import_kv "$report" external_links)" = 5 ] || fail "the report must count the links leading out: $(grep '^external' "$report")"
    setup_function import_remote_show_links
    out=$(IMPORT_REMOTE_PRIVILEGES=root import_remote_show_links "$report")
    printf '%s\n' "$out" | grep -Fq 'Links leading out of the site (5, 5 to check): the copy brings what they point to, read on the old server as root, into files PHP owns here:' ||
        fail "the summary must say what the transfer does with the links: $out"
    printf '%s\n' "$out" | grep -Fxq "    file       contents/videos/innocent.txt -> $outside/secret" || fail "the summary must list each link: $out"
    printf '%s\n' "$out" | grep -Fxq "    file       contents/store/nested.txt -> $outside/secret" || fail "the summary must list the links further out: $out"
    status=0
    (HEADLESS=y import_confirm_external_links "$report" "Way out.") > "$TMP_ROOT/out.txt" 2>&1 || status=$?
    if [ "$status" -ne 1 ] || ! grep -Fq 'Way out. Or set IMPORT_EXTERNAL_LINKS=copy' "$TMP_ROOT/out.txt"; then
        fail "a headless import from the old server must stop on them (status $status): $(cat "$TMP_ROOT/out.txt")"
    fi
    digest=$(import_kv "$report" external_links_digest)
    (HEADLESS=y IMPORT_EXTERNAL_LINKS_ACCEPTED=$digest import_confirm_external_links "$report" "Way out.") > /dev/null 2>&1 ||
        fail "the set accepted before must go on headless"
    # A count past the listed links, and a search that did not finish,
    # are said; an unfinished one is asked about with no link listed, and
    # is never taken for a set accepted before.
    printf 'external_links=25\nexternal_links_review=25\nexternal_links_complete=no\nexternal_links_digest=%s\nexternal_link_1=review|file|a -> /x\nexternal_link_2=review|directory|b -> /y\n' "$digest" > "$TMP_ROOT/out-many.txt"
    out=$(IMPORT_REMOTE_PRIVILEGES=sudo import_remote_show_links "$TMP_ROOT/out-many.txt")
    printf '%s\n' "$out" | grep -Fxq '    and 23 more' || fail "the links beyond the list must be counted: $out"
    printf '%s\n' "$out" | grep -Fq 'the copy may follow more than listed' || fail "an unfinished search must be said: $out"
    (HEADLESS=y IMPORT_EXTERNAL_LINKS_ACCEPTED=$digest import_confirm_external_links "$TMP_ROOT/out-many.txt" "") > /dev/null 2>&1 &&
        fail "an unfinished search is never the set accepted before"
    printf 'external_links=0\nexternal_links_review=0\nexternal_links_complete=no\n' > "$TMP_ROOT/out-unknown.txt"
    out=$(import_remote_show_links "$TMP_ROOT/out-unknown.txt")
    printf '%s\n' "$out" | grep -Fq 'could not run' || fail "a search that could not run must be said: $out"
    printf '%s\n' "$out" | grep -q 'contents directory on another disk' && fail "a search that could not run is no layout: $out"
    (HEADLESS=y import_confirm_external_links "$TMP_ROOT/out-unknown.txt" "") > /dev/null 2>&1 && fail "an unfinished search must be asked about"
    (HEADLESS=y import_confirm_external_links /dev/null "") > /dev/null 2>&1 || fail "no link, nothing to ask"
    printf 'external_links=1\nexternal_links_review=1\nexternal_links_special=1\nexternal_links_complete=yes\nexternal_link_1=refused|special|c -> /dev/sda\n' > "$TMP_ROOT/out-special.txt"
    (HEADLESS=y IMPORT_EXTERNAL_LINKS=copy import_confirm_external_links "$TMP_ROOT/out-special.txt" "") > /dev/null 2>&1 &&
        fail "a link to a device must stop the import whatever is set"
    printf 'external_links=1\nexternal_links_review=0\nexternal_links_complete=yes\nexternal_link_1=allowed|directory|contents/videos_sources -> /mnt/disk2\n' > "$TMP_ROOT/out-allowed.txt"
    (HEADLESS=y import_confirm_external_links "$TMP_ROOT/out-allowed.txt" "") > /dev/null 2>&1 ||
        fail "a contents directory on another disk needs no question"
    printf 'kvs_export=1\n' > "$TMP_ROOT/out-none.txt"
    [ -z "$(import_remote_show_links "$TMP_ROOT/out-none.txt")" ] || fail "a report without links shows none"

    # The setup asks after the summary and its paths to leave behind, and
    # before anything is written or transferred.
    inspect=$(sed -n '/^import_inspect_remote() {/,/^}/p' "$REPO_ROOT/docker/setup.sh")
    printf '%s\n' "$inspect" | grep -Fxq '    import_remote_show_links "$IMPORT_REMOTE_REPORT"' || fail "the remote summary must show the links"
    printf '%s\n' "$inspect" | sed -n '1,/^    import_ssh_setup "$IMPORT_REMOTE_HOST"/p' | grep -Fxq '    import_confirm_external_links /dev/null "" || exit 1' ||
        fail "a wrong IMPORT_EXTERNAL_LINKS must stop the run before the old server is contacted"
    gate=$(printf '%s\n' "$inspect" | grep -n '^    import_confirm_external_links "$IMPORT_REMOTE_REPORT" \\$' | cut -d: -f1) || gate=""
    load=$(printf '%s\n' "$inspect" | grep -n '^    import_remote_load_excludes "$IMPORT_REMOTE_REPORT"$' | cut -d: -f1) || load=""
    remember=$(printf '%s\n' "$inspect" | grep -n '^        import_remember_external_links || {$' | cut -d: -f1) || remember=""
    [ -n "$gate" ] && [ -n "$load" ] && [ "$gate" -lt "$load" ] || fail "the question must come before the transfer is prepared"
    [ -n "$remember" ] && [ "$gate" -lt "$remember" ] || fail "the agreed links must be remembered in .env after the question"
    done_line=$(printf '%s\n' "$inspect" | sed -n "1,${gate}p" | grep -n '^    done$' | tail -n 1 | cut -d: -f1) || done_line=""
    [ -n "$done_line" ] && [ $((gate - done_line)) -le 2 ] || fail "the question must come once the operator has chosen what to leave behind"
    # That question, as setup.sh asks it, on the report of the old server.
    block=$(printf '%s\n' "$inspect" | sed -n "${gate},/^    }\$/p")
    run_gate() {
        (
            # shellcheck disable=SC2034  # Read by the evaluated block.
            IMPORT_REMOTE_REPORT=$report HEADLESS=$1
            eval "$block"
            echo "went on"
        ) <<< "$2" > "$TMP_ROOT/out.txt" 2>&1
    }
    status=0
    run_gate y "" || status=$?
    if [ "$status" -ne 1 ] || ! grep -Fq 'Leave them behind with IMPORT_EXCLUDE' "$TMP_ROOT/out.txt"; then
        fail "a headless import from the old server must stop before the transfer (status $status): $(cat "$TMP_ROOT/out.txt")"
    fi
    status=0
    run_gate "" n || status=$?
    if [ "$status" -ne 0 ] || ! grep -q 'Import cancelled' "$TMP_ROOT/out.txt" || grep -q 'went on' "$TMP_ROOT/out.txt"; then
        fail "a no must end the import from the old server (status $status): $(cat "$TMP_ROOT/out.txt")"
    fi
    run_gate "" y || fail "a yes must let the import from the old server go on: $(cat "$TMP_ROOT/out.txt")"
    grep -q 'went on' "$TMP_ROOT/out.txt" || fail "a yes must let the import from the old server go on: $(cat "$TMP_ROOT/out.txt")"
    pass "links leading out of the site are listed and confirmed before the copy"
}

# The tar stream is a pipeline, and setup.sh runs without pipefail: the
# status of the remote tar must be read from the pipeline itself, or the
# files it could not read are silently left behind.
# import_compare_external_links on reports written by hand: each link the
# search finds after the copy leads to something the list shown led to, of
# the same kind, or it is named and what it brought, its own path in the
# destination, is removed when that path names a place under the
# destination beyond doubt; otherwise the operator is told to remove it.
test_the_links_found_after_the_copy_are_compared_with_the_list_shown() {
    local dir="$TMP_ROOT/cmp" dest="$TMP_ROOT/cmp/dest" outside="$TMP_ROOT/cmp-outside" status
    # shellcheck disable=SC2034  # The colours of the messages.
    local RED="" NC=""

    mkdir -p "$dest/contents/videos/d" "$dest/a|b%c" "$outside/videos"
    entries() {
        local complete="$1" i=1 entry
        shift
        printf 'kvs_export=1\nsite_dir=%s\nexternal_links_complete=%s\n' "${CMP_SITE:-/srv/site}" "$complete"
        for entry in "$@"; do
            printf 'external_entry_%s=%s\n' "$i" "$entry"
            i=$((i + 1))
        done
    }
    entries yes 'allowed|directory|contents|/disk/contents' 'review|file|contents/videos/a.txt|/srv/shared/a' > "$dir/shown"
    # The same targets, one through another path, one gone: nothing to say.
    entries yes 'review|directory|contents|/disk/contents' 'review|file|contents/videos/b.txt|/srv/shared/a' > "$dir/after"
    import_compare_external_links "$dir/shown" "$dir/after" "$dest" old.example.test > "$dir/out" 2>&1 ||
        fail "the same targets must let the import go on: $(cat "$dir/out")"
    [ ! -s "$dir/out" ] || fail "the same targets need no word: $(cat "$dir/out")"

    # A new target, a target of another kind, a path written with escapes:
    # named, and what they brought removed, nothing else.
    echo new > "$dest/contents/videos/new.txt"
    echo x > "$dest/contents/videos/d/f"
    echo y > "$dest/a|b%c/z"
    echo kept > "$dest/contents/videos/1.mp4"
    entries yes 'allowed|directory|contents|/disk/contents' 'review|file|contents/videos/new.txt|/srv/private/s' \
        'review|directory|contents/videos/d|/srv/shared/a' 'review|file|a%7Cb%25c/z|/srv/private/z' \
        'review|file|contents/videos/never-copied.txt|/srv/private/n' > "$dir/after"
    status=0
    import_compare_external_links "$dir/shown" "$dir/after" "$dest" old.example.test > "$dir/out" 2>&1 || status=$?
    [ "$status" -eq 1 ] || fail "new links must stop the import (status $status): $(cat "$dir/out")"
    grep -Fq 'links leading out of the site on old.example.test changed after they were listed' "$dir/out" || fail "the change must be said: $(cat "$dir/out")"
    grep -Fxq '    file       contents/videos/new.txt -> /srv/private/s' "$dir/out" || fail "a new link must be named: $(cat "$dir/out")"
    grep -Fxq '    directory  contents/videos/d -> /srv/shared/a' "$dir/out" || fail "a target of another kind must be named: $(cat "$dir/out")"
    grep -Fxq '    file       contents/videos/never-copied.txt -> /srv/private/n' "$dir/out" || fail "a link the copy missed is named too: $(cat "$dir/out")"
    [ ! -e "$dest/contents/videos/new.txt" ] && [ ! -e "$dest/contents/videos/d" ] && [ ! -e "$dest/a|b%c/z" ] ||
        fail "what the new links brought must leave the destination: $(find "$dest")"
    [ -f "$dest/contents/videos/1.mp4" ] && [ -d "$dest/a|b%c" ] || fail "nothing else may leave the destination: $(find "$dest")"
    grep -Fxq "    $dest/contents/videos/new.txt" "$dir/out" || fail "what was removed must be said: $(cat "$dir/out")"
    grep -Fxq "    $dest/a|b%c/z" "$dir/out" || fail "what was removed must be said: $(cat "$dir/out")"
    grep -q 'Remove yourself' "$dir/out" && fail "nothing is left to the operator: $(cat "$dir/out")"

    # A path that cannot be named beyond doubt is left to the operator: a
    # byte written %XX, a "..", a directory on the way leading out of the
    # destination.
    echo q > "$dest/odd"$'\n'"name"
    echo outside > "$outside/videos/v.txt"
    ln -s "$outside" "$dest/away"
    entries yes 'review|file|odd%0Aname|/srv/private/o' 'review|file|../x|/srv/private/x' \
        'review|file|away/videos/v.txt|/srv/private/v' > "$dir/after"
    status=0
    import_compare_external_links "$dir/shown" "$dir/after" "$dest" old.example.test > "$dir/out" 2>&1 || status=$?
    [ "$status" -eq 1 ] || fail "links the import cannot clear must stop it (status $status): $(cat "$dir/out")"
    [ -e "$dest/odd"$'\n'"name" ] && [ -f "$outside/videos/v.txt" ] || fail "nothing outside what can be named beyond doubt may be removed"
    sed -n '/Remove yourself/,$p' "$dir/out" | grep -Fxq '    odd%0Aname' || fail "the escaped path is left to the operator: $(cat "$dir/out")"
    sed -n '/Remove yourself/,$p' "$dir/out" | grep -Fxq '    ../x' || fail "the climbing path is left to the operator: $(cat "$dir/out")"
    sed -n '/Remove yourself/,$p' "$dir/out" | grep -Fxq '    away/videos/v.txt' || fail "the path leading out is left to the operator: $(cat "$dir/out")"

    # A search that could not run, ran on another directory, or no longer
    # finished: what the copy followed is not known.
    printf 'site_dir=/srv/site\n' > "$dir/after"
    status=0
    import_compare_external_links "$dir/shown" "$dir/after" "$dest" old.example.test > "$dir/out" 2>&1 || status=$?
    [ "$status" -eq 1 ] || fail "a search that did not run must stop the import (status $status): $(cat "$dir/out")"
    grep -q 'could not be listed again' "$dir/out" || fail "the reason must be said: $(cat "$dir/out")"
    CMP_SITE=/srv/other entries yes 'allowed|directory|contents|/disk/contents' > "$dir/after"
    status=0
    import_compare_external_links "$dir/shown" "$dir/after" "$dest" old.example.test > "$dir/out" 2>&1 || status=$?
    [ "$status" -eq 1 ] || fail "a search of another directory must stop the import (status $status): $(cat "$dir/out")"
    grep -q 'now resolves to /srv/other' "$dir/out" || fail "the reason must be said: $(cat "$dir/out")"
    entries no 'allowed|directory|contents|/disk/contents' > "$dir/after"
    status=0
    import_compare_external_links "$dir/shown" "$dir/after" "$dest" old.example.test > "$dir/out" 2>&1 || status=$?
    [ "$status" -eq 1 ] || fail "a search that no longer finished must stop the import (status $status): $(cat "$dir/out")"
    grep -q 'did not finish after the copy' "$dir/out" || fail "the reason must be said: $(cat "$dir/out")"
    # An unfinished search was agreed to as such: the same one goes on.
    entries no 'review|directory|contents/etc|/etc' > "$dir/shown"
    entries no 'review|directory|contents/etc|/etc' > "$dir/after"
    import_compare_external_links "$dir/shown" "$dir/after" "$dest" old.example.test > "$dir/out" 2>&1 ||
        fail "the same unfinished search as agreed to must go on: $(cat "$dir/out")"
    pass "the links found after the copy are compared with the list shown"
}

# The copy of a site directory follows the links it meets when it meets
# them, long after the operator saw the list on a large site. The same
# search after the copy finds a link planted or changed in between: the
# import stops there, before the init hands the files to PHP, names it, and
# what it brought leaves the copy; a name the list cannot show as it is is
# left to the operator. A link one level below a contents directory on
# another disk, to a directory whose name ends with a line break, stops a
# headless copy before it starts. A site without any link leading out
# forgets the set an earlier run agreed to, as the source over SSH does.
test_links_are_searched_again_after_the_copy_of_a_directory() {
    local site="$TMP_ROOT/again-site" disk="$TMP_ROOT/again-disk" other="$TMP_ROOT/again-other" secret="$TMP_ROOT/again-secret/s"
    local destination="$TMP_ROOT/out-dest" nl_site="$TMP_ROOT/again-nl-site" plain="$TMP_ROOT/again-plain" status accepted
    # shellcheck disable=SC2034  # The colours of the setup.sh functions run here.
    local RED="" YELLOW="" NC="" GREEN=""

    setup_function import_check_site_links
    setup_function import_keep_links_report
    setup_function import_recheck_site_links
    setup_function set_env_value
    setup_function remove_env_value
    OUT_ENV_DIR="$TMP_ROOT/again-env"
    OUT_FIND_BIN="$TMP_ROOT/again-find-bin"
    mkdir -p "$OUT_ENV_DIR" "$OUT_FIND_BIN" "$disk/sources" "$other" "$(dirname "$secret")"
    : > "$OUT_ENV_DIR/.env"
    echo "root only" > "$secret"
    chmod 600 "$secret"
    make_site "$site" "$site"
    echo source > "$disk/sources/s.mp4"
    echo other > "$other/o.mp4"
    ln -s "$disk/sources" "$site/contents/videos_sources"
    [ "$(id -u)" -ne 0 ] || chown -R 4242 "$site" "$disk" "$other"

    # Nothing changed: the copy goes on and the report is not kept.
    copy_from_directory "$site" y "" "" || fail "an unchanged site must be copied: $(cat "$TMP_ROOT/out.txt")"
    [ "$(cat "$destination/contents/videos_sources/s.mp4")" = source ] || fail "the sources must be copied"
    grep -q 'the report shown was kept' "$TMP_ROOT/out.txt" && fail "the report must go once the copy is checked"

    # A link planted between the list and the copy.
    status=0
    OUT_BETWEEN="ln -s '$secret' '$site/contents/videos/planted.txt'" copy_from_directory "$site" y "" "" || status=$?
    [ "$status" -eq 1 ] || fail "a link planted before the copy must stop the import (status $status): $(cat "$TMP_ROOT/out.txt")"
    grep -Fxq "    file       contents/videos/planted.txt -> $secret" "$TMP_ROOT/out.txt" || fail "the planted link must be named: $(cat "$TMP_ROOT/out.txt")"
    [ ! -e "$destination/contents/videos/planted.txt" ] || fail "what the planted link brought must leave the copy"
    [ -f "$destination/contents/videos/1.mp4" ] && [ -f "$destination/contents/videos_sources/s.mp4" ] || fail "the rest of the copy stays"
    rm -f "$site/contents/videos/planted.txt"

    # A link the operator saw, pointed elsewhere in between.
    status=0
    OUT_BETWEEN="ln -sfn '$other' '$site/contents/videos_sources'" copy_from_directory "$site" y "" "" || status=$?
    [ "$status" -eq 1 ] || fail "a changed link must stop the import (status $status): $(cat "$TMP_ROOT/out.txt")"
    grep -Fxq "    directory  contents/videos_sources -> $other" "$TMP_ROOT/out.txt" || fail "the changed link must be named: $(cat "$TMP_ROOT/out.txt")"
    [ ! -e "$destination/contents/videos_sources" ] || fail "what the changed link brought must leave the copy"
    ln -sfn "$disk/sources" "$site/contents/videos_sources"

    # A name the list writes %0A: left to the operator, with the stop.
    plant_odd_name() { ln -s "$secret" "$site/contents/odd"$'\n'"name"; }
    status=0
    OUT_BETWEEN=plant_odd_name copy_from_directory "$site" y "" "" || status=$?
    [ "$status" -eq 1 ] || fail "a link with an odd name must stop the import (status $status): $(cat "$TMP_ROOT/out.txt")"
    sed -n '/Remove yourself/,$p' "$TMP_ROOT/out.txt" | grep -Fxq '    contents/odd%0Aname' || fail "the odd name is left to the operator: $(cat "$TMP_ROOT/out.txt")"
    rm -f "$site/contents/odd"$'\n'"name"

    # One level below a contents directory on another disk, a link to a
    # directory whose name ends with a line break.
    make_site "$nl_site" "$nl_site"
    rm -rf "$nl_site/contents"
    mkdir -p "$TMP_ROOT/again-nl-disk/contents/videos" "$TMP_ROOT/again-nl-dir"$'\n'
    echo data > "$TMP_ROOT/again-nl-dir"$'\n'"/data.txt"
    ln -s "$TMP_ROOT/again-nl-disk/contents" "$nl_site/contents"
    ln -s "$TMP_ROOT/again-nl-dir"$'\n' "$TMP_ROOT/again-nl-disk/contents/videos/x"
    [ "$(id -u)" -ne 0 ] || chown -R 4242 "$nl_site" "$TMP_ROOT/again-nl-disk"
    status=0
    copy_from_directory "$nl_site" y "" "" || status=$?
    [ "$status" -eq 1 ] || fail "a link to such a name must stop a headless copy (status $status): $(cat "$TMP_ROOT/out.txt")"
    grep -Fq "directory  contents/videos/x -> $TMP_ROOT/again-nl-dir?" "$TMP_ROOT/out.txt" || fail "the link must be listed: $(cat "$TMP_ROOT/out.txt")"
    [ ! -e "$destination" ] || fail "nothing may be copied before the operator agrees"

    # Nothing leading out: the set an earlier run agreed to is forgotten.
    accepted=$(printf 'a%.0s' {1..64})
    make_site "$plain" "$plain"
    printf 'IMPORT_EXTERNAL_LINKS_ACCEPTED=%s\n' "$accepted" > "$OUT_ENV_DIR/.env"
    copy_from_directory "$plain" y "" "" || fail "a site without links must be copied: $(cat "$TMP_ROOT/out.txt")"
    grep -q '^IMPORT_EXTERNAL_LINKS_ACCEPTED=' "$OUT_ENV_DIR/.env" && fail "a set with nothing to ask about must be forgotten: $(cat "$OUT_ENV_DIR/.env")"
    # A site with no link at all when listed is searched again too.
    status=0
    OUT_BETWEEN="ln -s '$secret' '$plain/contents/videos/planted.txt'" copy_from_directory "$plain" y "" "" || status=$?
    [ "$status" -eq 1 ] || fail "a link planted in a site listed without links must stop the import (status $status): $(cat "$TMP_ROOT/out.txt")"
    [ ! -e "$destination/contents/videos/planted.txt" ] || fail "what it brought must leave the copy"
    rm -f "$plain/contents/videos/planted.txt"
    # The check of what came from the old server keeps it: that set is the
    # transfer's, and the copy holds no link leading out by then.
    printf 'IMPORT_EXTERNAL_LINKS_ACCEPTED=%s\n' "$accepted" > "$OUT_ENV_DIR/.env"
    (
        cd "$OUT_ENV_DIR" || exit 99
        # shellcheck disable=SC2034  # Read by import_check_site_links.
        IMPORT_SOURCE=remote IMPORT_SITE_DIR=$plain DOMAIN=links.example.test IMPORT_EXPORTER="$REPO_ROOT/kvs-export.sh" IMPORT_EXTERNAL_LINKS_ACCEPTED=$accepted
        import_check_site_links
    ) > "$TMP_ROOT/out.txt" 2>&1 || fail "the check of a transferred site must pass: $(cat "$TMP_ROOT/out.txt")"
    grep -Fxq "IMPORT_EXTERNAL_LINKS_ACCEPTED=$accepted" "$OUT_ENV_DIR/.env" || fail "the transfer's set must stay: $(cat "$OUT_ENV_DIR/.env")"
    pass "links are searched again after the copy of a directory"
}

# Over SSH the same: the exporter searches the old server again after the
# transfer, with the exclusions the transfer applied, a hidden name holding
# a space and a quote among them, which travel to it quoted on bash's
# standard input. A link planted after the detection is named and what it
# brought leaves the copy; one inside a part left behind brought nothing.
test_links_are_searched_again_after_the_transfer() {
    local bin="$TMP_ROOT/again-ssh-bin" site="$TMP_ROOT/again-remote-site" destination="$TMP_ROOT/again-remote-dest"
    local report="$TMP_ROOT/again-detect.txt" secret="$TMP_ROOT/again-remote-secret" odd tool status

    make_fake_ssh "$bin"
    for tool in mariadb mysql mariadb-dump mysqldump; do
        printf '#!/bin/sh\nexit 1\n' > "$bin/$tool"
        chmod +x "$bin/$tool"
    done
    make_site "$site" "$site"
    echo "root only" > "$secret"
    chmod 600 "$secret"
    odd=".odd 'name"
    mkdir -p "$site/$odd" "$site/backup"
    setup_function import_remote_load_excludes
    (
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/again-ctl" import_ssh_setup old.example.com 22 root "" yes
        FAKE_UID=0 import_remote_privileges || exit 30
        # shellcheck disable=SC2034  # Read by import_remote_recheck_links.
        IMPORT_EXPORTER="$REPO_ROOT/kvs-export.sh" IMPORT_REMOTE_DIR=$site
        import_remote_detect "$IMPORT_EXPORTER" "$site" "$report" 0 backup 2> "$TMP_ROOT/again-detect.err" || exit 1
        grep -Fxq "exclude_1=/$odd" "$report" && grep -Fxq 'exclude_2=/backup' "$report" || exit 2
        import_remote_load_excludes "$report"
        import_remote_files "$site" "$destination" yes "${IMPORT_EXCLUDE_PATTERNS[@]}" > "$TMP_ROOT/again-transfer.out" 2>&1 || exit 3
        import_remote_recheck_links "$report" "$destination" > "$TMP_ROOT/again.out" 2>&1 || exit 4
        grep -q '^command bash -s$' "$bin/ssh.log" || exit 5

        # Planted after the detection, and inside the parts left behind.
        ln -s "$secret" "$site/contents/videos/planted.txt"
        ln -s "$secret" "$site/backup/leak.txt"
        ln -s "$secret" "$site/$odd/leak.txt"
        import_remote_files "$site" "$destination" yes "${IMPORT_EXCLUDE_PATTERNS[@]}" > "$TMP_ROOT/again-transfer.out" 2>&1 || exit 6
        [ "$(cat "$destination/contents/videos/planted.txt")" = "root only" ] || exit 7
        status=0
        import_remote_recheck_links "$report" "$destination" > "$TMP_ROOT/again.out" 2>&1 || status=$?
        [ "$status" -eq 1 ] || exit 8
        grep -Fxq "    file       contents/videos/planted.txt -> $secret" "$TMP_ROOT/again.out" || exit 9
        grep -q 'leak.txt' "$TMP_ROOT/again.out" && exit 10
        [ ! -e "$destination/contents/videos/planted.txt" ] || exit 11
        [ -f "$destination/contents/videos/1.mp4" ] || exit 12
        # A search that cannot run is no pass.
        status=0
        FAKE_SSH_FAIL_COMMAND='bash -s' import_remote_recheck_links "$report" "$destination" > "$TMP_ROOT/again.out" 2>&1 || status=$?
        [ "$status" -eq 1 ] && grep -q 'could not be listed again after the transfer' "$TMP_ROOT/again.out" || exit 13
        status=0
        FAKE_SSH_FAIL_COMMAND='bash -s' import_remote_recheck_links "$report" "$destination" best-effort > "$TMP_ROOT/again.out" 2>&1 || status=$?
        [ "$status" -eq 1 ] && [ ! -s "$TMP_ROOT/again.out" ] || exit 14
        import_ssh_close
        exit 0
    ) || fail "the links must be searched again after the transfer (case $?): $(cat "$TMP_ROOT/again.out" "$TMP_ROOT/again-detect.err" 2>/dev/null)"
    pass "links are searched again after the transfer, with its exclusions"
}

# Where rsync is missing, the copy of a site directory uses cp -a, which
# copies a FIFO, a device or a socket as one: it installs rsync first when
# the site holds one, and does not copy without it.
test_the_copy_without_rsync_installs_it_for_a_special_file() {
    local site="$TMP_ROOT/norsync-site" fifo_site="$TMP_ROOT/norsync-fifo-site" bin="$TMP_ROOT/norsync-bin" tool

    make_site "$site" "$site"
    make_site "$fifo_site" "$fifo_site"
    mkfifo "$fifo_site/contents/pipe"
    mkdir -p "$bin"
    for tool in readlink find cp rm mkdir cat dirname basename grep; do
        ln -s "$(command -v "$tool")" "$bin/$tool"
    done
    (
        PATH=$bin
        # shellcheck disable=SC2329  # Called by import_place_site.
        import_ensure_tool() { echo "ensure $1" >> "$TMP_ROOT/norsync.log"; return 1; }
        # shellcheck disable=SC2034  # Read by import_marker_file and import_place_site.
        IMPORT_MARKER_DIR="$TMP_ROOT/norsync-markers" IMPORT_SITE_LINKS=no
        : > "$TMP_ROOT/norsync.log"
        import_place_site "$site" "$TMP_ROOT/norsync-dest" > /dev/null || exit 1
        [ -f "$TMP_ROOT/norsync-dest/contents/videos/1.mp4" ] || exit 2
        [ ! -s "$TMP_ROOT/norsync.log" ] || exit 3
        import_place_site "$fifo_site" "$TMP_ROOT/norsync-fifo-dest" > /dev/null 2>&1 && exit 4
        grep -Fxq 'ensure rsync' "$TMP_ROOT/norsync.log" || exit 5
        [ ! -e "$TMP_ROOT/norsync-fifo-dest/contents/pipe" ] || exit 6
        exit 0
    ) || fail "a copy without rsync must not bring a FIFO (case $?): $(cat "$TMP_ROOT/norsync.log")"

    # The site directory is copied from where it resolves, kept whole: a
    # name ending with a line break is not the one without it.
    make_site "$TMP_ROOT/whole-site"$'\n' "$TMP_ROOT/whole-site"
    make_site "$TMP_ROOT/whole-site" "$TMP_ROOT/whole-site"
    echo real > "$TMP_ROOT/whole-site"$'\n'"/real.txt"
    echo decoy > "$TMP_ROOT/whole-site/decoy.txt"
    ln -s "$TMP_ROOT/whole-site"$'\n' "$TMP_ROOT/whole-link"
    (
        # shellcheck disable=SC2034  # Read by import_marker_file and import_place_site.
        IMPORT_MARKER_DIR="$TMP_ROOT/whole-markers" IMPORT_SITE_LINKS=no
        import_place_site "$TMP_ROOT/whole-link" "$TMP_ROOT/whole-dest" > /dev/null || exit 1
        [ -f "$TMP_ROOT/whole-dest/real.txt" ] || exit 2
        [ ! -e "$TMP_ROOT/whole-dest/decoy.txt" ] || exit 3
        exit 0
    ) || fail "the copy must read the directory the site resolves to (case $?)"
    pass "the copy without rsync installs it for a special file, and reads the site where it resolves"
}

# import_fetch_source copies a site directory, then searches its links
# again before anything else, also when the copy failed.
test_the_copy_of_a_directory_is_followed_by_the_search_again() {
    setup_function import_fetch_source
    (
        # shellcheck disable=SC2034  # Read by import_fetch_source.
        IMPORT_MODE=true IMPORT_SOURCE=directory IMPORT_SITE_DIR=/srv/site DOMAIN=links.example.test RED="" NC=""
        # shellcheck disable=SC2329  # Called by import_fetch_source.
        import_place_site() { echo "copy $1 $2"; return "${FIXTURE_COPY_STATUS:-0}"; }
        # shellcheck disable=SC2329  # Called by import_fetch_source.
        import_recheck_site_links() { echo "search again $1"; }
        import_fetch_source > "$TMP_ROOT/fetch-dir.out" 2>&1 || exit 1
        [ "$(grep -v '^  Placing' "$TMP_ROOT/fetch-dir.out" | paste -sd'|')" = "copy /srv/site /var/www/links.example.test|search again /var/www/links.example.test" ] || exit 2
        FIXTURE_COPY_STATUS=1
        (import_fetch_source) > "$TMP_ROOT/fetch-dir.out" 2>&1 && exit 3
        grep -Fxq 'search again /var/www/links.example.test' "$TMP_ROOT/fetch-dir.out" || exit 4
        exit 0
    ) || fail "the copy of a directory must be followed by the search again (case $?): $(cat "$TMP_ROOT/fetch-dir.out")"
    pass "the copy of a directory is followed by the search again"
}

test_the_tar_stream_reports_what_the_old_server_could_not_read() {
    local bin="$TMP_ROOT/ssh-bin-tar" site destination real_tar

    make_fake_ssh "$bin"
    real_tar=$(command -v tar)
    # The remote tar is the real one ending with the status FAKE_TAR_STATUS
    # asks for, as tar does after "Cannot open: Permission denied" (2) or
    # "file changed as we read it" (1); the local tar runs untouched.
    cat > "$bin/tar" <<EOF
#!/bin/bash
case " \$* " in
    *" -chf "*) "$real_tar" "\$@"; exit "\${FAKE_TAR_STATUS:-0}" ;;
    *) exec "$real_tar" "\$@" ;;
esac
EOF
    chmod +x "$bin/tar"
    site="$TMP_ROOT/remote-site-tar"
    make_site "$site" "$site"
    destination="$TMP_ROOT/remote-dest-tar"
    (
        set +o pipefail
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ctl4" import_ssh_setup old.example.com 22 root "" yes
        FAKE_UID=0 import_remote_privileges || exit 1
        export FAKE_TAR_STATUS=2
        import_remote_files "$site" "$destination" no > "$TMP_ROOT/tar-out.txt" 2>&1 && exit 2
        grep -q '^ERROR: .*old.example.com' "$TMP_ROOT/tar-out.txt" || exit 3
        rm -rf "$destination"
        export FAKE_TAR_STATUS=1
        import_remote_files "$site" "$destination" no > "$TMP_ROOT/tar-out.txt" 2>&1 || exit 4
        grep -q 'vanished' "$TMP_ROOT/tar-out.txt" || exit 5
        [ -f "$destination/contents/videos/1.mp4" ] || exit 6
        rm -rf "$destination"
        export FAKE_TAR_STATUS=0
        import_remote_files "$site" "$destination" no > "$TMP_ROOT/tar-out.txt" 2>&1 || exit 7
        [ ! -s "$TMP_ROOT/tar-out.txt" ] || exit 8
        [ -f "$destination/admin/include/setup.php" ] || exit 9
        import_ssh_close
        exit 0
    ) || fail "the tar stream must fail on what the old server could not read and tolerate a live site (case $?)"
    pass "the tar stream reports what the old server could not read"
}

test_parallel_transfers_preserve_the_mirror() {
    local bin="$TMP_ROOT/parallel-bin" site="$TMP_ROOT/parallel-site" destination="$TMP_ROOT/parallel-dest"
    local reference="$TMP_ROOT/parallel-reference" name i
    make_fake_ssh "$bin"
    make_site "$site" "$site"
    mkdir -p "$site/contents/screens/one" "$site/contents/screens/two" "$site/tmp" "$site/backup" "$TMP_ROOT/parallel-store"
    for ((i = 0; i < 40; i++)); do
        printf 'screen %s\n' "$i" > "$site/contents/screens/one/$i.jpg"
    done
    for name in 'a b' $'a\nb' $'a\tb' 'a\#012b' 'a\b' 'a"b' 'a*b' $'\303\251.jpg'; do
        printf '%s' "$name" > "$site/contents/screens/two/$name"
    done
    echo external > "$TMP_ROOT/parallel-store/video.mp4"
    ln -s "$TMP_ROOT/parallel-store" "$site/contents/store"
    ln -s screens/one "$site/contents/inside"
    echo excluded > "$site/tmp/upload.part"
    echo excluded > "$site/backup/old.sql"
    echo literal > "$site/#leading-hash"
    echo literal > "$site/;leading-semicolon"
    mkdir -p "$destination"
    echo stale > "$destination/stale.txt"
    # A wrapper around real rsync requires the first four chunks to have
    # started before allowing any to finish. Serial execution cannot pass it.
    cat > "$bin/rsync" <<'EOF'
#!/bin/bash
worker=""; dry=no; server=no
for arg in "$@"; do
    case "$arg" in
        --files-from=*) worker=${arg#*=}; worker=${worker##*/}; worker=${worker%.list} ;;
        --dry-run) dry=yes ;;
        --server) server=yes ;;
    esac
done
if [ "$dry" = yes ] && [ "${PARALLEL_SHORT_PLAN:-}" = yes ]; then
    printf 'KVS-PLAN >f+++++++++ 1 contents/screens/one/0.jpg\n'
    echo 'fixture: interrupted or failed planning' >&2
    exit "${PARALLEL_PLAN_STATUS:-124}"
fi
if [ "$dry" = yes ]; then sleep "${PARALLEL_PLAN_DELAY:-0}"; fi
if [ -n "$worker" ]; then
    printf '%s\n' "$*" > "$PARALLEL_BIN/worker-$worker"
    touch "$PARALLEL_BIN/started-$worker"
    export PARALLEL_WORKER="$worker"
    if [ "${PARALLEL_FAIL:-}" = "$worker" ]; then exit 23; fi
    if [ "${PARALLEL_VANISH:-}" = "$worker" ]; then
        printf 'KVS_IMPORT_SSH_READY\n' >&2
        exit 24
    fi
fi
if [ "$server" = yes ] && [ -n "${PARALLEL_WORKER:-}" ]; then
    for ((attempt = 0; attempt < 100; attempt++)); do
        [ -f "$PARALLEL_BIN/started-1" ] && [ -f "$PARALLEL_BIN/started-2" ] &&
            [ -f "$PARALLEL_BIN/started-3" ] && [ -f "$PARALLEL_BIN/started-4" ] && break
        sleep 0.05
    done
    [ "$attempt" -lt 100 ] || exit 90
fi
if [ "$server" = no ] && [ "$dry" = no ] && [ -z "$worker" ]; then
    exec "$REAL_RSYNC" "$@" --out-format='FINAL %i %n'
fi
exec "$REAL_RSYNC" "$@"
EOF
    chmod +x "$bin/rsync"
    (
        export REAL_RSYNC
        REAL_RSYNC=$(command -v rsync)
        export PARALLEL_BIN="$bin"
        # Five files a chunk: the workers take several chunks each.
        export IMPORT_TRANSFER_CHUNK=5
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/parallel-ctl" import_ssh_setup old.example.com 2222 root "" yes
        IMPORT_REMOTE_SUDO=no
        # Exceed the optional size-count budget. Every regular file must
        # still reach a parallel worker, not a serial fallback at the end.
        PARALLEL_PLAN_DELAY=2 IMPORT_SIZE_TIMEOUT=1 IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$destination" yes '/tmp/*' '/backup' > "$TMP_ROOT/parallel.out" 2>&1 || {
            cat "$TMP_ROOT/parallel.out"; exit 1;
        }
        grep -q '4 workers on separate SSH connections' "$TMP_ROOT/parallel.out" || exit 2
        grep -q -- "-S '$TMP_ROOT/parallel-ctl/xfer\.[A-Za-z0-9]*/1'" "$bin/worker-1" || exit 3
        [ -e "$bin/worker-5" ] || exit 3
        grep -q -- '--no-recursive --dirs --from0' "$bin/worker-1" || exit 4
        grep -q -- '--delete' "$bin/worker-1" && exit 4
        grep -q '^FINAL >f' "$TMP_ROOT/parallel.out" && exit 15
        IMPORT_TRANSFER_JOBS=1 import_remote_files "$site" "$reference" yes '/tmp/*' '/backup' > /dev/null || exit 5
        diff -r --no-dereference "$reference" "$destination" || exit 6
        [ -L "$destination/contents/inside" ] && [ ! -L "$destination/contents/store" ] || exit 7
        [ ! -e "$destination/stale.txt" ] && [ ! -e "$destination/backup" ] && [ -d "$destination/tmp" ] || exit 8
        # An unchanged repeat must not send regular file data again.
        rm "$bin"/worker-*
        IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$destination" yes '/tmp/*' '/backup' > "$TMP_ROOT/parallel-repeat.out" 2>&1 || exit 9
        [ ! -e "$bin/worker-1" ] || exit 10
        # A failed worker must propagate its status, retaining partial work
        # and stale files for a retry instead of running the deletion pass.
        rm -rf "$destination/contents/screens"
        echo stale > "$destination/stale.txt"
        status=0
        PARALLEL_FAIL=2 IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$destination" yes '/tmp/*' '/backup' > "$TMP_ROOT/parallel-fail.out" 2>&1 || status=$?
        [ "$status" -eq 23 ] && [ -e "$destination/stale.txt" ] || exit 11
        IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$destination" yes '/tmp/*' '/backup' > /dev/null || exit 12
        diff -r --no-dereference "$reference" "$destination" || exit 13
        # Never copy or delete from a failed plan. Connection and permission
        # errors must propagate too, not hide behind a serial fallback.
        rm -rf "$destination/contents/screens"
        echo stale > "$destination/stale.txt"
        for plan_status in 124 12 23; do
            status=0
            PARALLEL_PLAN_STATUS="$plan_status" PARALLEL_SHORT_PLAN=yes IMPORT_TRANSFER_JOBS=4 IMPORT_TRANSFER_RETRIES=0 import_remote_files "$site" "$destination" yes '/tmp/*' '/backup' > "$TMP_ROOT/parallel-plan-fail.out" 2>&1 || status=$?
            [ "$status" -eq "$plan_status" ] || exit 16
            [ ! -e "$destination/contents/screens" ] && [ -f "$destination/stale.txt" ] || exit 17
            grep -q 'parallel transfer planning failed' "$TMP_ROOT/parallel-plan-fail.out" || exit 29
            grep -q 'fixture: interrupted or failed planning' "$TMP_ROOT/parallel-plan-fail.out" || exit 30
        done
        # A live source may still change after a complete plan.
        PARALLEL_VANISH=2 IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$destination" yes '/tmp/*' '/backup' > /dev/null || exit 18
        diff -r --no-dereference "$reference" "$destination" || exit 19
        rm "$destination/contents/screens/one/0.jpg"
        mkdir "$destination/contents/screens/one/0.jpg"
        echo obsolete > "$destination/contents/screens/one/0.jpg/old"
        IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$destination" yes '/tmp/*' '/backup' > /dev/null || exit 20
        diff -r --no-dereference "$reference" "$destination" || exit 21
        rm -rf "$destination/contents/screens"
        FAKE_SSH_INDEPENDENT_FAIL=yes IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$destination" yes '/tmp/*' '/backup' > "$TMP_ROOT/parallel-shared.out" 2>&1 || exit 22
        grep -q 'sharing the authenticated SSH connection' "$TMP_ROOT/parallel-shared.out" || exit 23
        diff -r --no-dereference "$reference" "$destination" || exit 24
        # Even a server accepting just one unauthenticated connection can
        # run 32 established transfers: the remote readiness marker gates
        # the next startup while the server-side transfer barrier proves
        # copying still overlaps. One file a chunk makes more chunks than
        # workers, so the workers reuse their connections too.
        rm "$bin"/worker-* "$bin"/started-*
        FAKE_SSH_STARTUP_GUARD="$TMP_ROOT/auth-guard" IMPORT_TRANSFER_CHUNK=1 IMPORT_TRANSFER_JOBS=32 import_remote_files "$site" "$TMP_ROOT/parallel-32" yes '/tmp/*' '/backup' > "$TMP_ROOT/parallel-32.out" 2>&1 || {
            cat "$TMP_ROOT/parallel-32.out"; exit 25;
        }
        [ -f "$bin/started-33" ] || exit 26
        diff -r --no-dereference "$reference" "$TMP_ROOT/parallel-32" || exit 27
        grep -q KVS_IMPORT_SSH_READY "$TMP_ROOT/parallel-32.out" && exit 28
        for jobs in 0 33 -1 04 invalid; do
            IMPORT_TRANSFER_JOBS="$jobs" import_remote_files "$site" "$destination" yes > /dev/null 2>&1 && exit 14
        done
        for chunk in 0 1000001 -5 05 invalid; do
            IMPORT_TRANSFER_CHUNK="$chunk" IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$destination" yes > "$TMP_ROOT/chunk-invalid.out" 2>&1 && exit 31
            grep -q 'IMPORT_TRANSFER_CHUNK must be an integer from 1 to 1000000' "$TMP_ROOT/chunk-invalid.out" || exit 32
        done
        exit 0
    ) || fail "parallel copies must match a single mirror, resume and propagate failures (case $?)"
    pass "parallel transfers preserve the mirror and resume after a worker failure"
}

# A site can hold the same file under several names (a video linked into
# several folders). Copied as separate files, a group of links takes its
# size once per name on the new server, beyond the size the exporter
# measured and the free space checked for it.
test_hard_links_arrive_as_links() {
    local bin="$TMP_ROOT/links-bin" site="$TMP_ROOT/links-site" destination jobs

    make_fake_ssh "$bin"
    make_site "$site" "$site"
    mkdir -p "$site/contents/videos/0/1" "$site/contents/videos/0/2" "$site/contents/videos_screenshots/0/1"
    head -c 65536 /dev/urandom > "$site/contents/videos/0/1/1.mp4"
    ln "$site/contents/videos/0/1/1.mp4" "$site/contents/videos/0/2/2.mp4"
    ln "$site/contents/videos/0/1/1.mp4" "$site/contents/videos_screenshots/0/1/1.mp4"
    echo screenshot > "$site/contents/videos_screenshots/0/1/preview.jpg"
    ln "$site/contents/videos_screenshots/0/1/preview.jpg" "$site/contents/videos_screenshots/0/1/preview.mp4.jpg"
    (
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/links-ctl" import_ssh_setup old.example.com 22 root "" yes
        IMPORT_REMOTE_SUDO=no
        links_kept() {
            local dir="$1"
            [ "$(stat -c '%h' "$dir/contents/videos/0/1/1.mp4")" -eq 3 ] &&
                [ "$(stat -c '%i' "$dir/contents/videos/0/2/2.mp4")" = "$(stat -c '%i' "$dir/contents/videos/0/1/1.mp4")" ] &&
                [ "$(stat -c '%i' "$dir/contents/videos_screenshots/0/1/1.mp4")" = "$(stat -c '%i' "$dir/contents/videos/0/1/1.mp4")" ] &&
                [ "$(stat -c '%i' "$dir/contents/videos_screenshots/0/1/preview.mp4.jpg")" = "$(stat -c '%i' "$dir/contents/videos_screenshots/0/1/preview.jpg")" ]
        }
        for jobs in 1 4; do
            destination="$TMP_ROOT/links-dest-$jobs"
            IMPORT_TRANSFER_JOBS=$jobs import_remote_files "$site" "$destination" yes > "$TMP_ROOT/links-$jobs.out" 2>&1 || exit 1
            links_kept "$destination" || exit 2
        done
        # A copy an earlier pass made without the links gets them back.
        destination="$TMP_ROOT/links-earlier"
        cp -a "$site/." "$destination"
        for name in contents/videos/0/2/2.mp4 contents/videos_screenshots/0/1/1.mp4 contents/videos_screenshots/0/1/preview.mp4.jpg; do
            cp -p "$destination/$name" "$destination/$name.copy"
            mv "$destination/$name.copy" "$destination/$name"
        done
        links_kept "$destination" && exit 3
        IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$destination" yes > "$TMP_ROOT/links-earlier.out" 2>&1 || exit 4
        links_kept "$destination" || exit 5
        destination="$TMP_ROOT/links-tar"
        import_remote_files "$site" "$destination" no > /dev/null 2>&1 || exit 6
        links_kept "$destination" || exit 7
        exit 0
    ) || fail "hard links of the site must arrive as links, in parallel, serial, repeated and tar transfers (case $?)"
    pass "hard links of the site arrive as links"
}

# The init gives the whole site to 1000:1000, and a mode set on this
# side, by the init or by KVS (666 and 777 on what it writes), must stay.
# With rsync -a, every later pass gave each file back its owner and mode
# on the old server and the init then changed them all again: two
# metadata writes per file and per pass, millions on a large site, the
# frozen pass too. The files set here now keep their modes, a changed one
# as well, a new file arrives with its mode on the old server, and every
# rsync from the old server writes 1000:1000.
test_a_later_pass_keeps_the_owner_and_modes_the_init_set() {
    local bin="$TMP_ROOT/modes-bin" template="$TMP_ROOT/modes-template" site destination shots changed jobs

    make_fake_ssh "$bin"
    make_site "$template" "$template"
    mkdir -p "$template/contents/videos_screenshots/0/1"
    printf 'one\n' > "$template/contents/videos_screenshots/0/1/1.jpg"
    printf 'two\n' > "$template/contents/videos_screenshots/0/1/2.jpg"
    chmod 644 "$template/contents/videos_screenshots/0/1/1.jpg" "$template/contents/videos_screenshots/0/1/2.jpg"
    chmod 755 "$template/contents/videos_screenshots/0/1"
    # A wrapper around real rsync keeps the command line of every rsync
    # run on this side.
    cat > "$bin/rsync" <<'EOF'
#!/bin/bash
case " $* " in
    *" --server "*) ;;
    *) printf '%s\n' "$*" >> "$MODES_BIN/local-rsync" ;;
esac
exec "$REAL_RSYNC" "$@"
EOF
    chmod +x "$bin/rsync"
    (
        export REAL_RSYNC MODES_BIN="$bin"
        REAL_RSYNC=$(command -v rsync)
        PATH="$bin:$PATH"
        umask 022
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/modes-ctl" import_ssh_setup old.example.com 22 root "" yes
        IMPORT_REMOTE_SUDO=no
        for jobs in 1 4; do
            site="$TMP_ROOT/modes-site-$jobs" destination="$TMP_ROOT/modes-dest-$jobs"
            shots="$destination/contents/videos_screenshots/0/1"
            cp -a "$template" "$site"
            IMPORT_TRANSFER_JOBS=$jobs import_remote_files "$site" "$destination" yes > "$TMP_ROOT/modes-$jobs-first.out" 2>&1 || exit 1
            [ "$(stat -c '%a' "$shots/1.jpg")" = 644 ] || exit 2
            # Modes set on this side, as KVS gives them to what it writes.
            chmod 777 "$shots"
            chmod 666 "$shots/1.jpg" "$shots/2.jpg"
            changed=$(stat -c '%z' "$shots/1.jpg")
            printf 'two, changed\n' > "$site/contents/videos_screenshots/0/1/2.jpg"
            printf 'three\n' > "$site/contents/videos_screenshots/0/1/3.jpg"
            chmod 644 "$site/contents/videos_screenshots/0/1/3.jpg"
            IMPORT_TRANSFER_JOBS=$jobs import_remote_files "$site" "$destination" yes > "$TMP_ROOT/modes-$jobs-later.out" 2>&1 || exit 3
            [ "$(stat -c '%a' "$shots")" = 777 ] || exit 4
            [ "$(stat -c '%a' "$shots/1.jpg")" = 666 ] || exit 5
            [ "$(stat -c '%z' "$shots/1.jpg")" = "$changed" ] || exit 6
            [ "$(cat "$shots/2.jpg")" = 'two, changed' ] && [ "$(stat -c '%a' "$shots/2.jpg")" = 666 ] || exit 7
            [ "$(stat -c '%a' "$shots/3.jpg")" = 644 ] || exit 8
        done
        exit 0
    ) || fail "a later pass must keep the modes the init set and leave an unchanged file alone (case $?)"
    grep -F 'old.example.com:' "$bin/local-rsync" > "$TMP_ROOT/modes-transfers" ||
        fail "no rsync from the old server was seen"
    if grep -v -F -e '--chown=1000:1000' "$TMP_ROOT/modes-transfers" | grep -q . ||
        grep -v -F -e '--no-perms' "$TMP_ROOT/modes-transfers" | grep -q .; then
        fail "every rsync from the old server must write 1000:1000 and keep the modes here: $(head -n 1 "$TMP_ROOT/modes-transfers")"
    fi
    pass "a later pass keeps the owner and modes the init set"
}

# rsync relays a --files-from list given on its side to the sender on the
# old server, a relay that grows with the square of the list: the workers
# of a site of several million files can copy nothing for hours. They read their
# chunk lists in a temporary directory of the old server, all copied there
# in one stream, which goes afterwards; when it cannot be made there,
# rsync relays them, cut into short lists whose relay stays quick.
test_parallel_workers_read_their_lists_on_the_old_server() {
    local bin="$TMP_ROOT/lists-bin" site="$TMP_ROOT/lists-site" remote_tmp="$TMP_ROOT/lists-remote-tmp" i uploads chunks names

    make_fake_ssh "$bin"
    make_site "$site" "$site"
    mkdir -p "$site/contents/screens/one" "$site/contents/screens/two" "$remote_tmp"
    for ((i = 0; i < 12; i++)); do
        printf 'screen %s\n' "$i" > "$site/contents/screens/one/$i.jpg"
        printf 'screen %s\n' "$i" > "$site/contents/screens/two/$i.jpg"
    done
    # The --files-from each worker's rsync is given, on this side, and the
    # number of names in that list when the rsync starts.
    cat > "$bin/rsync" <<'EOF'
#!/bin/bash
server=no
for arg in "$@"; do [ "$arg" != --server ] || server=yes; done
if [ "$server" = no ]; then
    for arg in "$@"; do
        case "$arg" in
            --files-from=*)
                list=${arg#--files-from=}
                printf '%s\n' "$list" >> "$LISTS_BIN/files-from.log"
                tr -cd '\0' < "${list#:}" | wc -c >> "$LISTS_BIN/names.log"
                ;;
        esac
    done
fi
exec "$REAL_RSYNC" "$@"
EOF
    chmod +x "$bin/rsync"
    (
        export REAL_RSYNC LISTS_BIN="$bin" TMPDIR="$remote_tmp" IMPORT_TRANSFER_CHUNK=5
        REAL_RSYNC=$(command -v rsync)
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/lists-ctl" import_ssh_setup old.example.com 22 root "" yes
        IMPORT_REMOTE_SUDO=no
        IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$TMP_ROOT/lists-dest" yes > "$TMP_ROOT/lists.out" 2>&1 || exit 1
        # The upload and the listing of the first chunks say what they wait for.
        grep -q '^  Copying the chunk lists ([0-9]* kB) to the old server in one stream\.\.\.$' "$TMP_ROOT/lists.out" || exit 2
        grep -q 'Chunk lists copied to .*/kvs-import-plan\.[A-Za-z0-9]* on the old server in [0-9]* s; the workers read them there' "$TMP_ROOT/lists.out" || exit 2
        grep -q '^  Each rsync lists its chunk of up to 5 files on the old server before copying it' "$TMP_ROOT/lists.out" || exit 2
        chunks=$(sed -n 's/^  Transferring \([0-9]*\) chunks .*/\1/p' "$TMP_ROOT/lists.out")
        [ "${chunks:-0}" -gt 4 ] || exit 3
        # One SSH session carries every list, whatever the number of chunks.
        uploads=$(grep -c "^command tar -xmf - -C '$remote_tmp/kvs-import-plan\.[A-Za-z0-9]*'$" "$bin/ssh.log")
        [ "$uploads" -eq 1 ] || exit 3
        grep -q '^command cat > ' "$bin/ssh.log" && exit 3
        [ "$(grep -c "^:$remote_tmp/kvs-import-plan\.[A-Za-z0-9]*/[0-9]*\.list$" "$bin/files-from.log")" -eq "$chunks" ] || exit 4
        [ "$(sort -u "$bin/files-from.log" | wc -l)" -eq "$chunks" ] || exit 4
        [ -z "$(ls -A "$remote_tmp")" ] || exit 5
        diff -r "$site" "$TMP_ROOT/lists-dest" || exit 6
        names=$(awk '{ total += $1 } END { print total + 0 }' "$bin/names.log")
        # No temporary directory on the old server: rsync relays the lists,
        # cut shorter first.
        rm "$bin/files-from.log" "$bin/names.log"
        FAKE_SSH_FAIL_COMMAND=mktemp IMPORT_RSYNC_RELAY_FILES=2 IMPORT_TRANSFER_JOBS=4 \
            import_remote_files "$site" "$TMP_ROOT/lists-relayed" yes > "$TMP_ROOT/lists-relayed.out" 2>&1 || exit 7
        chunks=$(sed -n 's/^  The chunk lists could not be copied to the old server: rsync relays each list from here, .*, so a chunk holds 2 files at most (\([0-9]*\) chunks)\.$/\1/p' "$TMP_ROOT/lists-relayed.out")
        [ "${chunks:-0}" -ge $(((names + 1) / 2)) ] || exit 8
        grep -q '^:' "$bin/files-from.log" && exit 9
        [ "$(grep -c '/[0-9]*\.list$' "$bin/files-from.log")" -eq "$chunks" ] || exit 10
        [ "$(sort -n "$bin/names.log" | tail -n 1)" -le 2 ] || exit 10
        [ "$(awk '{ total += $1 } END { print total + 0 }' "$bin/names.log")" -eq "$names" ] || exit 10
        diff -r "$site" "$TMP_ROOT/lists-relayed" || exit 11
        # A failed upload leaves nothing on the old server either. Lists
        # already short enough are relayed as they are.
        rm "$bin/files-from.log" "$bin/names.log"
        FAKE_SSH_FAIL_COMMAND='tar -xmf' IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$TMP_ROOT/lists-failed-upload" yes > "$TMP_ROOT/lists-failed-upload.out" 2>&1 || exit 12
        grep -q 'rsync relays each list from here, .*, so a chunk holds 5 files at most' "$TMP_ROOT/lists-failed-upload.out" || exit 13
        grep -q '^:' "$bin/files-from.log" && exit 14
        [ -z "$(ls -A "$remote_tmp")" ] || exit 15
        diff -r "$site" "$TMP_ROOT/lists-failed-upload" || exit 16
        exit 0
    ) || fail "parallel workers must read their lists on the old server and leave nothing there (case $?)"
    pass "parallel workers read their lists on the old server"
}

# The old server still runs the live site: the chunk lists only go to its
# temporary directory when that keeps 1 GB free once they are stored.
# Otherwise, or when df cannot tell, nothing is written there and rsync
# relays the lists.
test_chunk_lists_stay_off_an_old_server_short_of_room() {
    local bin="$TMP_ROOT/room-bin" site="$TMP_ROOT/room-site" remote_tmp="$TMP_ROOT/room-tmp"

    make_fake_ssh "$bin"
    make_site "$site" "$site"
    mkdir -p "$remote_tmp"
    (
        export TMPDIR="$remote_tmp" IMPORT_TRANSFER_CHUNK=2
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/room-ctl" import_ssh_setup old.example.com 22 root "" yes
        IMPORT_REMOTE_SUDO=no
        # Just under 1 GB free: nothing is left for the lists.
        FAKE_DF_AVAILABLE=1048575 IMPORT_TRANSFER_JOBS=4 \
            import_remote_files "$site" "$TMP_ROOT/room-short" yes > "$TMP_ROOT/room-short.out" 2>&1 || exit 1
        grep -q '^  The temporary directory of the old server has [0-9.]* [MG]B free, too little for the chunk lists ([0-9]* kB) and the 1 GB its live site keeps: rsync relays each list from here' \
            "$TMP_ROOT/room-short.out" || exit 2
        grep -q 'Copying the chunk lists' "$TMP_ROOT/room-short.out" && exit 3
        grep -E -q '^command .*(mktemp|tar -x)' "$bin/ssh.log" && exit 3
        [ -z "$(ls -A "$remote_tmp")" ] || exit 4
        diff -r "$site" "$TMP_ROOT/room-short" || exit 5
        # df gives no answer: nothing is known, nothing goes there.
        : > "$bin/ssh.log"
        FAKE_DF_FAIL=yes IMPORT_TRANSFER_JOBS=4 \
            import_remote_files "$site" "$TMP_ROOT/room-unknown" yes > "$TMP_ROOT/room-unknown.out" 2>&1 || exit 6
        grep -q '^  The free space of the temporary directory of the old server is unknown, so the chunk lists ([0-9]* kB) stay here: rsync relays each list from here' \
            "$TMP_ROOT/room-unknown.out" || exit 7
        grep -E -q '^command .*(mktemp|tar -x)' "$bin/ssh.log" && exit 8
        diff -r "$site" "$TMP_ROOT/room-unknown" || exit 9
        # 2 GB free: the lists go there, and leave at the end.
        FAKE_DF_AVAILABLE=2097152 IMPORT_TRANSFER_JOBS=4 \
            import_remote_files "$site" "$TMP_ROOT/room-enough" yes > "$TMP_ROOT/room-enough.out" 2>&1 || exit 10
        grep -q '^  Chunk lists copied to .*/kvs-import-plan\.[A-Za-z0-9]* on the old server' "$TMP_ROOT/room-enough.out" || exit 11
        [ -z "$(ls -A "$remote_tmp")" ] || exit 12
        diff -r "$site" "$TMP_ROOT/room-enough" || exit 13
        exit 0
    ) || fail "the chunk lists must stay off an old server short of room (case $?): $(tail -n 5 "$TMP_ROOT"/room-*.out)"
    pass "the chunk lists stay off an old server short of room"
}

# The same command again after an interrupted transfer checks the room of
# the database alone before it, the files of the earlier pass being there.
# What is left to copy is known once the transfer is planned: it has to fit
# with the database before a file is copied.
test_the_transfer_stops_when_what_is_left_does_not_fit() {
    local bin="$TMP_ROOT/fit-bin" site="$TMP_ROOT/fit-site" jobs

    make_fake_ssh "$bin"
    make_site "$site" "$site"
    for jobs in 4 1; do
        rm -rf "$TMP_ROOT/fit-dest"
        (
            PATH="$bin:$PATH"
            IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/fit-ctl" import_ssh_setup old.example.com 22 root "" yes
            IMPORT_REMOTE_SUDO=no
            # 11 MB free: the few bytes of the site fit, not with the 10 MB
            # of the database and a tenth of margin.
            if FAKE_DF_LOCAL_MB=11 IMPORT_TRANSFER_RESERVE_MB=10 IMPORT_TRANSFER_JOBS=$jobs \
                import_remote_files "$site" "$TMP_ROOT/fit-dest" yes > "$TMP_ROOT/fit.out" 2>&1; then
                exit 1
            fi
            grep -q '^ERROR: not enough free space under .*/fit-dest: the transfer still copies [0-9]* kB and the database takes about 10 MB, with a tenth of margin, and 11 MB is free' \
                "$TMP_ROOT/fit.out" || exit 2
            [ -z "$(find "$TMP_ROOT/fit-dest" -type f)" ] || exit 3
            # 13 MB free: it fits.
            FAKE_DF_LOCAL_MB=13 IMPORT_TRANSFER_RESERVE_MB=10 IMPORT_TRANSFER_JOBS=$jobs \
                import_remote_files "$site" "$TMP_ROOT/fit-dest" yes > "$TMP_ROOT/fit.out" 2>&1 || exit 4
            diff -r "$site" "$TMP_ROOT/fit-dest" || exit 5
            exit 0
        ) || fail "the transfer must stop before copying what does not fit, with $jobs worker(s) (case $?): $(tail -n 3 "$TMP_ROOT/fit.out")"
    done
    pass "the transfer stops before copying what does not fit"
}

# An old server given by its IPv6 address: ssh takes the address as it
# is, rsync reads host:path and took the host up to the first colon.
test_ipv6_address_of_the_old_server() {
    local bin="$TMP_ROOT/ipv6-bin" site="$TMP_ROOT/ipv6-site" jobs

    make_fake_ssh "$bin"
    make_site "$site" "$site"
    for jobs in 4 1; do
        rm -rf "$TMP_ROOT/ipv6-dest"
        : > "$bin/ssh.log"
        (
            PATH="$bin:$PATH"
            IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/ipv6-ctl" import_ssh_setup 2001:db8::7 22 root "" yes
            IMPORT_REMOTE_SUDO=no
            IMPORT_TRANSFER_JOBS=$jobs import_remote_files "$site" "$TMP_ROOT/ipv6-dest" yes > "$TMP_ROOT/ipv6.out" 2>&1 || exit 1
            diff -r "$site" "$TMP_ROOT/ipv6-dest" > /dev/null || exit 2
            # rsync opened its connections to the address, not to "2001".
            grep -q '^target 2001:db8::7$' "$bin/ssh.log" || exit 3
            grep -q '^target 2001$' "$bin/ssh.log" && exit 4
            exit 0
        ) || fail "the files of an old server given by its IPv6 address must arrive with $jobs worker(s) (case $?): $(tail -n 5 "$TMP_ROOT/ipv6.out")"
    done
    pass "the files of an old server given by its IPv6 address arrive"
}

# Ctrl-C in a terminal goes to the foreground process group. A timeout
# that moved the planning scan into a group of its own kept it running on
# the old server, and the setup waiting for it, until the scan ended.
test_interrupt_stops_the_planning_scan() {
    local bin="$TMP_ROOT/interrupt-bin" site="$TMP_ROOT/interrupt-site" jobs leader start elapsed

    make_fake_ssh "$bin"
    make_site "$site" "$site"
    for jobs in 4 1; do
        rm -rf "$TMP_ROOT/interrupt-dest"
        cat > "$TMP_ROOT/interrupt-run.sh" <<EOF
#!/bin/bash
source "$REPO_ROOT/docker/lib/import.sh"
PATH="$bin:\$PATH"
IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/interrupt-ctl" import_ssh_setup old.example.com 22 root "" yes
IMPORT_REMOTE_SUDO=no
IMPORT_TRANSFER_JOBS=$jobs import_remote_files "$site" "$TMP_ROOT/interrupt-dest" yes
EOF
        # A job started from a terminal: its own session, SIGINT not ignored.
        FAKE_SSH_DELAY=15 setsid env --default-signal=INT,QUIT bash "$TMP_ROOT/interrupt-run.sh" > "$TMP_ROOT/interrupt.out" 2>&1 &
        leader=$!
        sleep 2
        kill -INT -- "-$leader"
        start=$SECONDS
        while kill -0 "$leader" 2>/dev/null && [ $((SECONDS - start)) -lt 20 ]; do sleep 0.2; done
        elapsed=$((SECONDS - start))
        kill -KILL -- "-$leader" 2>/dev/null || true
        wait "$leader" 2>/dev/null || true
        [ "$elapsed" -le 5 ] ||
            fail "Ctrl-C during the planning scan waited $elapsed s for the scan to end (IMPORT_TRANSFER_JOBS=$jobs)"
        [ ! -e "$TMP_ROOT/interrupt-dest/admin" ] || fail "files were copied after Ctrl-C (IMPORT_TRANSFER_JOBS=$jobs)"
    done
    pass "Ctrl-C during the planning scan stops the import at once"
}

test_parallel_interruption_stops_the_process_groups() {
    local bin="$TMP_ROOT/interrupted-bin" plan="$TMP_ROOT/interrupted-plan" i pid status=0
    mkdir -p "$bin" "$plan"
    for i in 1 2 3 4; do printf 'file\0' > "$plan/$i.list"; done
    cat > "$bin/rsync" <<'EOF'
#!/bin/bash
echo "$$" >> "$INTERRUPTED_PLAN/pids"
sleep 60 &
echo "$!" >> "$INTERRUPTED_PLAN/pids"
wait
EOF
    chmod +x "$bin/rsync"
    INTERRUPTED_PLAN="$plan" PATH="$bin:$PATH" timeout --preserve-status -k 5s 2s \
        bash -c 'source "$1"; import_rsync_workers "$2" 4 unused' _ "$REPO_ROOT/docker/lib/import.sh" "$plan" \
        > "$TMP_ROOT/interrupted.out" 2>&1 || status=$?
    # The shell killed by TERM: GNU timeout --preserve-status returns 143,
    # as a shell reports such a command, the timeout of uutils (the
    # coreutils Ubuntu 26.04 defaults to) the number of the signal alone.
    case "$status" in
        143) ;;
        15) timeout --version 2>/dev/null | grep -q uutils || fail "interruption must return TERM, got $status" ;;
        *) fail "interruption must return TERM, got $status" ;;
    esac
    [ "$(wc -l < "$plan/pids")" -eq 8 ] || fail "four rsync workers and their children must have started"
    while read -r pid; do
        # timeout returns once the shell it started is gone, a millisecond
        # or so before the exit trap of the scheduler has stopped the
        # process groups. A reparented child can briefly be a zombie until
        # init reaps it; it must not be running once that trap is done.
        for ((i = 0; i < 50; i++)); do
            if ! kill -0 "$pid" 2>/dev/null || [ "$(ps -o stat= -p "$pid" | cut -c1)" = Z ]; then
                break
            fi
            sleep 0.1
        done
        [ "$i" -lt 50 ] || fail "worker child $pid survived interruption"
    done < "$plan/pids"
    pass "interruption stops every worker and its SSH process group"
}

# The plan keeps the order of the scan and cuts it into chunks of at most
# IMPORT_TRANSFER_CHUNK files and 1 GB of data, the size of the file list
# each rsync builds before it copies anything, keeping directories
# together. Toward the end the chunks shrink, so the workers finish
# together.
test_the_plan_cuts_the_scan_into_bounded_chunks() {
    local plan="$TMP_ROOT/chunk-plan" chunks i names previous videos

    mkdir -p "$plan"
    {
        for ((i = 0; i < 1000; i++)); do
            printf 'KVS-PLAN >f+++++++++ 100 d%d/f%03d.jpg\n' $((i / 100)) "$i"
        done
        printf 'KVS-PLAN hf+++++++++ 100 d0/linked.jpg => d0/f000.jpg\n'
        for ((i = 0; i < 8; i++)); do
            printf 'KVS-PLAN >f+++++++++ 629145600 videos/v%d.mp4\n' "$i"
        done
        printf 'Number of files: 1009\n'
    } | import_rsync_plan "$plan" 50 > "$TMP_ROOT/chunk-plan.out" 2>/dev/null || fail "the plan must succeed"
    grep -qx 'Number of files: 1009' "$TMP_ROOT/chunk-plan.out" || fail "the other lines of the dry run pass through"
    chunks=$(import_rsync_chunks "$plan" 2 50) || fail "the chunks must be written"
    [ "$chunks" -gt 20 ] || fail "1,000 files in chunks of 50 at most make more than 20 chunks, got $chunks"
    [ ! -e "$plan/pieces" ] && [ -z "$(find "$plan" -name '*.piece')" ] || fail "the pieces go once grouped"
    for ((i = 1; i <= chunks; i++)); do
        names=$(tr -cd '\0' < "$plan/$i.list" | wc -c)
        [ "$names" -ge 1 ] && [ "$names" -le 50 ] || fail "chunk $i holds $names files, not 1 to 50"
        videos=$(tr '\0' '\n' < "$plan/$i.list" | grep -c '^\./videos/' || true)
        [ "$videos" -le 1 ] || fail "chunk $i holds $videos videos of 600 MB, more than 1 GB"
    done
    # One after the other, the chunks give the order of the scan back, and
    # only the files needing data: the other name of a hard link is left to
    # the final mirror.
    {
        for ((i = 0; i < 1000; i++)); do printf './d%d/f%03d.jpg\0' $((i / 100)) "$i"; done
        for ((i = 0; i < 8; i++)); do printf './videos/v%d.mp4\0' "$i"; done
    } > "$TMP_ROOT/chunk-plan.expected"
    for ((i = 1; i <= chunks; i++)); do cat "$plan/$i.list"; done | cmp -s - "$TMP_ROOT/chunk-plan.expected" ||
        fail "the chunks must keep the order of the scan"

    # A chunk is made of whole pieces, a sixteenth of a chunk each that ends
    # with its directory, twice that inside a large one: 6 names here. The
    # chunks shrink toward the end, never growing again by more than one
    # piece, down to a single piece.
    rm -rf "$plan"
    mkdir -p "$plan"
    for ((i = 0; i < 1000; i++)); do
        printf 'KVS-PLAN >f+++++++++ 100 d%d/f%03d.jpg\n' $((i / 100)) "$i"
    done | import_rsync_plan "$plan" 48 > /dev/null 2>&1 || fail "the plan of small files must succeed"
    chunks=$(import_rsync_chunks "$plan" 4 48)
    [ "$(tr -cd '\0' < "$plan/1.list" | wc -c)" -eq 48 ] || fail "the first chunks are full"
    previous=48
    for ((i = 1; i <= chunks; i++)); do
        names=$(tr -cd '\0' < "$plan/$i.list" | wc -c)
        [ "$names" -le 48 ] || fail "chunk $i holds $names files, more than 48"
        [ "$names" -le $((previous + 6)) ] || fail "chunk $i ($names files) grows by more than a piece on the one before ($previous)"
        previous=$names
    done
    [ "$previous" -le 6 ] || fail "the last chunk is one piece, got $previous files"

    # rsync lists the parent directories of every name, in each list that
    # holds one: a directory smaller than a piece stays in one chunk.
    rm -rf "$plan"
    mkdir -p "$plan"
    for ((i = 0; i < 1000; i++)); do
        printf 'KVS-PLAN >f+++++++++ 100 s%03d/f%d.jpg\n' $((i / 5)) $((i % 5))
    done | import_rsync_plan "$plan" 48 > /dev/null 2>&1 || fail "the plan of small directories must succeed"
    chunks=$(import_rsync_chunks "$plan" 4 48)
    for ((i = 1; i <= chunks; i++)); do
        tr '\0' '\n' < "$plan/$i.list" | sed 's|/[^/]*$||' | sort -u
    done | sort | uniq -d > "$TMP_ROOT/chunk-plan.split"
    [ ! -s "$TMP_ROOT/chunk-plan.split" ] || fail "directories of 5 files spread over several chunks: $(head -n 3 "$TMP_ROOT/chunk-plan.split" | tr '\n' ' ')"

    rm -rf "$plan"
    mkdir -p "$plan"
    printf 'Number of files: 0\n' | import_rsync_plan "$plan" 50 > /dev/null || fail "an empty plan must succeed"
    [ "$(import_rsync_chunks "$plan" 4 50)" = 0 ] || fail "nothing to copy makes no chunk"
    pass "the plan cuts the scan into bounded chunks in its order"
}

# When rsync has to relay the lists, whose relay grows with the square of
# their length, they are cut shorter and keep their order.
test_relayed_lists_are_cut_short_in_order() {
    local plan="$TMP_ROOT/rechunk-plan" chunks i sizes=""

    mkdir -p "$plan"
    for ((i = 0; i < 7; i++)); do printf './a/%d\0' "$i"; done > "$plan/1.list"
    for ((i = 0; i < 3; i++)); do printf './b/%d\0' "$i"; done > "$plan/2.list"
    for ((i = 0; i < 12; i++)); do printf './c/%d\0' "$i"; done > "$plan/3.list"
    cat "$plan/1.list" "$plan/2.list" "$plan/3.list" > "$TMP_ROOT/rechunk.expected"
    chunks=$(import_rsync_rechunk "$plan" 5) || fail "the lists must be cut"
    for ((i = 1; i <= chunks; i++)); do sizes+="$(tr -cd '\0' < "$plan/$i.list" | wc -c) "; done
    [ "$sizes" = "5 2 3 5 5 2 " ] || fail "lists of 7, 3 and 12 names cut to 5 must give 5 2 3 5 5 2, got $sizes"
    for ((i = 1; i <= chunks; i++)); do cat "$plan/$i.list"; done | cmp -s - "$TMP_ROOT/rechunk.expected" ||
        fail "the cut lists must keep the order"
    [ "$(find "$plan" -type f | wc -l)" -eq 6 ] || fail "only the cut lists remain"
    pass "relayed lists are cut short in their order"
}

# Every rsync of a worker builds the file list of one chunk before it
# copies anything, never the list of all the files of the worker: copying
# starts once the first chunk is listed, and the next chunks are listed
# while the first files are already there.
test_every_rsync_copies_one_chunk_at_most() {
    local bin="$TMP_ROOT/bounded-bin" site="$TMP_ROOT/bounded-site" destination="$TMP_ROOT/bounded-dest"
    local i directory chunks names total=0 copied_before=0 runs

    make_fake_ssh "$bin"
    make_site "$site" "$site"
    for directory in a b c; do
        mkdir -p "$site/contents/screens/$directory"
        for ((i = 0; i < 8; i++)); do
            printf '%s %s\n' "$directory" "$i" > "$site/contents/screens/$directory/$i.jpg"
        done
    done
    # A wrapper around real rsync keeps each chunk list, the local one or
    # the one read on the old server, with the files the destination held
    # when the rsync started.
    cat > "$bin/rsync" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        --files-from=*)
            list=${arg#--files-from=}
            list=${list#:}
            chunk=${list##*/}
            chunk=${chunk%.list}
            cp "$list" "$BOUNDED_BIN/list-$chunk"
            printf '%s %s\n' "$chunk" "$(find "$BOUNDED_DEST" -type f -name '*.jpg' 2>/dev/null | wc -l)" >> "$BOUNDED_BIN/starts"
            ;;
    esac
done
exec "$REAL_RSYNC" "$@"
EOF
    chmod +x "$bin/rsync"
    (
        export REAL_RSYNC BOUNDED_BIN="$bin" BOUNDED_DEST="$destination"
        REAL_RSYNC=$(command -v rsync)
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/bounded-ctl" import_ssh_setup old.example.com 22 root "" yes
        IMPORT_REMOTE_SUDO=no
        IMPORT_TRANSFER_CHUNK=4 IMPORT_TRANSFER_JOBS=2 import_remote_files "$site" "$destination" yes > "$TMP_ROOT/bounded.out" 2>&1 || exit 1
        diff -r "$site" "$destination" > /dev/null || exit 2
        exit 0
    ) || fail "a transfer in chunks must copy the site (case $?): $(tail -n 5 "$TMP_ROOT/bounded.out")"
    chunks=$(sed -n 's/^  Transferring \([0-9]*\) chunks .*/\1/p' "$TMP_ROOT/bounded.out")
    [ "${chunks:-0}" -gt 2 ] || fail "two workers must take more than two chunks, got '${chunks:-}': $(cat "$TMP_ROOT/bounded.out")"
    runs=$(wc -l < "$bin/starts")
    [ "$runs" -eq "$chunks" ] || fail "one rsync a chunk: $runs runs for $chunks chunks"
    for ((i = 1; i <= chunks; i++)); do
        names=$(tr -cd '\0' < "$bin/list-$i" | wc -c)
        [ "$names" -ge 1 ] && [ "$names" -le 4 ] || fail "the rsync of chunk $i was given $names files, not 1 to 4"
        total=$((total + names))
    done
    [ "$total" -eq 29 ] || fail "the chunks must hold the 29 files of the site once each, got $total"
    # A directory is not spread over the chunks: its files follow each
    # other in the chunk lists taken in order.
    for ((i = 1; i <= chunks; i++)); do cat "$bin/list-$i"; done | tr '\0' '\n' |
        sed -n 's|^\./contents/screens/\([abc]\)/.*|\1|p' | uniq | tr -d '\n' | grep -qx abc ||
        fail "the files of a directory must stay together in the chunks"
    # Chunk 1 started on an empty destination; a later one found files the
    # workers had already copied.
    [ "$(awk '$1 == 1 { print $2 }' "$bin/starts")" -eq 0 ] || fail "chunk 1 must start first"
    copied_before=$(awk -v last="$chunks" '$1 == last { print $2 }' "$bin/starts")
    [ "${copied_before:-0}" -gt 0 ] || fail "the last chunk must be listed after the first files were copied: $(cat "$bin/starts")"
    pass "every rsync copies one chunk at most, and copying starts with the first"
}

# A connection lost in the middle of a transfer of hours (the rsync of the
# old server killed, a network drop: statuses 5, 10, 12, 30, 35 and 255)
# ended the whole transfer, and running the same command again meant a
# new dump and a new scan of the site. The chunk now starts again after a
# pause while the other workers go on; only a chunk that keeps failing, or
# another status, stops the transfer.
test_a_lost_connection_starts_the_chunk_again() {
    local bin="$TMP_ROOT/drop-bin" plan="$TMP_ROOT/drop-plan" err="$TMP_ROOT/drop.err" i status out

    mkdir -p "$bin"
    cat > "$bin/rsync" <<'EOF'
#!/bin/bash
serial=no
for arg in "$@"; do
    case "$arg" in
        --files-from=*) list=${arg#--files-from=} ;;
        --rsync-path=*KVS_IMPORT_SSH_READY*) serial=yes ;;
    esac
done
chunk=${list##*/}
chunk=${chunk%.list}
names=$(tr -cd '\0' < "$list" | wc -c)
attempt=$(($(grep -c "^$chunk " "$DROP_BIN/runs") + 1))
printf '%s %s %s\n' "$chunk" "$attempt" "$names" >> "$DROP_BIN/runs"
if [ "$chunk" = "$DROP_CHUNK" ] && [ "$attempt" -le "$DROP_TIMES" ]; then
    if [ "${DROP_BEFORE_READY:-no}" = yes ]; then
        echo "ssh: connect to host old.example.com port 22: Connection timed out" >&2
        exit 255
    fi
    [ "$serial" = no ] || echo KVS_IMPORT_SSH_READY >&2
    printf ' 1000 50%% 1.00MB/s 0:00:01 (xfr#1, to-chk=1/2)\n'
    echo "rsync: connection unexpectedly closed (1000 bytes received so far) [receiver]" >&2
    exit "$DROP_STATUS"
fi
[ "$serial" = no ] || echo KVS_IMPORT_SSH_READY >&2
printf ' %d 100%% 1.00MB/s 0:00:01 (xfr#%d, to-chk=0/%d)\n' $((names * 1000)) "$names" "$names"
EOF
    chmod +x "$bin/rsync"
    new_plan() {
        rm -rf "$plan"
        mkdir -p "$plan"
        for i in 1 2 3; do printf './c%s-a\0./c%s-b\0' "$i" "$i" > "$plan/$i.list"; done
        : > "$bin/runs"
    }

    # Chunk 2 loses its connection once, after copying part of it.
    new_plan
    status=0
    out=$(DROP_BIN="$bin" DROP_CHUNK=2 DROP_TIMES=1 DROP_STATUS=255 PATH="$bin:$PATH" IMPORT_TRANSFER_RETRY_PAUSE=0 \
        import_rsync_workers "$plan" 2 unused 2> "$err") || status=$?
    [ "$status" -eq 0 ] || fail "a chunk stopped by a lost connection must start again, status $status: $(cat "$err")"
    [ "$(grep -c '^2 ' "$bin/runs")" -eq 2 ] || fail "chunk 2 must run twice: $(cat "$bin/runs")"
    grep -q '^2 2 2$' "$bin/runs" || fail "the new attempt must still find the list of chunk 2: $(cat "$bin/runs")"
    [ "$(grep -c -v '^2 ' "$bin/runs")" -eq 2 ] || fail "the other chunks must run once: $(cat "$bin/runs")"
    grep -q 'connection unexpectedly closed' "$err" || fail "the message of rsync must be shown: $(cat "$err")"
    grep -q '^  Transfer worker [12] lost its connection on chunk 2 of 3 (rsync status 255); attempt 2 of 9 in 0 s\.$' "$err" ||
        fail "the new attempt must be announced: $(cat "$err")"
    [ -z "$(find "$plan" -name '*.list')" ] || fail "every list must go once its chunk is copied"
    printf '%s\n' "$out" | awk '{ b = $1 + 0; f = substr($NF, 6) + 0; if (b < lb || f < lf) bad = 1; lb = b; lf = f } END { exit bad }' ||
        fail "the progress must never go back: $out"

    # A chunk that keeps losing its connection stops the transfer once its
    # attempts are spent.
    new_plan
    status=0
    DROP_BIN="$bin" DROP_CHUNK=2 DROP_TIMES=99 DROP_STATUS=12 PATH="$bin:$PATH" IMPORT_TRANSFER_RETRIES=2 IMPORT_TRANSFER_RETRY_PAUSE=0 \
        import_rsync_workers "$plan" 2 unused > /dev/null 2> "$err" || status=$?
    [ "$status" -eq 12 ] || fail "a chunk that keeps failing must stop the transfer with its status, got $status"
    [ "$(grep -c '^2 ' "$bin/runs")" -eq 3 ] || fail "chunk 2 must run three times: $(cat "$bin/runs")"
    grep -q '^ERROR: transfer worker [12] failed on chunk 2 of 3 (rsync status 12) after 3 attempts$' "$err" ||
        fail "the attempts must be counted in the error: $(cat "$err")"

    # Another status is no lost connection: no other attempt.
    new_plan
    status=0
    DROP_BIN="$bin" DROP_CHUNK=2 DROP_TIMES=1 DROP_STATUS=23 PATH="$bin:$PATH" IMPORT_TRANSFER_RETRY_PAUSE=0 \
        import_rsync_workers "$plan" 2 unused > /dev/null 2> "$err" || status=$?
    [ "$status" -eq 23 ] || fail "status 23 must stop the transfer, got $status"
    [ "$(grep -c '^2 ' "$bin/runs")" -eq 1 ] || fail "status 23 must not be tried again: $(cat "$bin/runs")"

    # The old server out of reach when a worker connects (authentication
    # one at a time): the same pauses, then the chunk.
    new_plan
    status=0
    DROP_BIN="$bin" DROP_CHUNK=1 DROP_TIMES=1 DROP_STATUS=255 DROP_BEFORE_READY=yes PATH="$bin:$PATH" \
        IMPORT_RSYNC_SERIAL_AUTH=yes IMPORT_TRANSFER_RETRY_PAUSE=0 import_rsync_workers "$plan" 2 unused > /dev/null 2> "$err" || status=$?
    [ "$status" -eq 0 ] || fail "a worker that could not connect must try again, status $status: $(cat "$err")"
    [ "$(grep -c '^1 ' "$bin/runs")" -eq 2 ] || fail "chunk 1 must run twice: $(cat "$bin/runs")"
    grep -q '^  Transfer worker 1 could not reach the old server for chunk 1 of 3 (status 255); attempt 2 of 9 in 0 s\.$' "$err" ||
        fail "the new connection must be announced: $(cat "$err")"
    pass "a lost connection starts the chunk again"
}

# The planning scan of a site of millions of files takes long enough to
# lose the old server on the way, and the import stopped there: the same
# command again meant a new dump before a new scan. The scan now starts
# again with an empty plan; a scan that keeps failing, or another status,
# still stops the import before a file is copied.
test_a_lost_connection_starts_the_planning_scan_again() {
    local bin="$TMP_ROOT/replan-bin" site="$TMP_ROOT/replan-site" destination="$TMP_ROOT/replan-dest"

    make_fake_ssh "$bin"
    make_site "$site" "$site"
    # The first REPLAN_DROPS scans find two files the site does not have,
    # then lose the old server.
    cat > "$bin/rsync" <<'EOF'
#!/bin/bash
dry=no
for arg in "$@"; do
    [ "$arg" != --dry-run ] || dry=yes
done
if [ "$dry" = yes ]; then
    echo scan >> "$REPLAN_BIN/scans"
    if [ "$(wc -l < "$REPLAN_BIN/scans")" -le "$REPLAN_DROPS" ]; then
        printf 'KVS-PLAN >f+++++++++ 5 gone/one.jpg\nKVS-PLAN >f+++++++++ 5 gone/two.jpg\n'
        echo 'rsync: connection unexpectedly closed (0 bytes received so far) [Receiver]' >&2
        exit "$REPLAN_STATUS"
    fi
fi
exec "$REAL_RSYNC" "$@"
EOF
    chmod +x "$bin/rsync"
    (
        export REAL_RSYNC REPLAN_BIN="$bin" IMPORT_TRANSFER_RETRY_PAUSE=0 IMPORT_TRANSFER_JOBS=4
        REAL_RSYNC=$(command -v rsync)
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/replan-ctl" import_ssh_setup old.example.com 22 root "" yes
        IMPORT_REMOTE_SUDO=no
        : > "$bin/scans"
        REPLAN_DROPS=1 REPLAN_STATUS=255 import_remote_files "$site" "$destination" yes > "$TMP_ROOT/replan.out" 2>&1 || exit 1
        [ "$(wc -l < "$bin/scans")" -eq 2 ] || exit 2
        grep -q '^  The planning scan lost its connection to the old server (rsync status 255); attempt 2 of 9 in 0 s\.$' "$TMP_ROOT/replan.out" || exit 3
        grep -q 'connection unexpectedly closed' "$TMP_ROOT/replan.out" || exit 4
        diff -r "$site" "$destination" || exit 5
        # Everything is here now: nothing of the lost scan may be copied.
        : > "$bin/scans"
        REPLAN_DROPS=1 REPLAN_STATUS=12 import_remote_files "$site" "$destination" yes > "$TMP_ROOT/replan.out" 2>&1 || exit 6
        grep -q '^  To transfer:     nothing' "$TMP_ROOT/replan.out" || exit 7
        grep -q 'Transferring' "$TMP_ROOT/replan.out" && exit 8
        # A scan that keeps failing stops the import before a file is copied.
        rm -rf "$destination"
        : > "$bin/scans"
        status=0
        REPLAN_DROPS=99 REPLAN_STATUS=12 IMPORT_TRANSFER_RETRIES=2 import_remote_files "$site" "$destination" yes > "$TMP_ROOT/replan.out" 2>&1 || status=$?
        [ "$status" -eq 12 ] || exit 9
        [ "$(wc -l < "$bin/scans")" -eq 3 ] || exit 10
        grep -q '^ERROR: parallel transfer planning failed (status 12) after 3 attempts; no partial plan or final mirror was started$' "$TMP_ROOT/replan.out" || exit 11
        [ -z "$(find "$destination" -type f)" ] || exit 12
        # Another status is no lost connection.
        : > "$bin/scans"
        status=0
        REPLAN_DROPS=1 REPLAN_STATUS=23 import_remote_files "$site" "$destination" yes > "$TMP_ROOT/replan.out" 2>&1 || status=$?
        [ "$status" -eq 23 ] && [ "$(wc -l < "$bin/scans")" -eq 1 ] || exit 13
        exit 0
    ) || fail "a planning scan that lost the old server must start again (case $?): $(tail -n 5 "$TMP_ROOT/replan.out")"
    pass "a lost connection starts the planning scan again"
}

# Workers take the chunks in turn: while one works on a long chunk, the
# other takes all the rest. The aggregate record adds the finished chunks
# to the progress of the running ones and never goes back.
test_progress_never_goes_back_across_chunks() {
    local bin="$TMP_ROOT/turns-bin" plan="$TMP_ROOT/turns-plan" control="$TMP_ROOT/turns-ctl" i j total=0 status=0 out

    mkdir -p "$bin" "$plan" "$control"
    for ((i = 1; i <= 7; i++)); do
        : > "$plan/$i.list"
        for ((j = 1; j <= i; j++)); do printf './f%s-%s\0' "$i" "$j" >> "$plan/$i.list"; done
        total=$((total + i))
    done
    # A stand-in for rsync: a record within each file (no file count) and
    # one at its end, 1000 bytes a file. The rsync of chunk 1 lasts until
    # chunk 7 has started, which the other worker reaches alone.
    cat > "$bin/rsync" <<'EOF'
#!/bin/bash
previous=""
for arg in "$@"; do
    case "$arg" in
        --files-from=*) list=${arg#--files-from=} ;;
    esac
    # The remote shell ends with the socket of the worker's master.
    [ "$previous" != -e ] || rsh=$arg
    previous=$arg
done
chunk=${list##*/}
chunk=${chunk%.list}
worker=${rsh##*/}
worker=${worker%\'}
printf '%s %s\n' "$chunk" "$worker" >> "$TURNS_BIN/turns"
touch "$TURNS_BIN/started-$chunk"
if [ "$chunk" = 1 ]; then
    for ((attempt = 0; attempt < 200; attempt++)); do
        [ ! -e "$TURNS_BIN/started-7" ] || break
        sleep 0.05
    done
fi
names=$(tr -cd '\0' < "$list" | wc -c)
for ((n = 1; n <= names; n++)); do
    printf ' %d 50%% 1.00MB/s 0:00:01\r' $(((n - 1) * 1000 + 500))
    sleep 0.2
    printf ' %d %d%% 1.00MB/s 0:00:01 (xfr#%d, to-chk=%d/%d)\r' $((n * 1000)) $((100 * n / names)) "$n" $((names - n)) "$names"
done
printf ' %d 100%% 1.00MB/s 0:00:02 (xfr#%d, to-chk=0/%d)\n' $((names * 1000)) "$names" "$names"
EOF
    chmod +x "$bin/rsync"
    out=$(TURNS_BIN="$bin" PATH="$bin:$PATH" IMPORT_RSYNC_CONTROL_DIR="$control" import_rsync_workers "$plan" 2 unused 2>/dev/null) || status=$?
    [ "$status" -eq 0 ] || fail "the chunks must be copied, status $status"
    [ "$(wc -l < "$bin/turns")" -eq 7 ] || fail "every chunk must run once: $(cat "$bin/turns")"
    awk '$1 == 1 && $2 != 1 { bad = 1 } $1 != 1 && $2 != 2 { bad = 1 } END { exit bad }' "$bin/turns" ||
        fail "worker 2 must take chunks 2 to 7 while worker 1 works on chunk 1: $(cat "$bin/turns")"
    printf '%s\n' "$out" | awk -v total="$total" '
        {
            if (!match($0, /^ [0-9]+ 0% 0\.00B\/s 0:00:00 \(xfr#[0-9]+\)$/)) { print "not a record: " $0; bad = 1; next }
            bytes = $1 + 0
            files = substr($NF, 6) + 0
            if (bytes < last_bytes || files < last_files) { print "back from " last_bytes "/" last_files " to " bytes "/" files; bad = 1 }
            last_bytes = bytes
            last_files = files
            records++
        }
        END {
            if (records < 4) { print "too few records: " records; bad = 1 }
            if (last_bytes != total * 1000 || last_files != total) { print "the last record is " last_bytes "/" last_files; bad = 1 }
            exit bad
        }
    ' > "$TMP_ROOT/turns.check" || fail "the aggregate progress must only grow up to the whole: $(cat "$TMP_ROOT/turns.check")"
    printf '%s\n' "$out" | import_rsync_progress $((total * 1000)) "$total" no > "$TMP_ROOT/turns.render"
    grep -q "^  Transferred $total files, 27 kB in " "$TMP_ROOT/turns.render" ||
        fail "the renderer must sum up every chunk: $(cat "$TMP_ROOT/turns.render")"
    pass "workers take the chunks in turn and the progress never goes back"
}

# With a password (sshpass), every new SSH connection authenticates, and
# many at once meet the MaxStartups limit of sshd. Each worker keeps a
# master connection of its own: it authenticates once, however many chunks
# it copies, and the masters are closed at the end.
test_a_password_run_authenticates_once_per_worker() {
    local bin="$TMP_ROOT/auth-bin" site="$TMP_ROOT/auth-site" i chunks

    make_fake_ssh "$bin"
    cat > "$bin/sshpass" <<EOF
#!/bin/bash
echo "sshpass \$1" >> "$bin/sshpass.log"
[ "\$1" != -e ] || shift
exec "\$@"
EOF
    chmod +x "$bin/sshpass"
    make_site "$site" "$site"
    mkdir -p "$site/contents/screens"
    for ((i = 0; i < 24; i++)); do printf 'screen %s\n' "$i" > "$site/contents/screens/$i.jpg"; done
    (
        PATH="$bin:$PATH"
        IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/auth-ctl" import_ssh_setup old.example.com 22 root "" no no "s3cret" || exit 1
        IMPORT_REMOTE_SUDO=no
        IMPORT_TRANSFER_CHUNK=3 IMPORT_TRANSFER_JOBS=2 import_remote_files "$site" "$TMP_ROOT/auth-dest" yes > "$TMP_ROOT/auth.out" 2>&1 || exit 2
        diff -r "$site" "$TMP_ROOT/auth-dest" > /dev/null || exit 3
        grep -q '2 workers on separate SSH connections' "$TMP_ROOT/auth.out" || exit 4
        chunks=$(sed -n 's/^  Transferring \([0-9]*\) chunks .*/\1/p' "$TMP_ROOT/auth.out")
        [ "${chunks:-0}" -gt 4 ] || exit 5
        # Two masters, each authenticated once; every chunk but the first
        # of worker 2 went over an open one (worker 1 took over the
        # connection that tested the password).
        [ "$(grep -c "^auth $TMP_ROOT/auth-ctl/xfer\.[A-Za-z0-9]*/[12]$" "$bin/ssh.log")" -eq 2 ] || exit 6
        [ "$(grep "^auth $TMP_ROOT/auth-ctl/xfer\." "$bin/ssh.log" | sort -u | wc -l)" -eq 2 ] || exit 7
        [ "$(grep -c "^mux $TMP_ROOT/auth-ctl/xfer\.[A-Za-z0-9]*/[12]$" "$bin/ssh.log")" -eq $((chunks - 1)) ] || exit 8
        grep -q '^auth none$' "$bin/ssh.log" && exit 9
        [ "$(grep -c "^closed $TMP_ROOT/auth-ctl/xfer\.[A-Za-z0-9]*/[12]$" "$bin/ssh.log")" -eq 2 ] || exit 10
        [ -z "$(find "$TMP_ROOT/auth-ctl" -name 'xfer.*')" ] || exit 11
        grep -q 'opt BatchMode=yes' "$bin/ssh.log" && exit 12
        [ "$(grep -c '^sshpass -e$' "$bin/sshpass.log")" -gt "$chunks" ] || exit 13
        exit 0
    ) || fail "a password run must authenticate once per worker and close the masters (case $?): $(grep -E '^(auth|mux|closed) ' "$bin/ssh.log" | sort | uniq -c)"
    pass "a password run authenticates once per worker"
}

# Ctrl-C while the workers are on a later chunk: the rsync of every worker
# stops with its children, the SSH masters of the workers close, and the
# chunk lists leave the old server.
test_interruption_during_a_later_chunk_leaves_nothing_behind() {
    local bin="$TMP_ROOT/later-bin" site="$TMP_ROOT/later-site" remote_tmp="$TMP_ROOT/later-remote-tmp"
    local i leader start elapsed pid

    make_fake_ssh "$bin"
    make_site "$site" "$site"
    mkdir -p "$site/contents/screens" "$remote_tmp"
    for ((i = 0; i < 24; i++)); do printf 'screen %s\n' "$i" > "$site/contents/screens/$i.jpg"; done
    # The rsync of chunk 5 hangs with a child, as a long transfer does.
    cat > "$bin/rsync" <<'EOF'
#!/bin/bash
chunk=""
for arg in "$@"; do
    case "$arg" in
        --files-from=*) chunk=${arg##*/}; chunk=${chunk%.list} ;;
    esac
done
if [ "$chunk" = 5 ]; then
    echo "$$" >> "$LATER_BIN/pids"
    sleep 60 &
    echo "$!" >> "$LATER_BIN/pids"
    touch "$LATER_BIN/hung"
    wait
fi
exec "$REAL_RSYNC" "$@"
EOF
    chmod +x "$bin/rsync"
    cat > "$TMP_ROOT/later-run.sh" <<EOF
#!/bin/bash
source "$REPO_ROOT/docker/lib/import.sh"
export REAL_RSYNC="$(command -v rsync)" LATER_BIN="$bin" TMPDIR="$remote_tmp"
PATH="$bin:\$PATH"
IMPORT_SSH_CONTROL_DIR="$TMP_ROOT/later-ctl" import_ssh_setup old.example.com 22 root "" yes
IMPORT_REMOTE_SUDO=no
IMPORT_TRANSFER_CHUNK=3 IMPORT_TRANSFER_JOBS=2 import_remote_files "$site" "$TMP_ROOT/later-dest" yes
EOF
    # A job started from a terminal: its own session, SIGINT not ignored.
    setsid env --default-signal=INT,QUIT bash "$TMP_ROOT/later-run.sh" > "$TMP_ROOT/later.out" 2>&1 &
    leader=$!
    start=$SECONDS
    while [ ! -e "$bin/hung" ] && kill -0 "$leader" 2>/dev/null && [ $((SECONDS - start)) -lt 30 ]; do sleep 0.1; done
    if [ ! -e "$bin/hung" ]; then
        kill -KILL -- "-$leader" 2>/dev/null || true
        wait "$leader" 2>/dev/null || true
        fail "the transfer never reached chunk 5: $(tail -n 5 "$TMP_ROOT/later.out")"
    fi
    grep -q "^  Chunk lists copied to $remote_tmp/kvs-import-plan\." "$TMP_ROOT/later.out" ||
        fail "the chunk lists must be on the old server during the transfer: $(cat "$TMP_ROOT/later.out")"
    kill -INT -- "-$leader"
    start=$SECONDS
    while kill -0 "$leader" 2>/dev/null && [ $((SECONDS - start)) -lt 20 ]; do sleep 0.2; done
    elapsed=$((SECONDS - start))
    kill -KILL -- "-$leader" 2>/dev/null || true
    wait "$leader" 2>/dev/null || true
    [ "$elapsed" -le 5 ] || fail "Ctrl-C during chunk 5 waited $elapsed s"
    while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            [ "$(ps -o stat= -p "$pid" | cut -c1)" = Z ] || fail "the rsync of chunk 5 or its child $pid survived Ctrl-C"
        fi
    done < "$bin/pids"
    pgrep -f -- "$site/" > /dev/null && fail "an rsync of the transfer survived Ctrl-C: $(pgrep -af -- "$site/")"
    [ -z "$(ls -A "$remote_tmp")" ] || fail "the chunk lists or the work files stayed behind: $(ls -A "$remote_tmp")"
    [ "$(grep -c "^closed $TMP_ROOT/later-ctl/xfer\.[A-Za-z0-9]*/[12]$" "$bin/ssh.log")" -eq 2 ] ||
        fail "the SSH masters of the two workers must close: $(grep -E '^(auth|closed) ' "$bin/ssh.log")"
    [ -z "$(find "$TMP_ROOT/later-ctl" -name 'xfer.*')" ] || fail "the socket directory of the workers must go"
    grep -q 'Checking the whole site' "$TMP_ROOT/later.out" && fail "the final mirror must not start after Ctrl-C"
    pass "Ctrl-C during a later chunk stops everything and leaves nothing on the old server"
}

test_archive_names_map_to_kinds_tools_and_packages
test_only_the_missing_tool_is_installed
test_listings_are_normalized_for_every_archive_kind
test_analysis_finds_the_site_root_and_the_dump
test_analysis_refuses_what_would_pollute_the_webroot
test_peek_reads_the_config_before_extraction
test_extraction_settles_the_site_and_takes_the_dump_out
test_settle_rejects_linked_import_materials
test_settle_preserves_complete_entry_names
test_nested_stage_preserves_site_entries
test_stage_directory_follows_the_destination_filesystem
test_destination_marker_allows_a_repeat_of_the_same_source_only
test_take_over_moves_the_files_of_an_earlier_import
test_url_domain_and_key_value_helpers
test_external_search_plugin_is_recognized
test_ssh_setup_validates_and_builds_the_options
test_a_password_reaches_ssh_through_sshpass
test_the_old_nginx_configuration_is_saved_and_its_rewrites_recovered
test_the_rewrite_recovery_follows_the_includes_of_the_server_block
test_the_transfer_is_counted_first_and_shown_against_the_count
test_remote_detect_dump_and_files_go_through_one_ssh
test_excluded_names_are_literal_and_special_files_never_arrive
test_a_user_with_sudo_runs_the_remote_side_through_it
test_password_protected_archives_are_refused_with_a_reason
test_links_leaving_the_site_are_listed_and_the_copy_follows_them
test_links_leading_out_are_confirmed_before_the_copy
test_the_links_found_after_the_copy_are_compared_with_the_list_shown
test_links_are_searched_again_after_the_copy_of_a_directory
test_links_are_searched_again_after_the_transfer
test_the_copy_without_rsync_installs_it_for_a_special_file
test_the_copy_of_a_directory_is_followed_by_the_search_again
test_the_tar_stream_reports_what_the_old_server_could_not_read
test_parallel_transfers_preserve_the_mirror
test_hard_links_arrive_as_links
test_a_later_pass_keeps_the_owner_and_modes_the_init_set
test_parallel_workers_read_their_lists_on_the_old_server
test_chunk_lists_stay_off_an_old_server_short_of_room
test_the_transfer_stops_when_what_is_left_does_not_fit
test_ipv6_address_of_the_old_server
test_interrupt_stops_the_planning_scan
test_parallel_interruption_stops_the_process_groups
test_the_plan_cuts_the_scan_into_bounded_chunks
test_relayed_lists_are_cut_short_in_order
test_every_rsync_copies_one_chunk_at_most
test_progress_never_goes_back_across_chunks
test_a_lost_connection_starts_the_chunk_again
test_a_lost_connection_starts_the_planning_scan_again
test_a_password_run_authenticates_once_per_worker
test_interruption_during_a_later_chunk_leaves_nothing_behind

echo "All $TESTS_RUN import source tests passed."
