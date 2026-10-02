#!/bin/bash
# IMPORT_REUSE_SITE_DIR moves the files of an earlier import into place
# during the inspection of the old server, long before the transfer. When a
# later step fails ("the file transfer failed ...; run the same command
# again to resume it"), the same command must inspect again and go on with
# the files moved, instead of refusing the directory they came from.
# shellcheck disable=SC2034,SC2329  # Read or called by the extracted functions.
set -uo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-take-over-rerun.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
for name in import_save_nginx_config import_remote_earlier_pass import_inspect_remote; do
    awk -v signature="$name() {" '$0 == signature { capture = 1 } capture { print } capture && /^}$/ { exit }' \
        "$ROOT_DIR/docker/setup.sh"
done | sed "s|/var/www/|$TEST_DIR/www/|g" > "$TEST_DIR/setup-functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/setup-functions.sh"
cd "$TEST_DIR" || exit 1
mkdir -p logs import www/dev.example.com/admin
LOG_DIR="$TEST_DIR/logs" HEADLESS=y RED='' GREEN='' YELLOW='' CYAN='' NC=''
DOMAIN=example.com IMPORT_STAGING="$TEST_DIR/import" IMPORT_MARKER_DIR="$TEST_DIR/import"
IMPORT_TRANSFER_JOBS=4 IMPORT_SIZE_TIMEOUT=300 IMPORT_REMOTE_PASSWORD=fixture
IMPORT_REMOTE_HOST=old.example.com IMPORT_REMOTE_PORT=22 IMPORT_REMOTE_USER=root IMPORT_REMOTE_DIR=''
IMPORT_SSH_KEY='' IMPORT_SSH_ACCEPT_NEW=y IMPORT_EXCLUDE='' IMPORT_INCLUDE=''
IMPORT_DATABASE_FORMAT=auto IMPORT_REMOTE_SUDO_ERROR='' IMPORT_EXPORTER="$ROOT_DIR/kvs-export.sh"
IMPORT_NGINX_REWRITES='' IMPORT_MODE=true IMPORT_REUSE_SITE_DIR="$TEST_DIR/www/dev.example.com"
import_ensure_tool() { return 0; }
import_ssh_setup() { IMPORT_SSH_TARGET=root@old.example.com; }
import_ssh_close() { return 0; }
import_remote_privileges() { IMPORT_REMOTE_PRIVILEGES=root; }
import_remote_show_entries() { return 0; }
import_remote_show_servers() { return 0; }
import_remote_load_excludes() { return 0; }
import_remote_free_space_check() { return 0; }
import_remote_detect() {
    printf 'kvs_export=1\nsite_dir=/var/www/example.com\nproject_path=/var/www/example.com\nkvs_version=7.0.2\n' > "$3"
    printf 'tables_prefix=ktvs_\ndb_ok=yes\nrsync=yes\ncompressor=gzip\ndomain=example.com\n' >> "$3"
}
echo video > www/dev.example.com/admin/file
import_mark_destination www/dev.example.com ssh://root@old.example.com:22/var/www/example.com

status=0
if ! (import_inspect_remote) > first.log 2>&1 || ! grep -q 'taken over' first.log || [ -e www/dev.example.com ]; then
    cat first.log >&2
    echo 'FAIL: the first pass takes the files of the earlier import over' >&2
    exit 1
fi
echo 'PASS: the first pass takes the files of the earlier import over'
# The run then stops later on (transfer, ports, DNS...): the same command again.
if (import_inspect_remote) > second.log 2>&1 && [ -f www/example.com/admin/file ]; then
    echo 'PASS: the same command goes on once the files were taken over'
else
    grep ERROR second.log >&2
    echo 'FAIL: the same command is refused once the files were taken over' >&2
    status=1
fi
# Files of another source in the destination are still refused.
rm -rf www/example.com import/example.com.source
mkdir -p www/dev.example.com www/example.com
echo other > www/example.com/other
import_mark_destination www/dev.example.com ssh://root@old.example.com:22/var/www/example.com
if (import_inspect_remote) > third.log 2>&1 || ! grep -q 'already holds something' third.log; then
    cat third.log >&2
    echo 'FAIL: a destination holding other files is refused' >&2
    status=1
else
    echo 'PASS: a destination holding other files is refused'
fi
exit "$status"
