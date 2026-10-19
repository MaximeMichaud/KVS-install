#!/bin/bash
# Exercise the actual setup entry point without changing a Docker installation.
# shellcheck disable=SC2016  # PHP and SQL fixtures contain literal dollar signs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kvs-import-plan.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
TESTS=0

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { TESTS=$((TESTS + 1)); echo "ok $TESTS - $*"; }

mkdir -p "$WORK/site/admin/include" "$WORK/site/contents" "$WORK/work" "$WORK/bin"
cat > "$WORK/site/admin/include/setup.php" <<'EOF'
<?php
$config['project_path']='/srv/old-site';
$config['project_url']='https://old.example.test';
$config['tables_prefix']='catalog_';
EOF
printf '<?php\ndefine("DB_HOST", "localhost");\n' > "$WORK/site/admin/include/setup_db.php"
printf '<?php\n$config["project_version"]="7.0.0";\n' > "$WORK/site/admin/include/version.php"
printf '<?php\nfunction fixture() {}\n' > "$WORK/site/admin/include/functions_base.php"
printf 'preserved media\n' > "$WORK/site/contents/media.txt"
cat > "$WORK/database.sql" <<'EOF'
CREATE TABLE `catalog_options` (`variable` varchar(255), `value` text);
INSERT INTO `catalog_options` VALUES ('INITIAL_VERSION','7.0.0');
-- Dump completed on 2026-01-01 00:00:00
EOF
printf 'services: {}\n' > "$WORK/work/docker-compose.yml"
printf 'PRESERVE_THIS_FILE=yes\n' > "$WORK/work/.env"
export PLAN_MUTATION_LOG="$WORK/mutations.log"
for command in docker apt-get systemctl curl wget git ssh sshpass; do
    cat > "$WORK/bin/$command" <<'EOF'
#!/bin/bash
printf '%s\n' "$0 $*" >> "$PLAN_MUTATION_LOG"
exit 91
EOF
    chmod +x "$WORK/bin/$command"
done
# Version display reads Git before option handling; allow that read alone.
cat > "$WORK/bin/git" <<'EOF'
#!/bin/bash
case " $* " in
    *' log -1 --format='*) exit 0 ;;
    *) printf '%s\n' "$0 $*" >> "$PLAN_MUTATION_LOG"; exit 91 ;;
esac
EOF
export PATH="$WORK/bin:$PATH"

snapshot() {
    find "$WORK/site" "$WORK/work" -type f -print0 | sort -z | xargs -0 sha256sum
}
snapshot > "$WORK/before"

run_plan() {
    local status=0
    (
        cd "$WORK/work"
        env -u IMPORT_ARCHIVE -u IMPORT_REMOTE_HOST -u IMPORT_SITE_DIR -u IMPORT_DB_DUMP \
            DOMAIN=destination.example.test EMAIL=admin@example.test SSL_CHOICE=3 DB_CHOICE=1 \
            "$@" bash "$ROOT/docker/setup.sh" --dry-run
    ) > "$WORK/out" 2> "$WORK/err" || status=$?
    return "$status"
}

assert_untouched() {
    snapshot > "$WORK/after"
    cmp "$WORK/before" "$WORK/after" || fail 'preview changed source files or setup configuration'
    [ ! -e "$PLAN_MUTATION_LOG" ] || fail "preview invoked a mutating tool: $(cat "$PLAN_MUTATION_LOG")"
    [ ! -d "$WORK/work/import" ] || fail 'preview left an import staging directory'
    [ ! -d "$WORK/work/mariadb" ] || fail 'preview staged database initialization files'
}

run_plan IMPORT_SITE_DIR="$WORK/site" IMPORT_DB_DUMP="$WORK/database.sql" ||
    fail "directory preview must work through setup.sh: $(cat "$WORK/out" "$WORK/err")"
grep -Fxq 'Source type: directory' "$WORK/out" || fail 'wrong source type'
grep -Fxq 'KVS version: 7.0.0' "$WORK/out" || fail 'wrong version'
grep -Fxq 'Table prefix: catalog_' "$WORK/out" || fail 'wrong table prefix'
grep -Fxq 'Database tables: 1' "$WORK/out" || fail 'dump was not inspected'
grep -Fxq 'Destination: /var/www/destination.example.test' "$WORK/out" || fail 'wrong destination'
assert_untouched
pass 'directory preview reads the real source and dump without changing the installation'

if run_plan IMPORT_SITE_DIR="$WORK/site"; then fail 'a directory without a dump must fail'; fi
assert_untouched
pass 'incomplete source selection fails before any mutation'

if run_plan IMPORT_SITE_DIR="$WORK/site" IMPORT_DB_DUMP="$WORK/missing.sql"; then fail 'missing dump must fail'; fi
assert_untouched
pass 'missing database dump is a real failure'

sed 's/catalog_/different_/g' "$WORK/database.sql" > "$WORK/wrong-prefix.sql"
if run_plan IMPORT_SITE_DIR="$WORK/site" IMPORT_DB_DUMP="$WORK/wrong-prefix.sql"; then fail 'wrong table prefix must fail'; fi
assert_untouched
pass 'a dump for another table prefix cannot produce a successful plan'

if run_plan IMPORT_SITE_DIR="$WORK/site" IMPORT_DB_DUMP="$WORK/database.sql" DOMAIN='../escape'; then
    fail 'an unsafe destination domain must fail'
fi
assert_untouched
pass 'invalid destination domains are rejected'

mkdir -p "$WORK/package"
cp -a "$WORK/site" "$WORK/package/www"
cp "$WORK/database.sql" "$WORK/package/database.sql"
tar -C "$WORK/package" -cf "$WORK/site.tar" www database.sql
run_plan IMPORT_ARCHIVE="$WORK/site.tar" || fail "archive preview failed: $(cat "$WORK/out" "$WORK/err")"
grep -Fxq 'Source type: archive' "$WORK/out" || fail 'wrong archive source type'
grep -Fxq 'KVS version: 7.0.0' "$WORK/out" || fail 'archive version was not inspected'
grep -Fxq 'Table prefix: catalog_' "$WORK/out" || fail 'archive prefix was not inspected'
assert_untouched
pass 'archive preview reads the actual application configuration without extracting a target site'

mkdir -p "$WORK/legacy/content" "$WORK/work/kvs-archive"
cp "$WORK/site/contents/media.txt" "$WORK/legacy/content/"
zstd -q -c "$WORK/database.sql" > "$WORK/legacy/database.sql.zst"
cat > "$WORK/legacy/metadata.json" <<'EOF'
{"version":"1.0","kvs_version":"7.0.0","source_path":"/srv/old-site","table_prefix":"catalog_","database":{"file":"database.sql.zst"},"content":{"included":true}}
EOF
(cd "$WORK/site" && zip -qr "$WORK/work/kvs-archive/KVS_7.0.0.zip" .)
tar --zstd -cf "$WORK/legacy.tar.zst" -C "$WORK/legacy" .
snapshot > "$WORK/before"
run_plan IMPORT_ARCHIVE="$WORK/legacy.tar.zst" || fail "legacy preview failed: $(cat "$WORK/out" "$WORK/err")"
grep -Fxq 'Source type: archive' "$WORK/out" || fail 'wrong legacy source type'
grep -Fxq 'KVS version: 7.0.0' "$WORK/out" || fail 'legacy version was not validated'
grep -Fxq 'Table prefix: catalog_' "$WORK/out" || fail 'legacy prefix was not read'
grep -Fq 'Legacy KVS CLI data package' "$WORK/out" || fail 'legacy reconstruction must be explained'
assert_untouched
pass 'a legacy CLI package is planned against the matching application archive without writes'

mv "$WORK/work/kvs-archive/KVS_7.0.0.zip" "$WORK/application.saved"
snapshot > "$WORK/before"
if run_plan IMPORT_ARCHIVE="$WORK/legacy.tar.zst"; then fail 'legacy preview needs matching application files'; fi
assert_untouched
mv "$WORK/application.saved" "$WORK/work/kvs-archive/KVS_7.0.0.zip"
snapshot > "$WORK/before"
pass 'a legacy data-only package cannot pretend to be a complete application'

for compression in gzip xz zstd; do
    case "$compression" in
        gzip) extension=gz ;;
        xz) extension=xz ;;
        zstd) extension=zst ;;
    esac
    "$compression" -c "$WORK/site.tar" > "$WORK/site.tar.$extension"
    run_plan IMPORT_ARCHIVE="$WORK/site.tar.$extension" ||
        fail "$compression archive preview failed: $(cat "$WORK/out" "$WORK/err")"
    grep -Fxq 'Table prefix: catalog_' "$WORK/out" || fail "$compression preview lost the prefix"
    assert_untouched
    pass "$compression archive metadata is read by the actual decompressor"
done

head -c 64 "$WORK/site.tar.zst" > "$WORK/truncated.tar.zst"
if run_plan IMPORT_ARCHIVE="$WORK/truncated.tar.zst"; then fail 'a truncated compressed archive must fail'; fi
assert_untouched
pass 'decompression failure cannot produce a successful archive plan'

if run_plan IMPORT_ARCHIVE="$WORK/site.tar" IMPORT_SITE_DIR="$WORK/site" IMPORT_DB_DUMP="$WORK/database.sql"; then
    fail 'conflicting sources must fail'
fi
assert_untouched
pass 'conflicting source kinds are rejected'

if run_plan; then fail 'an import preview requires an explicit source'; fi
assert_untouched
pass 'no selected source cannot produce a successful migration plan'

for bad_setting in DB_CHOICE=99 DB_CHOICE=latest SSL_CHOICE=0; do
    if run_plan IMPORT_SITE_DIR="$WORK/site" IMPORT_DB_DUMP="$WORK/database.sql" "$bad_setting"; then
        fail "invalid setting $bad_setting must fail"
    fi
    assert_untouched
done
pass 'invalid database and certificate choices fail before any mutation'

run_plan IMPORT_REMOTE_HOST=source.example.test IMPORT_REMOTE_DIR=/srv/site ||
    fail "SSH plan failed: $(cat "$WORK/out" "$WORK/err")"
grep -Fxq 'Source type: remote' "$WORK/out" || fail 'wrong SSH source type'
grep -Fxq 'KVS version: not inspected' "$WORK/out" || fail 'SSH preview must not invent a version'
grep -Fq 'no connection was opened' "$WORK/out" || fail 'SSH verification limit must be explicit'
assert_untouched
pass 'SSH selection can be previewed without making a connection or claiming source validation'

if run_plan IMPORT_REMOTE_HOST=source.example.test IMPORT_REMOTE_PORT=70000; then
    fail 'an invalid SSH port must fail'
fi
assert_untouched
pass 'invalid SSH connection settings are rejected'

run_plan IMPORT_REMOTE_HOST=source.example.test IMPORT_FILES_ONLY=yes || fail 'files-only preview failed'
grep -Fxq 'Database action: unchanged (files-only pass)' "$WORK/out" || fail 'files-only plan must preserve the database'
assert_untouched
pass 'a files-only SSH plan leaves database and services unchanged'

run_plan IMPORT_REMOTE_HOST=source.example.test IMPORT_REUSE_DUMP=yes || fail 'dump reuse preview failed'
grep -Fxq 'Database action: import the previously received dump after source checks' "$WORK/out" || fail 'dump reuse plan must not promise a fresh export'
assert_untouched
pass 'dump reuse is distinguished from a new database export'

for bad_setting in IMPORT_FILES_ONLY=invalid IMPORT_FILES_ONLY=yes IMPORT_REUSE_SITE_DIR=/srv/previous-site; do
    if run_plan IMPORT_SITE_DIR="$WORK/site" IMPORT_DB_DUMP="$WORK/database.sql" "$bad_setting"; then
        fail "incompatible mode $bad_setting must fail"
    fi
    assert_untouched
done
if run_plan IMPORT_REMOTE_HOST=source.example.test IMPORT_FILES_ONLY=yes IMPORT_REUSE_DUMP=yes; then
    fail 'files-only and dump reuse must not be combined'
fi
assert_untouched
pass 'invalid and incompatible import modes fail in preview too'

if (
    cd "$WORK/work"
    bash "$ROOT/docker/setup.sh" --dry-run --resume-import
) > "$WORK/out" 2> "$WORK/err"; then
    fail 'resume and new-import planning must not be combined'
fi
assert_untouched
pass 'incompatible planning and resume modes fail without modifying the installation'

if [ "$EUID" -ne 0 ]; then
    chmod 000 "$WORK/database.sql"
    status=0
    run_plan IMPORT_SITE_DIR="$WORK/site" IMPORT_DB_DUMP="$WORK/database.sql" || status=$?
    chmod 644 "$WORK/database.sql"
    [ "$status" -ne 0 ] || fail 'unreadable dump must fail'
    assert_untouched
    pass 'real filesystem permission failure is not treated as an empty database'
fi

echo "All $TESTS import plan tests passed"
