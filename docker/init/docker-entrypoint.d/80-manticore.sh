#!/bin/bash
# Configure Manticore Search (if enabled)
# shellcheck disable=SC1091
source /init/lib/common.sh

# Skip if Manticore is not enabled
if [ "${ENABLE_MANTICORE:-false}" != "true" ]; then
    log_info "Manticore not enabled, skipping"
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

    # Fix error handling to return XML instead of fatal error
    sed -i "s/header('Content-type: text\/plain/header('Content-type: text\/xml/" "$file"
    sed -i "s/http_response_code(503);/\/\/ Return empty XML on error/" "$file"
    sed -i "s/die('\[FATAL\].*');/die('<search_feed total_count=\"0\" from=\"0\" query=\"\"><\/search_feed>');/" "$file"

    cp "$file" "$KVS_PATH/"
done

log_info "Manticore PHP scripts installed"

# Configure External Search plugin automatically
log_info "Configuring External Search plugin..."
PLUGIN_DATA_DIR="$KVS_PATH/admin/data/plugins/external_search"
mkdir -p "$PLUGIN_DATA_DIR"

# Create plugin configuration using PHP serialized format
cat > /tmp/configure_external_search.php << 'EOPHP'
<?php
$plugin_data = array(
    'enable_external_search' => 1,
    'display_results' => 1,
    'api_call' => 'http://manticore-api/kvs_manticore_search_videos.php?query=%QUERY%&limit=%LIMIT%&from=%FROM%',
    'outgoing_url' => 'https://' . getenv('DOMAIN'),

    'enable_external_search_albums' => 1,
    'display_results_albums' => 1,
    'api_call_albums' => 'http://manticore-api/kvs_manticore_search_albums.php?query=%QUERY%&limit=%LIMIT%&from=%FROM%',
    'outgoing_url_albums' => 'https://' . getenv('DOMAIN'),

    'enable_external_search_searches' => 1,
    'display_results_searches' => 1,
    'api_call_searches' => 'http://manticore-api/kvs_manticore_search_searches.php?query=%QUERY%&limit=%LIMIT%&from=%FROM%',
    'outgoing_url_searches' => 'https://' . getenv('DOMAIN')
);

$plugin_data_dir = getenv('PLUGIN_DATA_DIR');
file_put_contents("$plugin_data_dir/data.dat", serialize($plugin_data), LOCK_EX);
echo "External Search plugin configured\n";
EOPHP

DOMAIN="$DOMAIN" PLUGIN_DATA_DIR="$PLUGIN_DATA_DIR" php /tmp/configure_external_search.php
chown -R 1000:1000 "$PLUGIN_DATA_DIR"
chmod 666 "$PLUGIN_DATA_DIR/data.dat"

log_info "External Search plugin configured:"
log_info "  - Videos: http://manticore-api/kvs_manticore_search_videos.php"
log_info "  - Albums: http://manticore-api/kvs_manticore_search_albums.php"
log_info "  - Searches: http://manticore-api/kvs_manticore_search_searches.php"
log_info "Indexes are updated hourly via cron."
