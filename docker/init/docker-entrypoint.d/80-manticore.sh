#!/bin/bash
set -e

# Configure Manticore Search (if enabled)
# shellcheck disable=SC1091
source /init/lib/common.sh

PLUGIN_DATA_DIR="$KVS_PATH/admin/data/plugins/external_search"
# The search scripts only talk to searchd, so they live outside the KVS
# tree, in the manticore-api volume that nginx, php-fpm and this container
# share: the KVS audit plugin reports every file or directory it does not
# know inside the site as suspicious.
SCRIPT_DIR="${MANTICORE_API_DIR:-/var/www/manticore-api}"

# Copies that earlier versions of this script left inside the site.
remove_legacy_scripts() {
    local kind legacy

    for kind in videos albums searches; do
        for legacy in "$KVS_PATH/kvs_manticore_search_${kind}.php" "$KVS_PATH/admin/manticore/kvs_manticore_search_${kind}.php"; do
            if [ -e "$legacy" ]; then
                rm -f "$legacy"
                log_info "Removed ${legacy#"$KVS_PATH/"} from the site (the scripts live in $SCRIPT_DIR)"
            fi
        done
    done
    rmdir "$KVS_PATH/admin/manticore" 2>/dev/null || true
}

# Skip if Manticore is not enabled
if [ "${ENABLE_MANTICORE:-false}" != "true" ]; then
    rm -f \
        "$SCRIPT_DIR/kvs_manticore_search_videos.php" \
        "$SCRIPT_DIR/kvs_manticore_search_albums.php" \
        "$SCRIPT_DIR/kvs_manticore_search_searches.php" \
        "$PLUGIN_DATA_DIR/data.dat"
    remove_legacy_scripts
    log_info "Manticore disabled; removed generated API scripts and plugin configuration"
    exit 0
fi

DOMAIN_SAFE=$(get_safe_domain)
log_info "Configuring Manticore Search..."
log_info "Index prefix: ${DOMAIN_SAFE}"

# Download and configure Manticore PHP files
log_info "Downloading Manticore search scripts..."
work=$(mktemp -d /tmp/kvs-manticore.XXXXXX)
plugin_temp=""
trap 'rm -rf -- "$work"; [ -z "$plugin_temp" ] || rm -f -- "$plugin_temp"' EXIT
curl --connect-timeout 15 --max-time 300 -fsSL https://kernel-scripts.com/files/manticore.zip -o "$work/manticore.zip"
unzip -q -o "$work/manticore.zip" -d "$work/"
# A failed or incomplete download must leave the existing search configured.
for kind in videos albums searches; do
    [ -s "$work/kvs_manticore_search_${kind}.php" ] || {
        log_error "Missing Manticore $kind script in the downloaded archive"
        exit 1
    }
done

# Update host and index names in PHP files
for file in "$work"/kvs_manticore_search_*.php; do
    [ -f "$file" ] || continue

    sed -i "s/\$manticore_host = '127.0.0.1'/\$manticore_host = 'searchd'/" "$file"

    if [[ "$file" == *"videos"* ]]; then
        sed -i "s/\$manticore_index = 'projectname_videos'/\$manticore_index = '${DOMAIN_SAFE}_videos'/" "$file"
    elif [[ "$file" == *"albums"* ]]; then
        sed -i "s/\$manticore_index = 'projectname_albums'/\$manticore_index = '${DOMAIN_SAFE}_albums'/" "$file"
    elif [[ "$file" == *"searches"* ]]; then
        sed -i "s/\$manticore_index = 'projectname_searches'/\$manticore_index = '${DOMAIN_SAFE}_searches'/" "$file"
    fi

    # Manticore identifiers that start with a digit must be quoted. Domains
    # may legally start with a digit, so quote the generated index variable in
    # every downloaded query rather than changing existing index names.
    # shellcheck disable=SC2016
    sed -E -i 's/(from[[:space:]]+)\$manticore_index/\1`$manticore_index`/Ig' "$file"

    # Fix error handling to return XML instead of fatal error
    sed -i "s/header('Content-type: text\/plain/header('Content-type: text\/xml/" "$file"
    sed -i "s/http_response_code(503);/\/\/ Return empty XML on error/" "$file"
    sed -E -i "s|^[[:space:]]*die\\(.*FATAL.*$|    die('<search_feed total_count=\"0\" from=\"0\" query=\"\"></search_feed>');|" "$file"

    php -l "$file" >/dev/null
done
mkdir -p "$SCRIPT_DIR"
cp "$work"/kvs_manticore_search_*.php "$SCRIPT_DIR/"
remove_legacy_scripts

log_info "Manticore PHP scripts installed in $SCRIPT_DIR"

# Configure External Search plugin automatically
log_info "Configuring External Search plugin..."
PROJECT_URL=$(get_project_url)
mkdir -p "$PLUGIN_DATA_DIR"

# Create plugin configuration using PHP serialized format. The values follow
# the hints the plugin form gives for Manticore: use the external search
# always (1) and let it completely replace the internal search (0); any
# other display mode adds the internal results and shows every hit twice.
# The internal fallback stays at its default, so KVS still answers with its
# own search while Manticore is down.
plugin_temp=$(mktemp "$PLUGIN_DATA_DIR/.data.dat.XXXXXX")
cat > "$work/configure_external_search.php" << 'EOPHP'
<?php
$plugin_data = array(
    'enable_external_search' => 1,
    'display_results' => 0,
    'api_call' => 'http://manticore-api:8080/kvs_manticore_search_videos.php?query=%QUERY%&limit=%LIMIT%&from=%FROM%',
    'outgoing_url' => getenv('PROJECT_URL'),

    'enable_external_search_albums' => 1,
    'display_results_albums' => 0,
    'api_call_albums' => 'http://manticore-api:8080/kvs_manticore_search_albums.php?query=%QUERY%&limit=%LIMIT%&from=%FROM%',
    'outgoing_url_albums' => getenv('PROJECT_URL'),

    'enable_external_search_searches' => 1,
    'display_results_searches' => 0,
    'api_call_searches' => 'http://manticore-api:8080/kvs_manticore_search_searches.php?query=%QUERY%&limit=%LIMIT%&from=%FROM%',
    'outgoing_url_searches' => getenv('PROJECT_URL')
);

$payload = serialize($plugin_data);
if (file_put_contents(getenv('PLUGIN_DATA_FILE'), $payload, LOCK_EX) !== strlen($payload)) exit(1);
echo "External Search plugin configured\n";
EOPHP

DOMAIN="$DOMAIN" PROJECT_URL="$PROJECT_URL" PLUGIN_DATA_FILE="$plugin_temp" \
    php "$work/configure_external_search.php"
chown -R 1000:1000 "$PLUGIN_DATA_DIR"
chmod 600 "$plugin_temp"
mv -f "$plugin_temp" "$PLUGIN_DATA_DIR/data.dat"
plugin_temp=""

log_info "External Search plugin configured:"
log_info "  - Videos: http://manticore-api:8080/kvs_manticore_search_videos.php"
log_info "  - Albums: http://manticore-api:8080/kvs_manticore_search_albums.php"
log_info "  - Searches: http://manticore-api:8080/kvs_manticore_search_searches.php"
log_info "Indexes are updated hourly via cron."
