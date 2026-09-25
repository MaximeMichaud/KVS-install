#!/bin/bash
# Import sources: archives (zip, 7z, tar) analysed, extracted and settled
# into the site directory, the tools installed on demand, and the SSH
# plumbing of the remote source run through a fake ssh that executes the
# remote command locally.
# shellcheck disable=SC2016  # Fixture content holds literal dollar signs.
# shellcheck disable=SC2030,SC2031  # PATH is changed inside subshells on purpose.
set -euo pipefail

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
# command locally with the same stdin and stdout.
make_fake_ssh() {
    local bin="$1"

    mkdir -p "$bin"
    cat > "$bin/ssh" <<EOF
#!/bin/bash
log="$bin/ssh.log"
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) echo "opt \$2" >> "\$log"; shift 2 ;;
        -p) echo "port \$2" >> "\$log"; shift 2 ;;
        -i) echo "key \$2" >> "\$log"; shift 2 ;;
        -l) echo "login \$2" >> "\$log"; shift 2 ;;
        -O) echo "control \$2" >> "\$log"; exit 0 ;;
        -*) echo "flag \$1" >> "\$log"; shift ;;
        *) break ;;
    esac
done
echo "target \$1" >> "\$log"
shift
echo "command \$*" >> "\$log"
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
    chmod +x "$bin/id" "$bin/sudo"
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

        import_remote_files "$site" "$destination" yes >/dev/null 2>&1 || exit 12
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
test_remote_detect_dump_and_files_go_through_one_ssh
test_a_user_with_sudo_runs_the_remote_side_through_it
test_password_protected_archives_are_refused_with_a_reason
test_links_leaving_the_site_are_listed_and_the_copy_follows_them
test_the_tar_stream_reports_what_the_old_server_could_not_read

echo "All $TESTS_RUN import source tests passed."
