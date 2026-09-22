#!/bin/bash
set -e

# Replace the admin credential shipped in the KVS seed database before public
# services start, and register it where the admin login looks it up. KVS
# support access stays as KVS ships it unless the operator opts out.
# shellcheck disable=SC1091
source /init/lib/common.sh

# KVS keeps admin/data/system/ap.dat, a list of substr(md5(login . stored
# hash), 0, 20) fingerprints. The admin login rejects any account whose
# fingerprint is missing before it reads the database, so a credential changed
# by SQL alone locks the panel until the file matches again.
ADMIN_FINGERPRINT_FILE="$KVS_PATH/admin/data/system/ap.dat"

register_admin_fingerprint() {
    local fingerprint="$1"

    if [ ! -f "$ADMIN_FINGERPRINT_FILE" ]; then
        log_warn "admin/data/system/ap.dat not found; the admin login fingerprint was not registered"
        return 0
    fi
    # shellcheck disable=SC2016  # This is PHP code, not a shell expression.
    php -r '
        $file = $argv[1];
        $fingerprint = $argv[2];
        $data = json_decode((string) file_get_contents($file), true);
        if (!is_array($data) || !isset($data["admins"]) || !is_array($data["admins"])) {
            fwrite(STDERR, "ap.dat does not hold an admins list\n");
            exit(1);
        }
        $found = false;
        foreach ($data["admins"] as &$entry) {
            if (is_array($entry) && (string) ($entry["id"] ?? "") === "1") {
                $entry["hash"] = $fingerprint;
                $found = true;
                break;
            }
        }
        unset($entry);
        if (!$found) {
            $data["admins"][] = ["id" => "1", "hash" => $fingerprint, "lock_ip" => ""];
        }
        $json = json_encode($data);
        if ($json === false || file_put_contents($file, $json, LOCK_EX) === false) {
            fwrite(STDERR, "ap.dat could not be written\n");
            exit(1);
        }
        $written = json_decode((string) file_get_contents($file), true);
        foreach ((array) ($written["admins"] ?? []) as $entry) {
            if (is_array($entry) && (string) ($entry["id"] ?? "") === "1" &&
                ($entry["hash"] ?? "") === $fingerprint) {
                exit(0);
            }
        }
        fwrite(STDERR, "ap.dat does not carry the admin fingerprint after the write\n");
        exit(1);
    ' -- "$ADMIN_FINGERPRINT_FILE" "$fingerprint"
}

ADMIN_COUNT=$(db_query "SELECT COUNT(*) FROM ktvs_admin_users WHERE user_id=1 AND login='admin'" || echo 0)
if [ "$ADMIN_COUNT" -ne 1 ]; then
    log_error "Expected exactly one primary KVS admin account"
    exit 1
fi

DEFAULT_ADMIN_HASH=$(php -r 'echo md5("pass:" . md5("123"));')

if [ -n "${KVS_ADMIN_PASSWORD:-}" ]; then
    if [ "${#KVS_ADMIN_PASSWORD}" -lt 20 ]; then
        log_error "KVS_ADMIN_PASSWORD must contain at least 20 characters"
        exit 1
    fi
    # The admin login hashes the submitted password as md5("pass:" . md5(pw)),
    # the same scheme the seed uses, so the panel accepts this value directly.
    # shellcheck disable=SC2016  # This is PHP code, not a shell expression.
    ADMIN_HASH=$(
        printf '%s' "$KVS_ADMIN_PASSWORD" |
            php -r '$password = stream_get_contents(STDIN); echo md5("pass:" . md5($password));'
    )
    unset KVS_ADMIN_PASSWORD
    ADMIN_FINGERPRINT=$(
        printf '%s' "admin${ADMIN_HASH}" |
            php -r 'echo substr(md5(stream_get_contents(STDIN)), 0, 20);'
    )
    # Register the fingerprint first: if it fails, the database still holds
    # the default credential and the next run repeats the whole replacement.
    register_admin_fingerprint "$ADMIN_FINGERPRINT"
    unset ADMIN_FINGERPRINT
    db_exec "UPDATE ktvs_admin_users SET pass='${ADMIN_HASH}', last_session_id='' WHERE user_id=1 AND login='admin';" \
        >/dev/null
    unset ADMIN_HASH
    log_info "Primary KVS admin credential replaced and registered for the admin login"
fi

DEFAULT_ADMIN_COUNT=$(db_query "SELECT COUNT(*) FROM ktvs_admin_users WHERE user_id=1 AND login='admin' AND pass='${DEFAULT_ADMIN_HASH}'" || echo 1)
unset DEFAULT_ADMIN_HASH

if [ "$DEFAULT_ADMIN_COUNT" -ne 0 ]; then
    log_error "The primary KVS admin account still uses the archive default credential"
    exit 1
fi

# KVS ships the kvs_support account with ENABLE_KVS_SUPPORT_ACCESS=1 so that
# Kernel Team can log in from its own address when the owner asks for help.
# That access is kept as shipped unless the operator opts out; the dashboard
# button re-enables it at any time.
case "${DISABLE_KVS_SUPPORT_ACCESS:-false}" in
    true)
        db_exec "UPDATE ktvs_options SET value='0' WHERE variable='ENABLE_KVS_SUPPORT_ACCESS';" \
            >/dev/null
        SUPPORT_ACCESS=$(db_query "SELECT value FROM ktvs_options WHERE variable='ENABLE_KVS_SUPPORT_ACCESS'" || echo query-failed)
        if [ "$SUPPORT_ACCESS" != "0" ]; then
            log_error "KVS support access could not be disabled (ENABLE_KVS_SUPPORT_ACCESS is '${SUPPORT_ACCESS}')"
            exit 1
        fi
        log_info "KVS support access disabled; the admin dashboard can re-enable it"
        ;;
    false)
        log_info "KVS support access left as configured in KVS (enabled by default); set DISABLE_KVS_SUPPORT_ACCESS=true to turn it off"
        ;;
    *)
        log_error "DISABLE_KVS_SUPPORT_ACCESS must be true or false"
        exit 1
        ;;
esac
log_info "Seeded KVS admin account hardened"
