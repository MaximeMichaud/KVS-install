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

if [ -n "$GEOIP_DB" ]; then
    if SQL_OUTPUT=$(mariadb -h mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" "$DOMAIN" 2>&1 <<-EOSQL
		UPDATE ktvs_settings
		SET value = JSON_SET(value, '$.geoip_database', '$GEOIP_DB')
		WHERE section = 'system';
	EOSQL
    ); then
        log_info "GeoIP database configured: $GEOIP_DB"
    else
        log_warn "Failed to configure GeoIP: $SQL_OUTPUT"
    fi
else
    log_info "No GeoIP database found in /usr/share/geoip/"
    log_info "To enable: copy GeoLite2-Country.mmdb to docker/geoip/"
fi

# Optimize system settings for nginx and Docker environment
log_info "Configuring system settings..."
if SQL_OUTPUT=$(mariadb -h mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" "$DOMAIN" 2>&1 <<-EOSQL
	UPDATE ktvs_settings
	SET value = JSON_SET(
		value,
		'$.server_type', 'nginx',
		'$.memory_limit_default', 256,
		'$.file_upload_max_size', 2048
	)
	WHERE section = 'system';
EOSQL
); then
    log_info "System settings optimized:"
    log_info "  - Server type: nginx"
    log_info "  - Memory limit: 256 MB"
    log_info "  - Upload limit: 2048 MB"
else
    log_warn "Failed to update system settings: $SQL_OUTPUT"
fi
