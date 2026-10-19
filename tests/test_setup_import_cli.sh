#!/bin/bash
# Exercise setup's legacy package handoff with real files and decompression.
# shellcheck disable=SC2016,SC2034  # Literal PHP fixtures and setup globals.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kvs-setup-cli.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
TESTS=0
fail() { echo "not ok - $*" >&2; exit 1; }
pass() { TESTS=$((TESTS + 1)); echo "ok $TESTS - $*"; }

# Source only the production functions, leaving host setup side effects out.
for name in import_inspect_cli_package import_cli_inputs_unchanged import_extract_cli_package import_validate_local_materials import_check_site_links import_note_external_search; do
    awk -v signature="$name() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$ROOT/docker/setup.sh" >> "$WORK/functions.sh"
done
# shellcheck source=/dev/null
source "$ROOT/docker/lib/import.sh"
# shellcheck source=/dev/null
source "$ROOT/docker/lib/import-cli.sh"
# shellcheck source=/dev/null
source "$WORK/functions.sh"

mkdir -p "$WORK/work/kvs-archive" "$WORK/application/admin/include" "$WORK/package/content"
cat > "$WORK/application/admin/include/setup.php" <<'EOF'
<?php
$config['project_path']='/srv/default-site';
$config['project_url']='https://example.test';
$config['tables_prefix']='default_';
EOF
printf '<?php\ndefine("DB_HOST", "localhost");\n' > "$WORK/application/admin/include/setup_db.php"
printf '<?php\n$config["project_version"]="7.0.0";\n' > "$WORK/application/admin/include/version.php"
printf '<?php\nfunction fixture() {}\n' > "$WORK/application/admin/include/functions_base.php"
(cd "$WORK/application" && zip -qr "$WORK/work/kvs-archive/KVS_7.0.0.zip" .)
cat > "$WORK/package/metadata.json" <<'EOF'
{"version":"1.0","kvs_version":"7.0.0","source_path":"/srv/old-site","table_prefix":"catalog_","database":{"file":"database.sql.zst"},"content":{"included":true}}
EOF
printf 'preserved media\n' > "$WORK/package/content/media.txt"
cat > "$WORK/database.sql" <<'EOF'
CREATE TABLE `catalog_options` (`variable` varchar(255), `value` text);
INSERT INTO `catalog_options` VALUES ('INITIAL_VERSION','7.0.0');
-- Dump completed on 2026-01-01 00:00:00
EOF

make_package() {
    zstd -q -c "$1" > "$WORK/package/database.sql.zst"
    tar --zstd -cf "$WORK/package.tar.zst" -C "$WORK/package" .
}
source_hashes() {
    sha256sum "$WORK/package.tar.zst" "$WORK/work/kvs-archive/KVS_7.0.0.zip"
}
assert_stage_removed() {
    if find "$WORK" -maxdepth 1 -name '.kvs-import-*.cli.*' -print -quit | grep -q .; then
        fail 'private preparation stage was left behind'
    fi
}

cd "$WORK/work"
RED='' GREEN='' YELLOW='' CYAN='' NC=''
DOMAIN=example.test
IMPORT_SOURCE=archive
IMPORT_ARCHIVE="$WORK/package.tar.zst"
IMPORT_STAGING="$WORK/import"
IMPORT_MARKER_DIR=$IMPORT_STAGING
make_package "$WORK/database.sql"
source_hashes > "$WORK/before"
import_inspect_cli_package "$WORK/target" > "$WORK/inspection.log" || fail 'setup inspection failed'
[ "$IMPORT_CLI_PACKAGE" = true ] && [ "$IMPORT_TABLES_PREFIX" = catalog_ ] || fail 'wrong inspected package metadata'
import_extract_cli_package "$WORK/target" > "$WORK/extraction.log" || fail 'setup extraction failed'
cmp "$WORK/package/content/media.txt" "$WORK/target/contents/media.txt" || fail 'media bytes changed'
[ "$(import_read_php_config_value "$WORK/target/admin/include/setup.php" tables_prefix)" = catalog_ ] || fail 'application prefix not reconstructed'
[ "$(import_read_php_config_value "$WORK/target/admin/include/setup.php" project_path)" = /srv/old-site ] || fail 'old path lost before native rewrite'
zstd -q -d -c "$IMPORT_STAGING/database.sql.zst" | cmp "$WORK/database.sql" - || fail 'database payload changed'
[ "$(stat -c %a "$IMPORT_STAGING/database.sql.zst")" = 600 ] || fail 'staged dump must be private'
[ ! -e "$WORK/target/database.sql.zst" ] && [ ! -e "$WORK/target/metadata.json" ] || fail 'private package files reached the webroot'
[ "$(cat "$(import_marker_file "$WORK/target")")" = "archive:$IMPORT_ARCHIVE" ] || fail 'native source marker missing'
source_hashes > "$WORK/after"
cmp "$WORK/before" "$WORK/after" || fail 'input files changed'
assert_stage_removed
pass 'setup reconstructs application files and stages the identical private SQL payload'

printf 'keep\n' > "$WORK/target/sentinel"
touch "$IMPORT_ARCHIVE"
if (import_extract_cli_package "$WORK/target") > "$WORK/changed.log" 2>&1; then fail 'changed package identity must fail'; fi
grep -Fq 'changed after inspection' "$WORK/changed.log" || fail 'changed-input guard was not exercised'
[ "$(cat "$WORK/target/sentinel")" = keep ] || fail 'rejected input changed the destination'
assert_stage_removed
pass 'changing an inspected input rejects the handoff without changing the destination'

sed 's/catalog_/different_/g' "$WORK/database.sql" > "$WORK/wrong.sql"
make_package "$WORK/wrong.sql"
import_inspect_cli_package "$WORK/target" > "$WORK/inspection.log" || fail 'metadata inspection failed'
find "$WORK/target" "$IMPORT_STAGING" -type f -print0 | sort -z | xargs -0 sha256sum > "$WORK/target.before"
if (import_extract_cli_package "$WORK/target") > "$WORK/wrong.log" 2>&1; then fail 'wrong SQL prefix must fail'; fi
grep -Fq 'holds no CREATE TABLE for the catalog_ tables' "$WORK/wrong.log" || fail 'SQL guard was not exercised'
find "$WORK/target" "$IMPORT_STAGING" -type f -print0 | sort -z | xargs -0 sha256sum > "$WORK/target.after"
cmp "$WORK/target.before" "$WORK/target.after" || fail 'SQL rejection modified the existing target or staged dump'
assert_stage_removed
pass 'SQL prefix rejection preserves an earlier target and its database staging'

make_package "$WORK/database.sql"
mkdir "$WORK/other"
printf 'unrelated\n' > "$WORK/other/sentinel"
if (import_inspect_cli_package "$WORK/other") > "$WORK/unrelated.log" 2>&1; then fail 'an unrelated destination must fail'; fi
[ "$(cat "$WORK/other/sentinel")" = unrelated ] || fail 'unrelated destination changed'
[ ! -e "$(import_marker_file "$WORK/other")" ] || fail 'an unrelated destination was marked as imported'
pass 'an unrelated existing site is refused without being claimed'

import_inspect_cli_package "$WORK/target" > "$WORK/inspection.log" || fail 'fresh metadata inspection failed'
# Change the real input at the handoff boundary, after the helper has read it.
import_cli_prepare() {
    (
        # shellcheck source=/dev/null
        source "$ROOT/docker/lib/import-cli.sh"
        import_cli_prepare "$@"
    ) || return
    touch "$IMPORT_ARCHIVE"
}
find "$WORK/target" "$IMPORT_STAGING" -type f -print0 | sort -z | xargs -0 sha256sum > "$WORK/target.before"
if (import_extract_cli_package "$WORK/target") > "$WORK/handoff-change.log" 2>&1; then
    fail 'changing an input during preparation must reject publication'
fi
find "$WORK/target" "$IMPORT_STAGING" -type f -print0 | sort -z | xargs -0 sha256sum > "$WORK/target.after"
cmp "$WORK/target.before" "$WORK/target.after" || fail 'changed input during preparation modified the destination'
assert_stage_removed
# shellcheck source=/dev/null
source "$ROOT/docker/lib/import-cli.sh"
pass 'changing a source during preparation cannot publish stale inspection results'

if [ "$EUID" -ne 0 ]; then
    chmod 000 "$WORK/other"
    inspect_status=0
    extract_status=0
    (import_inspect_cli_package "$WORK/other") > "$WORK/denied-inspect.log" 2>&1 || inspect_status=$?
    sha256sum "$IMPORT_STAGING/database.sql.zst" > "$WORK/dump.before"
    (import_extract_cli_package "$WORK/other") > "$WORK/denied-extract.log" 2>&1 || extract_status=$?
    chmod 755 "$WORK/other"
    [ "$inspect_status" -ne 0 ] && [ "$extract_status" -ne 0 ] || fail 'unreadable destination must be refused before publication'
    sha256sum "$IMPORT_STAGING/database.sql.zst" > "$WORK/dump.after"
    cmp "$WORK/dump.before" "$WORK/dump.after" || fail 'denied destination changed staged SQL'
    [ "$(cat "$WORK/other/sentinel")" = unrelated ] || fail 'denied destination changed an unrelated file'
    [ ! -e "$(import_marker_file "$WORK/other")" ] || fail 'denied destination received an import marker'
    assert_stage_removed
    pass 'an unreadable destination cannot receive a marker or replace staged SQL'
fi

echo "All $TESTS setup legacy package tests passed"
