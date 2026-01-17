#!/bin/bash
# Extract KVS archive if not already installed
# shellcheck disable=SC1091
source /init/lib/common.sh

if kvs_is_installed; then
    log_info "KVS already installed, skipping extraction"
    exit 0
fi

log_info "Installing KVS..."

# Find KVS archive
KVS_ARCHIVE=$(find_kvs_archive)

if [ -z "$KVS_ARCHIVE" ]; then
    log_error "No KVS archive found in $KVS_ARCHIVE_DIR"
    log_error "Please mount your KVS_X.X.X_[domain].zip file to /kvs-archive"
    exit 1
fi

log_info "Found archive: $KVS_ARCHIVE"

# Extract KVS
mkdir -p "$KVS_PATH"
unzip -o "$KVS_ARCHIVE" -d "$KVS_PATH"

# Set initial permissions
chown -R 1000:1000 "$KVS_PATH"
chmod -R 755 "$KVS_PATH"

# Run KVS permission script (safe in Docker - isolated environment)
# Must run from _INSTALL directory since script does "cd .."
if [ -f "$KVS_PATH/_INSTALL/install_permissions.sh" ]; then
    log_info "Running KVS permission script..."
    (cd "$KVS_PATH/_INSTALL" && bash install_permissions.sh) || true
fi

log_info "KVS extracted successfully"
