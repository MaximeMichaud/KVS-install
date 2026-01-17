#!/bin/bash
set -e

# KVS Docker Initialization - Orchestrator
# This script runs all initialization modules in docker-entrypoint.d/

echo "=== KVS Docker Initialization ==="
echo ""

# Source common functions
# shellcheck disable=SC1091
source /init/lib/common.sh

# Validate required environment variables
if [ -z "$DOMAIN" ]; then
    log_error "DOMAIN environment variable is required"
    exit 1
fi

if [ -z "$MARIADB_PASSWORD" ]; then
    log_error "MARIADB_PASSWORD environment variable is required"
    exit 1
fi

log_info "Domain: $DOMAIN"
log_info "USE_WWW: ${USE_WWW:-false}"
log_info "SSL_PROVIDER: ${SSL_PROVIDER:-letsencrypt}"
log_info "ENABLE_MANTICORE: ${ENABLE_MANTICORE:-false}"
echo ""

# Track execution
SCRIPTS_RUN=0
SCRIPTS_FAILED=0

# Run all scripts in docker-entrypoint.d/ in order
for script in /init/docker-entrypoint.d/*.sh; do
    [ -f "$script" ] || continue

    script_name=$(basename "$script")
    log_step "Running $script_name"

    if bash "$script"; then
        SCRIPTS_RUN=$((SCRIPTS_RUN + 1))
        log_info "$script_name completed"
    else
        SCRIPTS_FAILED=$((SCRIPTS_FAILED + 1))
        log_error "$script_name failed"
        exit 1
    fi
done

echo ""
echo "=== KVS Initialization Complete ==="
log_info "Scripts executed: $SCRIPTS_RUN"

if [ "$SCRIPTS_FAILED" -gt 0 ]; then
    log_error "Scripts failed: $SCRIPTS_FAILED"
    exit 1
fi
