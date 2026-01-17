#!/bin/bash
# Configure KVS system settings (GeoIP, nginx, memory limits)
# shellcheck disable=SC1091
source /init/lib/common.sh

# Configure GeoIP database if available
GEOIP_DB=""
if [ -f "/usr/share/geoip/GeoLite2-City.mmdb" ]; then
    GEOIP_DB="/usr/share/geoip/GeoLite2-City.mmdb"
    log_info "Found GeoIP City database"
elif [ -f "/usr/share/geoip/GeoLite2-Country.mmdb" ]; then
    GEOIP_DB="/usr/share/geoip/GeoLite2-Country.mmdb"
    log_info "Found GeoIP Country database"
fi

if [ -z "$GEOIP_DB" ]; then
    log_info "No GeoIP database found in /usr/share/geoip/"
    log_info "To enable: copy GeoLite2-Country.mmdb to docker/geoip/"
fi

# Optimize system settings for nginx and Docker environment
log_info "Configuring system settings..."

if SQL_OUTPUT=$(mariadb -h mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" "$DOMAIN" 2>&1 <<-EOSQL
	INSERT INTO ktvs_settings (section, satellite_prefix, value, added_date, version_control)
	VALUES (
		'system',
		'',
		JSON_OBJECT(
			'server_type', 'nginx',
			'cpu_priority', '0',
			'timezone', 'UTC',
			'memory_limit_default', 256,
			'memory_limit_admin', 512,
			'memory_limit_background', 1024,
			'file_upload_disk', 'members',
			'file_upload_url', 'admins',
			'default_timeout', 20,
			'download_timeout', 1800,
			'geoip_info', '',
			'geoip_database', '$GEOIP_DB',
			'file_upload_max_size', 2048,
			'file_download_speed_limit', 0,
			'custom_user_agent', '',
			'custom_ip', '',
			'enable_debug_get_file', false,
			'enable_debug_get_image', false
		),
		NOW(),
		1
	)
	ON DUPLICATE KEY UPDATE
		value = JSON_SET(
			value,
			'$.server_type', 'nginx',
			'$.memory_limit_default', 256,
			'$.file_upload_max_size', 2048,
			'$.geoip_database', '$GEOIP_DB'
		),
		version_control = version_control + 1;
	EOSQL
); then
    log_info "System settings optimized:"
    log_info "  - Server type: nginx"
    log_info "  - Memory limit: 256 MB"
    log_info "  - Upload limit: 2048 MB"
    [ -n "$GEOIP_DB" ] && log_info "  - GeoIP: $GEOIP_DB"
else
    log_warn "Failed to update system settings: $SQL_OUTPUT"
fi
