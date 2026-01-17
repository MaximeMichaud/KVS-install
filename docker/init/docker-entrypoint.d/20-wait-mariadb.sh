#!/bin/bash
# Wait for MariaDB to be ready
# shellcheck disable=SC1091
source /init/lib/common.sh

log_info "Waiting for MariaDB..."

TRIES=0
MAX_TRIES=30

until db_is_ready; do
    TRIES=$((TRIES + 1))
    if [ $TRIES -ge $MAX_TRIES ]; then
        log_error "Cannot connect to MariaDB after 1 minute"
        log_error "Check credentials: DOMAIN=$DOMAIN"
        exit 1
    fi
    echo "  Waiting for MariaDB... ($TRIES/$MAX_TRIES)"
    sleep 2
done

log_info "MariaDB is ready"
