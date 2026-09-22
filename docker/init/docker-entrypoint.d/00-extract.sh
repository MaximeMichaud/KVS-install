#!/bin/bash
set -e

# Extract KVS archive if not already installed
# shellcheck disable=SC1091
source /init/lib/common.sh

EXTRACTION_COMPLETE_MARKER="$KVS_PATH/.kvs-extraction-complete"
EXTRACTION_IN_PROGRESS_MARKER="$KVS_PATH/.kvs-extraction-in-progress"
STAGING_DIR=""

cleanup_staging() {
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        rm -rf "$STAGING_DIR"
    fi
}

write_marker_atomically() {
    local destination="$1"
    local archive_name="$2"
    local archive_sha256="$3"
    local temporary_marker

    temporary_marker=$(mktemp "${destination}.tmp.XXXXXX")
    {
        printf 'archive=%s\n' "$archive_name"
        printf 'sha256=%s\n' "$archive_sha256"
    } > "$temporary_marker"
    chmod 644 "$temporary_marker"
    mv -f "$temporary_marker" "$destination"
}

trap cleanup_staging EXIT

mkdir -p "$KVS_PATH"
# Atomic marker writes can leave only their temporary file if the container is
# killed before mv. These files never represent installation state.
rm -f \
    "${EXTRACTION_COMPLETE_MARKER}.tmp."* \
    "${EXTRACTION_IN_PROGRESS_MARKER}.tmp."*

if [ -f "$EXTRACTION_COMPLETE_MARKER" ]; then
    if ! kvs_is_installed; then
        log_error "KVS extraction marker exists, but setup.php is missing"
        log_error "Refusing to overwrite an inconsistent site directory"
        exit 1
    fi

    rm -f "$EXTRACTION_IN_PROGRESS_MARKER"
    log_info "KVS extraction is complete, skipping extraction"
    exit 0
fi

# Installations created before the completion marker was introduced must be
# preserved. Without an in-progress marker, setup.php is treated as evidence
# of a pre-existing site rather than permission to overwrite it.
if kvs_is_installed && [ ! -f "$EXTRACTION_IN_PROGRESS_MARKER" ]; then
    log_info "Existing KVS installation found without an extraction marker, preserving it"
    exit 0
fi

# A non-empty unmarked directory may contain an older or manually managed
# site. Only a directory marked by this installer as in progress is safe to
# resume in place.
if [ ! -f "$EXTRACTION_IN_PROGRESS_MARKER" ] &&
    find "$KVS_PATH" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    log_error "KVS directory is not empty and has no extraction state marker"
    log_error "Refusing to overwrite existing files"
    exit 1
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

if ! ARCHIVE_SHA256=$(sha256sum "$KVS_ARCHIVE" | awk '{print $1}'); then
    log_error "Could not calculate the KVS archive checksum"
    exit 1
fi
ARCHIVE_NAME=$(basename "$KVS_ARCHIVE")
ARCHIVE_IDENTITY="archive=${ARCHIVE_NAME}"$'\n'"sha256=${ARCHIVE_SHA256}"

if [ -f "$EXTRACTION_IN_PROGRESS_MARKER" ]; then
    if [ "$(cat "$EXTRACTION_IN_PROGRESS_MARKER")" != "$ARCHIVE_IDENTITY" ]; then
        log_error "The interrupted extraction belongs to a different KVS archive"
        log_error "Refusing to mix archive contents in the existing site directory"
        exit 1
    fi
    log_info "Resuming interrupted KVS extraction"
fi

# Extract into an isolated directory first. A failed or interrupted unzip never
# exposes an incomplete archive as a live KVS tree. The staging directory is
# disposable and is rebuilt on every retry.
STAGING_DIR=$(mktemp -d /tmp/kvs-extract.XXXXXX)
if ! unzip -tq "$KVS_ARCHIVE" >/dev/null; then
    log_error "KVS archive integrity check failed"
    exit 1
fi
if ! unzip -q -o "$KVS_ARCHIVE" -d "$STAGING_DIR"; then
    log_error "KVS archive extraction failed"
    exit 1
fi
if [ ! -f "$STAGING_DIR/admin/include/setup.php" ] ||
    [ ! -f "$STAGING_DIR/_INSTALL/install_db.sql" ]; then
    log_error "KVS archive is missing required installation files"
    exit 1
fi

if [ ! -f "$EXTRACTION_IN_PROGRESS_MARKER" ]; then
    write_marker_atomically \
        "$EXTRACTION_IN_PROGRESS_MARKER" "$ARCHIVE_NAME" "$ARCHIVE_SHA256"
fi

# Promotion can be retried safely after interruption. The in-progress marker
# authorizes replacement only for a tree created from this exact archive.
if ! cp -a "$STAGING_DIR"/. "$KVS_PATH"/; then
    log_error "Could not promote the staged KVS extraction"
    exit 1
fi

# Set initial permissions
chown -R 1000:1000 "$KVS_PATH"
chmod -R 755 "$KVS_PATH"

# The final permissions module applies both the KVS rules and the container
# safeguards after every configuration step has finished.

write_marker_atomically \
    "$EXTRACTION_COMPLETE_MARKER" "$ARCHIVE_NAME" "$ARCHIVE_SHA256"
rm -f "$EXTRACTION_IN_PROGRESS_MARKER"

log_info "KVS extracted successfully"
