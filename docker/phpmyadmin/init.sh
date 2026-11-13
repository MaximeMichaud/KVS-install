#!/bin/sh
set -eu

# The release phpMyAdmin is pinned to, and the sha256 phpMyAdmin publishes
# beside it at
# https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.tar.gz.sha256
# Overriding PHPMYADMIN_VERSION without PHPMYADMIN_SHA256 fetches that file
# for the requested version, so the archive is always checked against a
# published checksum and never against the page that advertises it.
PMA_DEFAULT_VERSION=5.2.3
PMA_DEFAULT_SHA256=12ba1c425fa4071abbd4e7668c9ebdeac0b0755a467a6d6d5026122bb47c102b

TARGET_DIR=${PHPMYADMIN_TARGET_DIR:-/usr/share/phpmyadmin}
COMPLETION_MARKER="${TARGET_DIR}/.kvs-install-complete"
# phpMyAdmin runs as kvs-phpmyadmin, UID and GID 999 in the PHP-FPM image
# (docker/php/Dockerfile), never as the site's www-data of UID 1000: it reads
# config.inc.php, which it may not change, and alone writes tmp/, where it
# compiles its templates to PHP. Earlier releases gave both to UID 1000.
RUNTIME_UID=999
RUNTIME_GID=999
LEGACY_UID=1000
# The PHP-FPM entrypoint keeps the socket of that pool here, for nginx.
SOCKET_DIR="${TARGET_DIR}/.kvs-fpm"
# The sample server is localhost, which PHP reaches through a Unix socket that
# the PHP-FPM container does not have. MariaDB is the "mariadb" Compose service.
SAMPLE_HOST_LINE="\$cfg['Servers'][\$i]['host'] = 'localhost';"
MARIADB_HOST_LINE="\$cfg['Servers'][\$i]['host'] = 'mariadb';"
# Rewrites exactly the sample line, with BusyBox sed as well as GNU sed.
HOST_EDIT="/^[\$]cfg\['Servers']\[[\$]i]\['host'] = 'localhost';\$/s/localhost/mariadb/"
TEMP_ROOT=${TMPDIR:-/tmp}
STAGING_DIR=
DOWNLOAD_FILE=
CHECKSUM_FILE=
PROMOTION_DIR=
BACKUP_DIR=
MARKER_TMP=
CONFIG_TMP=
PROMOTION_IN_PROGRESS=false
BACKUP_COMPLETE=false
ORIGINAL_TARGET_UID=
ORIGINAL_TARGET_GID=
ORIGINAL_TARGET_MODE=

metadata_is() {
    [ "$(stat -c '%u:%g:%a' "$1" 2>/dev/null)" = "$2" ]
}

config_is_current() {
    metadata_is "${TARGET_DIR}/config.inc.php" "0:${RUNTIME_GID}:640"
}

tmp_is_current() {
    metadata_is "${TARGET_DIR}/tmp" "${RUNTIME_UID}:${RUNTIME_GID}:700"
}

config_is_legacy() {
    metadata_is "${TARGET_DIR}/config.inc.php" "${LEGACY_UID}:${LEGACY_UID}:600"
}

# Root alone may have written the file: root's, writable by no one else,
# in a directory that is root's and writable by no one else either. stat
# reads a link itself, which everyone may write.
written_by_root_alone() {
    for path in "$1" "$TARGET_DIR"; do
        owner_mode=$(stat -c '%u %a' "$path") || return 1
        [ "${owner_mode% *}" = 0 ] || return 1
        [ $((0${owner_mode#* } & 022)) -eq 0 ] || return 1
    done
}

# Writes the sample configuration <sample> to <output> with a new application
# secret and the mariadb server entry.
write_config_from_sample() {
    BLOWFISH=$(head -c 48 /dev/urandom | base64 | tr -d '=+/' | cut -c 1-32)
    [ "${#BLOWFISH}" -eq 32 ] || {
        echo "ERROR: Could not generate the phpMyAdmin application secret" >&2
        exit 1
    }
    sed -e "s|cfg\['blowfish_secret'\] = '';|cfg['blowfish_secret'] = '${BLOWFISH}';|" \
        -e "$HOST_EDIT" \
        "$1" > "$2"
    if grep -Fq "\$cfg['blowfish_secret'] = '';" "$2" ||
        ! grep -Fq "$BLOWFISH" "$2"; then
        echo "ERROR: Could not write the phpMyAdmin application secret" >&2
        exit 1
    fi
    unset BLOWFISH
    if grep -Fqx "$SAMPLE_HOST_LINE" "$2" ||
        ! grep -Fqx "$MARIADB_HOST_LINE" "$2"; then
        echo "ERROR: Could not point phpMyAdmin at the mariadb service" >&2
        exit 1
    fi
}

# The sample of the installation can replace a config.inc.php of an earlier
# release: root alone wrote it, and it is still the sample of a release.
sample_is_trusted() {
    sample="${TARGET_DIR}/config.sample.inc.php"
    [ -f "$sample" ] && written_by_root_alone "$sample" &&
        grep -Fq "\$cfg['blowfish_secret'] = '';" "$sample" &&
        grep -Fqx "$SAMPLE_HOST_LINE" "$sample"
}

# Earlier releases gave config.inc.php to the site's PHP-FPM user, so the
# site's PHP could have added code to it, which phpMyAdmin would run as its
# own user, or read its secret. It is written anew from the sample, with a
# new secret: settings made in it by hand are dropped, and phpMyAdmin's
# logins end. The new file replaces the old one in a single rename.
replace_legacy_config() {
    CONFIG_TMP=$(mktemp "${TARGET_DIR}/.config.inc.php.XXXXXX") || adopt_runtime_owner_failed
    write_config_from_sample "${TARGET_DIR}/config.sample.inc.php" "$CONFIG_TMP"
    chown "0:${RUNTIME_GID}" "$CONFIG_TMP" || adopt_runtime_owner_failed
    chmod 640 "$CONFIG_TMP" || adopt_runtime_owner_failed
    mv -f "$CONFIG_TMP" "${TARGET_DIR}/config.inc.php" || adopt_runtime_owner_failed
    CONFIG_TMP=
    echo "Wrote config.inc.php anew from config.sample.inc.php with a new secret: the site's PHP-FPM user could change the one an earlier release left, and settings made in it by hand are not kept"
}

is_initialized() {
    [ -f "$COMPLETION_MARKER" ] &&
        [ -s "${TARGET_DIR}/index.php" ] &&
        [ -s "${TARGET_DIR}/config.inc.php" ] &&
        [ ! -L "${TARGET_DIR}/config.inc.php" ] &&
        [ -d "${TARGET_DIR}/tmp" ] &&
        [ ! -L "${TARGET_DIR}/tmp" ] &&
        metadata_is "$COMPLETION_MARKER" '0:0:600' &&
        { config_is_current ||
            metadata_is "${TARGET_DIR}/config.inc.php" "${LEGACY_UID}:${LEGACY_UID}:600"; } &&
        { tmp_is_current ||
            metadata_is "${TARGET_DIR}/tmp" "${LEGACY_UID}:${LEGACY_UID}:700"; }
}

# An installation of an earlier release: its configuration is written anew
# (replace_legacy_config), owned by root and read by kvs-phpmyadmin. Its tmp/
# was written by the site's PHP, and phpMyAdmin runs the compiled templates
# it finds there, so it starts empty. The marker goes first: a run stopped
# halfway leaves an installation the next run installs again.
adopt_runtime_owner() {
    if config_is_current && tmp_is_current; then
        return 0
    fi
    rm -f -- "$COMPLETION_MARKER" || adopt_runtime_owner_failed
    if config_is_legacy; then
        replace_legacy_config
    fi
    if ! tmp_is_current; then
        rm -rf -- "${TARGET_DIR}/tmp" || adopt_runtime_owner_failed
        mkdir "${TARGET_DIR}/tmp" || adopt_runtime_owner_failed
        chown "${RUNTIME_UID}:${RUNTIME_GID}" "${TARGET_DIR}/tmp" || adopt_runtime_owner_failed
        chmod 700 "${TARGET_DIR}/tmp" || adopt_runtime_owner_failed
        echo "Emptied tmp/ and gave it to phpMyAdmin's own PHP-FPM user instead of the site's"
    fi
    write_completion_marker
}

adopt_runtime_owner_failed() {
    echo "ERROR: Could not give the phpMyAdmin files to its own PHP-FPM user" >&2
    exit 1
}

# Written last, through a temporary file that cleanup removes if the run stops.
write_completion_marker() {
    MARKER_TMP=$(mktemp "${TARGET_DIR}/.kvs-install-complete.XXXXXX")
    printf '%s\n' complete > "$MARKER_TMP"
    chown 0:0 "$MARKER_TMP"
    chmod 600 "$MARKER_TMP"
    mv -f "$MARKER_TMP" "$COMPLETION_MARKER"
    MARKER_TMP=
    is_initialized || {
        echo "ERROR: phpMyAdmin completion metadata is invalid" >&2
        exit 1
    }
}

# Installations made before the host was set keep the sample's localhost line.
# Rewrite it inside the same file so its inode, owner and mode stay as they
# are; any other host was chosen on purpose and is left alone.
repair_database_host() {
    config="${TARGET_DIR}/config.inc.php"

    grep -Fqx "$SAMPLE_HOST_LINE" "$config" || return 0
    # The x keeps the final newlines, which command substitution would strip.
    repaired=$(sed "$HOST_EDIT" "$config" && printf x)
    # Writing in place empties the file before refilling it, so the marker is
    # removed first and written back once the new content is verified. A run
    # that stops halfway then makes the next one install phpMyAdmin again.
    if ! rm -f -- "$COMPLETION_MARKER" ||
        ! printf '%s' "${repaired%x}" > "$config" ||
        grep -Fqx "$SAMPLE_HOST_LINE" "$config" ||
        ! grep -Fqx "$MARIADB_HOST_LINE" "$config"; then
        echo "ERROR: Could not point phpMyAdmin at the mariadb service in ${config}" >&2
        exit 1
    fi
    write_completion_marker
    echo "Switched the sample localhost server entry of config.inc.php to mariadb"
}

remove_target_entries() {
    for entry in \
        "$TARGET_DIR"/* \
        "$TARGET_DIR"/.[!.]* \
        "$TARGET_DIR"/..?*
    do
        if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
            continue
        fi
        if [ "$entry" = "$BACKUP_DIR" ] || [ "$entry" = "$PROMOTION_DIR" ] ||
            [ "$entry" = "$SOCKET_DIR" ]; then
            continue
        fi
        rm -rf -- "$entry" || return 1
    done
}

restore_backup() {
    [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] || return 0

    if [ "$BACKUP_COMPLETE" = true ]; then
        remove_target_entries || return 1
    fi
    for entry in \
        "$BACKUP_DIR"/* \
        "$BACKUP_DIR"/.[!.]* \
        "$BACKUP_DIR"/..?*
    do
        if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
            continue
        fi
        mv -- "$entry" "$TARGET_DIR/" || return 1
    done
    if [ -n "$ORIGINAL_TARGET_UID" ]; then
        chown "${ORIGINAL_TARGET_UID}:${ORIGINAL_TARGET_GID}" "$TARGET_DIR" || return 1
        chmod "$ORIGINAL_TARGET_MODE" "$TARGET_DIR" || return 1
    fi
}

cleanup() {
    status=$?
    rollback_failed=false
    trap - 0 2 15
    set +e

    if [ "$PROMOTION_IN_PROGRESS" = true ] && ! restore_backup; then
        echo "ERROR: Could not restore the previous phpMyAdmin installation" >&2
        rollback_failed=true
        status=1
    fi
    [ -n "$MARKER_TMP" ] && rm -f -- "$MARKER_TMP"
    [ -n "$CONFIG_TMP" ] && rm -f -- "$CONFIG_TMP"
    [ -n "$PROMOTION_DIR" ] && rm -rf -- "$PROMOTION_DIR"
    if [ "$rollback_failed" = false ] && [ -n "$BACKUP_DIR" ]; then
        rm -rf -- "$BACKUP_DIR"
    fi
    [ -n "$STAGING_DIR" ] && rm -rf -- "$STAGING_DIR"
    [ -n "$DOWNLOAD_FILE" ] && rm -f -- "$DOWNLOAD_FILE"
    [ -n "$CHECKSUM_FILE" ] && rm -f -- "$CHECKSUM_FILE"

    exit "$status"
}
trap cleanup 0
trap 'exit 130' 2
trap 'exit 143' 15

if is_initialized; then
    if config_is_legacy && ! sample_is_trusted; then
        # Nothing root alone wrote to start the configuration from.
        echo "config.inc.php of an earlier release cannot be written anew from a sample only root wrote: installing phpMyAdmin again"
    else
        echo "phpMyAdmin is already initialized"
        adopt_runtime_owner
        repair_database_host
        exit 0
    fi
fi

apk add --no-cache curl tar grep sed >/dev/null
umask 077

STAGING_DIR=$(mktemp -d "${TEMP_ROOT%/}/phpmyadmin-staging.XXXXXX")
DOWNLOAD_FILE=$(mktemp "${TEMP_ROOT%/}/phpmyadmin-archive.XXXXXX")

PMA_VERSION=${PHPMYADMIN_VERSION:-$PMA_DEFAULT_VERSION}
case "$PMA_VERSION" in
    ''|*[!0-9A-Za-z.-]*|*..*|.*)
        echo "ERROR: PHPMYADMIN_VERSION is not a release number" >&2
        exit 1
        ;;
esac

PMA_BASE_URL=${PHPMYADMIN_BASE_URL:-https://files.phpmyadmin.net/phpMyAdmin}
PMA_URL="${PMA_BASE_URL}/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"

PMA_SHA256=${PHPMYADMIN_SHA256:-}
if [ -z "$PMA_SHA256" ] && [ "$PMA_VERSION" = "$PMA_DEFAULT_VERSION" ]; then
    PMA_SHA256=$PMA_DEFAULT_SHA256
fi
if [ -z "$PMA_SHA256" ]; then
    CHECKSUM_FILE=$(mktemp "${TEMP_ROOT%/}/phpmyadmin-checksum.XXXXXX")
    curl -fsSL "${PMA_URL}.sha256" -o "$CHECKSUM_FILE"
    PMA_SHA256=$(cut -d' ' -f1 <"$CHECKSUM_FILE")
fi
case "$PMA_SHA256" in
    ''|*[!0-9a-f]*)
        echo "ERROR: phpMyAdmin checksum is not a sha256 digest" >&2
        exit 1
        ;;
esac
[ "${#PMA_SHA256}" -eq 64 ] || {
    echo "ERROR: phpMyAdmin checksum is not a sha256 digest" >&2
    exit 1
}

curl -fsSL "$PMA_URL" -o "$DOWNLOAD_FILE"
DOWNLOAD_SHA256=$(sha256sum "$DOWNLOAD_FILE" | cut -d' ' -f1)
[ "$DOWNLOAD_SHA256" = "$PMA_SHA256" ] || {
    echo "ERROR: phpMyAdmin ${PMA_VERSION} checksum mismatch" >&2
    echo "  expected: ${PMA_SHA256}" >&2
    echo "  received: ${DOWNLOAD_SHA256}" >&2
    exit 1
}
tar -tzf "$DOWNLOAD_FILE" >/dev/null
tar -xzf "$DOWNLOAD_FILE" --strip-components=1 -C "$STAGING_DIR"
[ -s "${STAGING_DIR}/index.php" ] || {
    echo "ERROR: phpMyAdmin archive is missing index.php" >&2
    exit 1
}
[ -s "${STAGING_DIR}/config.sample.inc.php" ] || {
    echo "ERROR: phpMyAdmin archive is missing its sample configuration" >&2
    exit 1
}
grep -Fq "\$cfg['blowfish_secret'] = '';" \
    "${STAGING_DIR}/config.sample.inc.php" || {
    echo "ERROR: phpMyAdmin sample configuration has no secret placeholder" >&2
    exit 1
}
grep -Fqx "$SAMPLE_HOST_LINE" "${STAGING_DIR}/config.sample.inc.php" || {
    echo "ERROR: phpMyAdmin sample configuration has no localhost server entry" >&2
    exit 1
}

write_config_from_sample "${STAGING_DIR}/config.sample.inc.php" "${STAGING_DIR}/config.inc.php"

if [ -e "$TARGET_DIR" ] && [ ! -d "$TARGET_DIR" ]; then
    echo "ERROR: phpMyAdmin target exists but is not a directory" >&2
    exit 1
fi
mkdir -p "$TARGET_DIR" "${STAGING_DIR}/tmp"
ORIGINAL_TARGET_UID=$(stat -c %u "$TARGET_DIR")
ORIGINAL_TARGET_GID=$(stat -c %g "$TARGET_DIR")
ORIGINAL_TARGET_MODE=$(stat -c %a "$TARGET_DIR")

# Prepare the complete release inside the target filesystem before changing
# the active installation. The backup is restored automatically if any step
# of the promotion fails.
PROMOTION_DIR=$(mktemp -d "${TARGET_DIR}/.kvs-install-next.XXXXXX")
cp -a "${STAGING_DIR}/." "$PROMOTION_DIR/"
chown -R 0:0 "$PROMOTION_DIR"
find "$PROMOTION_DIR" -type d -exec chmod 755 {} \;
find "$PROMOTION_DIR" -type f -exec chmod 644 {} \;
chown "0:${RUNTIME_GID}" "${PROMOTION_DIR}/config.inc.php"
chown "${RUNTIME_UID}:${RUNTIME_GID}" "${PROMOTION_DIR}/tmp"
chmod 640 "${PROMOTION_DIR}/config.inc.php"
chmod 700 "${PROMOTION_DIR}/tmp"

BACKUP_DIR=$(mktemp -d "${TARGET_DIR}/.kvs-install-backup.XXXXXX")
PROMOTION_IN_PROGRESS=true
for entry in \
    "$TARGET_DIR"/* \
    "$TARGET_DIR"/.[!.]* \
    "$TARGET_DIR"/..?*
do
    if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
        continue
    fi
    if [ "$entry" = "$PROMOTION_DIR" ] || [ "$entry" = "$BACKUP_DIR" ] ||
        [ "$entry" = "$SOCKET_DIR" ]; then
        continue
    fi
    mv -- "$entry" "$BACKUP_DIR/"
done
BACKUP_COMPLETE=true
for entry in \
    "$PROMOTION_DIR"/* \
    "$PROMOTION_DIR"/.[!.]* \
    "$PROMOTION_DIR"/..?*
do
    if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
        continue
    fi
    mv -- "$entry" "$TARGET_DIR/"
done
rmdir "$PROMOTION_DIR"
PROMOTION_DIR=

chown 0:0 "$TARGET_DIR"
chmod 755 "$TARGET_DIR"
[ -s "${TARGET_DIR}/index.php" ] &&
    [ -s "${TARGET_DIR}/config.inc.php" ] &&
    [ -d "${TARGET_DIR}/tmp" ] || {
    echo "ERROR: phpMyAdmin promotion produced an incomplete installation" >&2
    exit 1
}

write_completion_marker

PROMOTION_IN_PROGRESS=false
rm -rf -- "$BACKUP_DIR"
BACKUP_DIR=
echo "phpMyAdmin initialized successfully"
