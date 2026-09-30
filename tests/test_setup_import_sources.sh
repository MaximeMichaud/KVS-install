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
TMP_ROOT=$(mktemp -d /tmp/kvs-import-sources-test.XXXXXX)
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
        [ "$(import_inspect_dump "$staging/database.sql.zst" ktvs_)" = $'1\t7.0.2\t0\tyes' ] || fail "$archive: the staged dump must be intact"
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

test_stage_directory_follows_the_destination_filesystem() {
    local destination="$TMP_ROOT/stage-dest"

    [ "$(import_stage_dir_for "$destination")" = "$TMP_ROOT/.kvs-import-stage-dest" ] || fail "an absent destination stages next to itself"
    mkdir -p "$destination"
    [ "$(import_stage_dir_for "$destination")" = "$TMP_ROOT/.kvs-import-stage-dest" ] || fail "a destination on the same filesystem stages next to itself"
    ln -s "$destination" "$TMP_ROOT/stage-link"
    [ "$(import_stage_dir_for "$TMP_ROOT/stage-link")" = "$TMP_ROOT/.kvs-import-stage-dest" ] || fail "a symlinked destination stages next to its target"
    (
        # shellcheck disable=SC2329  # Stub consumed by the function under test.
        stat() { if [ "$4" = "$destination" ]; then echo 99; else echo 1; fi; }
        [ "$(import_stage_dir_for "$destination")" = "$destination/.kvs-import-stage" ]
    ) || fail "a destination that is a mount point stages inside itself"
    pass "stage directory follows the destination filesystem"
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

test_the_transfer_is_counted_first_and_shown_against_the_count() {
    local stats out status

    stats=$'\nNumber of files: 3,012 (reg: 3,008, dir: 4)\nNumber of created files: 3,011 (reg: 3,008, dir: 3)\nNumber of deleted files: 0\nNumber of regular files transferred: 3,008\nTotal file size: 38,000,000 bytes\nTotal transferred file size: 38,000,000 bytes\nLiteral data: 0 bytes\n'
    [ "$(import_rsync_stats_totals <<< "$stats")" = $'3008\t38000000\t3008\t38000000' ] ||
        fail "the statistics of the dry run give the files and bytes to transfer and the site's: $(import_rsync_stats_totals <<< "$stats")"
    [ "$(printf 'Number of files transferred: 12\nTotal transferred file size: 3400 bytes\n' | import_rsync_stats_totals)" = $'12\t3400\t0\t0' ] ||
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
    out=$(printf '\r              0   0%%    0.00kB/s    0:00:00 (xfr#0, ir-chk=1000/3012)\r        4000000  10%%    4.03MB/s    0:00:00 (xfr#1, ir-chk=1007/3012)\rskipping non-regular file "x"\n       32042000  84%%    3.91MB/s    0:00:07 (xfr#2029, ir-chk=979/3012)\r       38000000 100%%    3.90MB/s    0:00:09 (xfr#3008, to-chk=0/3012)\n' |
        import_rsync_progress 38000000 3008 no)
    grep -q '^  0 B of 36.2 MB (0%), 0 of 3,008 files, ? left, Copy: 0 B/s, 0 files/s; check: ? entries/s, 2,012 of 3,012 discovered entries checked, scan running, 0:00:00 elapsed$' <<< "$out" ||
        fail "the first record is shown against the totals, the scan counted: $out"
    grep -q '^skipping non-regular file "x"$' <<< "$out" || fail "what else rsync prints passes through: $out"
    grep -q '^  Transferred 3,008 files, 36.2 MB in 0:00:0[0-9] (.* files/s); 3,012 entries checked$' <<< "$out" || fail "the end is summed up: $out"
    # Without totals the counts show alone, the scan still counted.
    out=$(printf '       38000000 100%%    3.90MB/s    0:00:09 (xfr#3008, to-chk=0/3012)\n' | import_rsync_progress 0 0 no)
    grep -q '^  36.2 MB, 3,008 files, Copy: .* files/s; check: .* entries/s, 3,012 of 3,012 discovered entries checked, scan done, 0:00:0[0-9] elapsed$' <<< "$out" ||
        fail "without totals the counts show alone: $out"
    # Without a scan figure (a record inside a file) the rates and the
    # time stand alone.
    out=$(printf '       32768   0%%    0.00kB/s    0:00:00  \n' | import_rsync_progress 0 0 no)
    grep -q '^  32 kB, 0 files, Copy: 0 B/s, 0 files/s, 0:00:0[0-9] elapsed$' <<< "$out" || fail "a record without a scan figure: $out"
    # On a terminal two lines are rewritten in place (cursor up one line)
    # and the end replaces them with its summary.
    out=$(printf '       38000000 100%%    3.90MB/s    0:00:09 (xfr#3008, to-chk=0/3012)\n' | import_rsync_progress 38000000 3008 yes | tr '\r\033' '|^')
    [[ "$out" == "  36.2 MB of 36.2 MB (100%), 3,008 of 3,008 files, ? left^[K"$'\n'"  "*"entries checked, scan done, 0:00:0"?" elapsed^[K|^[1A  Transferred 3,008 files"*"^[K"$'\n'"^[K" ]] ||
        fail "on a terminal the two lines are rewritten in place: $out"
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
        [ "$(import_inspect_dump "$TMP_ROOT/remote.sql.gz" ktvs_)" = $'1\t\t0\tyes' ] || exit 11

        import_remote_files "$site" "$destination" yes > "$TMP_ROOT/transfer-out.txt" 2>&1 || exit 12
        grep -Eq '^  To transfer:     [0-9,]+ files, [0-9.]+ [kMGT]B of the site'"'"'s [0-9,]+ files, [0-9.]+ [kMGT]B$' "$TMP_ROOT/transfer-out.txt" || exit 41
        grep -Eq '^  Transferred [0-9,]+ files, [0-9.]+ [kMGT]?B in [0-9]+:[0-9]{2}:[0-9]{2} ' "$TMP_ROOT/transfer-out.txt" || exit 42
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
        grep -q '^command tar -C ' "$bin/ssh.log" || exit 21
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
        grep -q "^command tar -C $site '--exclude=./tmp/\*' '--exclude=./backup' '--exclude=./.well-known' '--exclude=./contents/videos_sources' -chf - .\$" "$bin/ssh.log" || exit 57
        import_remote_files "$site" "$destination" no 'backup' 2>/dev/null && exit 58
        rm -rf "$site/tmp" "$site/backup" "$site/.well-known" "$site/contents/videos_sources"

        import_ssh_close
        grep -q '^control exit$' "$bin/ssh.log" || exit 22
        exit 0
    ) || fail "remote detect, dump and files must go through the ssh plumbing (case $?)"
    pass "remote detect, dump and files go through one ssh connection"
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
        grep -q '^command sudo -n tar -C ' "$bin/ssh.log" || exit 14
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
    local site="$TMP_ROOT/linked-site" store="$TMP_ROOT/linked-store" destination="$TMP_ROOT/linked-dest" listed

    make_site "$site" /home/old/www
    mkdir -p "$store"
    echo "stored" > "$store/big.mp4"
    ln -s "$store" "$site/contents/store"
    ln -s 1.mp4 "$site/contents/videos/2.mp4"
    ln -s videos "$site/contents/inside"
    ln -s /nowhere/at/all "$site/contents/gone"
    listed=$(import_external_links "$site" | sort)
    [ "$listed" = "$(printf 'contents/gone -> /nowhere/at/all (dangling)\ncontents/store -> %s' "$store")" ] ||
        fail "the links leaving the site and the dangling ones must be listed, not the ones inside (got: $listed)"
    [ -z "$(import_external_links "$TMP_ROOT/layout-locked" 2>/dev/null)" ] || fail "a site without links lists nothing"

    rm -f "$site/contents/gone"
    (
        # shellcheck disable=SC2034  # Read by import_marker_file.
        IMPORT_MARKER_DIR="$TMP_ROOT/linked-markers"
        import_place_site "$site" "$destination" >/dev/null || exit 1
        [ -d "$destination/contents/store" ] && [ ! -L "$destination/contents/store" ] || exit 2
        [ "$(cat "$destination/contents/store/big.mp4")" = stored ] || exit 3
        [ -L "$destination/contents/inside" ] || exit 4
        [ -L "$destination/contents/videos/2.mp4" ] || exit 5
        exit 0
    ) || fail "the copy of a directory must bring the targets of the links leaving the site and keep the inside ones (case $?)"
    pass "links leaving the site are listed and the copy follows them"
}

# The tar stream is a pipeline, and setup.sh runs without pipefail: the
# status of the remote tar must be read from the pipeline itself, or the
# files it could not read are silently left behind.
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
            PARALLEL_PLAN_STATUS="$plan_status" PARALLEL_SHORT_PLAN=yes IMPORT_TRANSFER_JOBS=4 import_remote_files "$site" "$destination" yes '/tmp/*' '/backup' > "$TMP_ROOT/parallel-plan-fail.out" 2>&1 || status=$?
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

# rsync relays a --files-from list given on its side to the sender on the
# old server, a relay that grows with the square of the list: the workers
# of a site of ten million files copied nothing for hours. They read their
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
    [ "$status" -eq 143 ] || fail "interruption must return TERM, got $status"
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
test_a_user_with_sudo_runs_the_remote_side_through_it
test_password_protected_archives_are_refused_with_a_reason
test_links_leaving_the_site_are_listed_and_the_copy_follows_them
test_the_tar_stream_reports_what_the_old_server_could_not_read
test_parallel_transfers_preserve_the_mirror
test_hard_links_arrive_as_links
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
test_a_password_run_authenticates_once_per_worker
test_interruption_during_a_later_chunk_leaves_nothing_behind

echo "All $TESTS_RUN import source tests passed."
