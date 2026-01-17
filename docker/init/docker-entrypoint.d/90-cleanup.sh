#!/bin/bash
# Clean up installation files
# shellcheck disable=SC1091
source /init/lib/common.sh

# Clean up installation files (done last, after all other scripts)
if [ -d "$KVS_PATH/_INSTALL" ]; then
    rm -rf "$KVS_PATH/_INSTALL"
    log_info "Installation files cleaned up"
else
    log_info "No installation files to clean up"
fi
