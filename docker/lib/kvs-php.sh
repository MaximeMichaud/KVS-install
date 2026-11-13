#!/bin/bash
# The PHP runtime a KVS release needs, for the scripts that create a site from
# an archive without setup.sh: the multi-site add. Sourced, never run. The
# rules are the ones setup.sh applies to the primary site
# (kvs_documented_php_version, detect_ioncube, import_site_ioncube), and
# tests/test_multisite_manager_hardening.sh checks that both agree, within
# the 4 KiB of a PHP file the import reads (see kvs_archive_ioncube).

# kvs_php_series <major.minor.patch>
# The PHP series Kernel Team documents for a KVS release: 7.4 for 6.2.0 and
# older, 8.1 for 6.2.1 through 7.0.2, and 8.3 for 7.0.3 and newer, whose
# archives can target the PHP 8.2 Encoder that PHP 8.1 cannot load. Fails on
# anything but three numbers.
kvs_php_series() {
    local major minor patch

    [[ "${1:-}" =~ ^([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})$ ]] || return 1
    major=$((10#${BASH_REMATCH[1]}))
    minor=$((10#${BASH_REMATCH[2]}))
    patch=$((10#${BASH_REMATCH[3]}))

    if [ "$major" -lt 6 ] ||
        { [ "$major" -eq 6 ] && [ "$minor" -lt 2 ]; } ||
        { [ "$major" -eq 6 ] && [ "$minor" -eq 2 ] && [ "$patch" -eq 0 ]; }; then
        printf '7.4\n'
    elif [ "$major" -gt 7 ] ||
        { [ "$major" -eq 7 ] && { [ "$minor" -gt 0 ] || [ "$patch" -ge 3 ]; }; }; then
        printf '8.3\n'
    else
        printf '8.1\n'
    fi
}

# kvs_archive_version <archive>
# The KVS release an archive's name carries (KVS_7.0.3_[example.com].zip
# gives 7.0.3). Fails when the name holds none.
kvs_archive_version() {
    local name="${1##*/}"

    [[ "$name" =~ KVS_([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# kvs_php_source_ioncube < file
# yes when the PHP source on standard input is IonCube encoded, no otherwise,
# from its first 4 KiB: the "<?php //<hex>" header the encoder writes, or the
# loader check every encoded file carries.
kvs_php_source_ioncube() {
    local head="" first=""

    IFS= read -r -N 4096 head || true
    first=${head%%$'\n'*}
    if [[ "$first" =~ ^[[:space:]]*\<\?php[[:space:]]+//[0-9a-f]{5,6} ]] ||
        [[ "$head" == *"extension_loaded('ionCube Loader')"* ]] ||
        [[ "$head" == *_il_exec* ]]; then
        printf 'yes\n'
    else
        printf 'no\n'
    fi
}

# kvs_archive_ioncube <archive>
# yes or no for the KVS files in a zip archive, read from the first of
# admin/include/functions_base.php (loaded first) and admin/index.php that
# unzip can extract, the order and the fallback of setup.sh's
# detect_ioncube. unzip -t answers 0 for a member that extracts, 11 for one
# that is missing and another status for one it cannot extract (a damaged
# archive, a compression method this unzip lacks). Only a member that
# extracts is read: what unzip -p prints for the others would look like
# plain PHP. Fails when neither member can be read, or unzip is missing.
# The member is read up to 4 KiB, as the import reads a site's file, where
# detect_ioncube reads all of it: a file whose only signature lies past its
# first 4 KiB is plain here and encoded for detect_ioncube. An encoded file
# starts with the encoder's header, inside that window.
kvs_archive_ioncube() {
    local archive="$1" member

    command -v unzip >/dev/null 2>&1 || return 1
    for member in admin/include/functions_base.php admin/index.php; do
        if unzip -tq "$archive" "$member" >/dev/null 2>&1; then
            unzip -p "$archive" "$member" 2>/dev/null | kvs_php_source_ioncube
            return 0
        fi
    done
    return 1
}

# kvs_site_version <site directory>
# The KVS release of a site in place, from the project_version of its
# admin/include/version.php, as setup.sh's kvs_documented_php_version reads
# it there (the import's import_read_kvs_version): the leading
# major.minor.patch. Fails when the file or a version is missing.
kvs_site_version() {
    local file="$1/admin/include/version.php" version

    [ -f "$file" ] && [ -r "$file" ] || return 1
    version=$(sed -n -E "s/^[[:space:]]*\\\$config\\[[[:space:]]*['\"]project_version['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/p" \
        "$file" | head -n 1)
    [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# kvs_site_ioncube <site directory>
# yes or no for a site in place, from its admin/include/functions_base.php,
# the file setup.sh's detect_ioncube reads there through the import's
# import_site_ioncube. Fails when the file cannot be read.
kvs_site_ioncube() {
    local file="$1/admin/include/functions_base.php"

    [ -f "$file" ] && [ -r "$file" ] || return 1
    kvs_php_source_ioncube < "$file"
}
