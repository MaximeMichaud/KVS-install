#!/bin/bash
set -e

# Configure Manticore Search (if enabled)
# shellcheck disable=SC1091
source /init/lib/common.sh

PLUGIN_DATA_DIR="$KVS_PATH/admin/data/plugins/external_search"

# Skip if Manticore is not enabled
if [ "${ENABLE_MANTICORE:-false}" != "true" ]; then
    rm -f \
        "$KVS_PATH/kvs_manticore_search_videos.php" \
        "$KVS_PATH/kvs_manticore_search_albums.php" \
        "$KVS_PATH/kvs_manticore_search_searches.php" \
        "$PLUGIN_DATA_DIR/data.dat"
    log_info "Manticore disabled; removed generated API scripts and plugin configuration"
    exit 0
fi

DOMAIN_SAFE=$(get_safe_domain)
log_info "Configuring Manticore Search..."
log_info "Index prefix: ${DOMAIN_SAFE}"

# Download and configure Manticore PHP files
log_info "Downloading Manticore search scripts..."
curl -fsSL https://kernel-scripts.com/files/manticore.zip -o /tmp/manticore.zip
unzip -q -o /tmp/manticore.zip -d /tmp/

# Update host and index names in PHP files
for file in /tmp/kvs_manticore_search_*.php; do
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

    cp "$file" "$KVS_PATH/"
done

log_info "Manticore PHP scripts installed"

# Configure External Search plugin automatically
log_info "Configuring External Search plugin..."
PROJECT_URL=$(get_project_url)
mkdir -p "$PLUGIN_DATA_DIR"

# Create plugin configuration using PHP serialized format
cat > /tmp/configure_external_search.php << 'EOPHP'
<?php
$plugin_data = array(
    'enable_external_search' => 1,
    'display_results' => 1,
    'api_call' => 'http://manticore-api:8080/kvs_manticore_search_videos.php?query=%QUERY%&limit=%LIMIT%&from=%FROM%',
    'outgoing_url' => getenv('PROJECT_URL'),

    'enable_external_search_albums' => 1,
    'display_results_albums' => 1,
    'api_call_albums' => 'http://manticore-api:8080/kvs_manticore_search_albums.php?query=%QUERY%&limit=%LIMIT%&from=%FROM%',
    'outgoing_url_albums' => getenv('PROJECT_URL'),

    'enable_external_search_searches' => 1,
    'display_results_searches' => 1,
    'api_call_searches' => 'http://manticore-api:8080/kvs_manticore_search_searches.php?query=%QUERY%&limit=%LIMIT%&from=%FROM%',
    'outgoing_url_searches' => getenv('PROJECT_URL')
);

$plugin_data_dir = getenv('PLUGIN_DATA_DIR');
file_put_contents("$plugin_data_dir/data.dat", serialize($plugin_data), LOCK_EX);
echo "External Search plugin configured\n";
EOPHP

DOMAIN="$DOMAIN" PROJECT_URL="$PROJECT_URL" PLUGIN_DATA_DIR="$PLUGIN_DATA_DIR" \
    php /tmp/configure_external_search.php
chown -R 1000:1000 "$PLUGIN_DATA_DIR"
chmod 600 "$PLUGIN_DATA_DIR/data.dat"

log_info "External Search plugin configured:"
log_info "  - Videos: http://manticore-api:8080/kvs_manticore_search_videos.php"
log_info "  - Albums: http://manticore-api:8080/kvs_manticore_search_albums.php"
log_info "  - Searches: http://manticore-api:8080/kvs_manticore_search_searches.php"
log_info "Indexes are updated hourly via cron."
