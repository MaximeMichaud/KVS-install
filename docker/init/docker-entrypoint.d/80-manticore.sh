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

# Download and configure Manticore PHP files.
#
# The vendor serves one file with no version in its name, so two installs of
# the same stack release can get different plugin code. MANTICORE_PLUGIN_SHA256
# pins it: left empty the download is accepted and its sha256 is logged, which
# is how a release learns the value to record; set, a mismatch stops the init
# rather than installing code nobody reviewed.
MANTICORE_PLUGIN_URL="${MANTICORE_PLUGIN_URL:-https://kernel-scripts.com/files/manticore.zip}"
log_info "Downloading Manticore search scripts..."
curl -fsSL "$MANTICORE_PLUGIN_URL" -o /tmp/manticore.zip

PLUGIN_SHA256=$(sha256sum /tmp/manticore.zip | cut -d' ' -f1)
if [ -n "${MANTICORE_PLUGIN_SHA256:-}" ]; then
    if [ "$PLUGIN_SHA256" != "$MANTICORE_PLUGIN_SHA256" ]; then
        log_error "Manticore plugin checksum mismatch"
        log_error "  expected: $MANTICORE_PLUGIN_SHA256"
        log_error "  received: $PLUGIN_SHA256"
        log_error "  from:     $MANTICORE_PLUGIN_URL"
        rm -f /tmp/manticore.zip
        exit 1
    fi
    log_info "Manticore plugin checksum verified ($PLUGIN_SHA256)"
else
    log_info "Manticore plugin sha256: $PLUGIN_SHA256"
    log_info "Set MANTICORE_PLUGIN_SHA256 to refuse anything else."
fi

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

    mkdir -p "$SCRIPT_DIR"
    cp "$file" "$SCRIPT_DIR/"
done
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
cat > /tmp/configure_external_search.php << 'EOPHP'
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
