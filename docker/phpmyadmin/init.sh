#!/bin/sh
set -eu

TARGET_DIR=${PHPMYADMIN_TARGET_DIR:-/usr/share/phpmyadmin}
COMPLETION_MARKER="${TARGET_DIR}/.kvs-install-complete"
TEMP_ROOT=${TMPDIR:-/tmp}
STAGING_DIR=
DOWNLOAD_FILE=
DOWNLOAD_PAGE=
PROMOTION_DIR=
BACKUP_DIR=
MARKER_TMP=
PROMOTION_IN_PROGRESS=false
BACKUP_COMPLETE=false
ORIGINAL_TARGET_UID=
ORIGINAL_TARGET_GID=
ORIGINAL_TARGET_MODE=

metadata_is() {
    [ "$(stat -c '%u:%g:%a' "$1" 2>/dev/null)" = "$2" ]
}

is_initialized() {
    [ -f "$COMPLETION_MARKER" ] &&
        [ -s "${TARGET_DIR}/index.php" ] &&
        [ -s "${TARGET_DIR}/config.inc.php" ] &&
        [ -d "${TARGET_DIR}/tmp" ] &&
        metadata_is "$COMPLETION_MARKER" '0:0:600' &&
        metadata_is "${TARGET_DIR}/config.inc.php" '1000:1000:600' &&
        metadata_is "${TARGET_DIR}/tmp" '1000:1000:700'
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
        if [ "$entry" = "$BACKUP_DIR" ] || [ "$entry" = "$PROMOTION_DIR" ]; then
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
    [ -n "$PROMOTION_DIR" ] && rm -rf -- "$PROMOTION_DIR"
    if [ "$rollback_failed" = false ] && [ -n "$BACKUP_DIR" ]; then
        rm -rf -- "$BACKUP_DIR"
    fi
    [ -n "$STAGING_DIR" ] && rm -rf -- "$STAGING_DIR"
    [ -n "$DOWNLOAD_FILE" ] && rm -f -- "$DOWNLOAD_FILE"
    [ -n "$DOWNLOAD_PAGE" ] && rm -f -- "$DOWNLOAD_PAGE"

    exit "$status"
}
trap cleanup 0
trap 'exit 130' 2
trap 'exit 143' 15

if is_initialized; then
    echo "phpMyAdmin is already initialized"
    exit 0
fi

apk add --no-cache curl tar grep sed >/dev/null
umask 077

STAGING_DIR=$(mktemp -d "${TEMP_ROOT%/}/phpmyadmin-staging.XXXXXX")
DOWNLOAD_FILE=$(mktemp "${TEMP_ROOT%/}/phpmyadmin-archive.XXXXXX")
DOWNLOAD_PAGE=$(mktemp "${TEMP_ROOT%/}/phpmyadmin-download-page.XXXXXX")

curl -fsSL https://www.phpmyadmin.net/downloads/ -o "$DOWNLOAD_PAGE"
PMA_URL=$(
    grep -oE 'https://files[.]phpmyadmin[.]net/phpMyAdmin/[^" ]+all-languages[.]tar[.]gz' \
        "$DOWNLOAD_PAGE" | sed -n '1p'
)
case "$PMA_URL" in
    https://files.phpmyadmin.net/phpMyAdmin/*/phpMyAdmin-*-all-languages.tar.gz) ;;
    *)
        echo "ERROR: Could not determine a trusted phpMyAdmin download URL" >&2
        exit 1
        ;;
esac

curl -fsSL "$PMA_URL" -o "$DOWNLOAD_FILE"
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

BLOWFISH=$(head -c 48 /dev/urandom | base64 | tr -d '=+/' | cut -c 1-32)
[ "${#BLOWFISH}" -eq 32 ] || {
    echo "ERROR: Could not generate the phpMyAdmin application secret" >&2
    exit 1
}
sed "s|cfg\['blowfish_secret'\] = '';|cfg['blowfish_secret'] = '${BLOWFISH}';|" \
    "${STAGING_DIR}/config.sample.inc.php" > "${STAGING_DIR}/config.inc.php"
if grep -Fq "\$cfg['blowfish_secret'] = '';" "${STAGING_DIR}/config.inc.php" ||
    ! grep -Fq "$BLOWFISH" "${STAGING_DIR}/config.inc.php"; then
    echo "ERROR: Could not write the phpMyAdmin application secret" >&2
    exit 1
fi
unset BLOWFISH

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
chown 1000:1000 "${PROMOTION_DIR}/config.inc.php" "${PROMOTION_DIR}/tmp"
chmod 600 "${PROMOTION_DIR}/config.inc.php"
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
    if [ "$entry" = "$PROMOTION_DIR" ] || [ "$entry" = "$BACKUP_DIR" ]; then
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

PROMOTION_IN_PROGRESS=false
rm -rf -- "$BACKUP_DIR"
BACKUP_DIR=
echo "phpMyAdmin initialized successfully"
