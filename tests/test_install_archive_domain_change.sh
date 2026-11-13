#!/bin/bash
# I6: the Docker install wrote the domain of the archive name into .env with
# sed before docker/setup.sh ran, on every run without DOMAIN. A KVS package
# also runs under the subdomains of the domain it is licensed for, so that
# name is not always the site's domain: a site installed as
# dev.new.example.com lost its domain to new.example.com on the next run.
# setup.sh takes the domain .env holds as the previous one, so it never saw
# that change either: an import completed under the old domain still
# counted, and the retirement and prefix reset of a new domain were
# skipped. A line written "export DOMAIN=..." was not matched at all, and
# setup.sh kept its domain while the installer said it had set another.
#
# The archive name now seeds only a .env that saves no domain yet, through
# the environment; a domain .env saves is kept, with a warning when the
# archive name differs; an explicit DOMAIN switches, and setup.sh sees the
# change.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kvs-install-archive-domain.XXXXXX")

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

if ! command -v unzip > /dev/null 2>&1 || ! command -v python3 > /dev/null 2>&1; then
    echo "ok - unzip or python3 is not installed here, the Docker case is left to the CI runner"
    exit 0
fi

# env_value <file> <key>: the value of key as setup.sh reads it, by sourcing
# the file.
env_value() {
    (
        unset "$2"
        # shellcheck source=/dev/null
        source "$1" > /dev/null 2>&1
        printf '%s\n' "${!2-}"
    )
}

# saved_site_domain reads the domain of .env the way setup.sh does, by
# sourcing it: an exported or quoted line counts, the last line wins, the
# case does not, and a DOMAIN of the environment or what the file prints
# is not taken for it. No domain, an empty one and the placeholder of
# .env.example are no saved domain.
check_saved_domain() {
    local expected="$1" content="$2" out err
    printf '%b' "$content" > "$TMP_ROOT/unit.env"
    out=$(DOMAIN=env.example.com bash -c 'source "$1"; unset DOMAIN; saved_site_domain "$2"' \
        _ "$REPO_ROOT/kvs-install.sh" "$TMP_ROOT/unit.env" 2> "$TMP_ROOT/unit.err") || true
    err=$(cat "$TMP_ROOT/unit.err")
    [ "$out" = "$expected" ] && [ -z "$err" ] ||
        fail "saved_site_domain of '${content}' must be '${expected}', got '${out}' (stderr: '${err}')"
}
check_saved_domain dev.new.example.com 'DOMAIN=Dev.New.Example.com\n'
check_saved_domain dev.new.example.com 'export DOMAIN="dev.new.example.com"\n'
check_saved_domain b.example.com 'DOMAIN=a.example.com\nDOMAIN=b.example.com\n'
check_saved_domain dev.new.example.com 'echo noise\necho noise >&2\nDOMAIN=dev.new.example.com\n'
check_saved_domain '' 'DOMAIN=example.com\n'
check_saved_domain '' 'DOMAIN=\n'
check_saved_domain '' 'EMAIL=ops@example.com\n'
out=$(DOMAIN=env.example.com bash -c 'source "$1"; saved_site_domain "$2"' \
    _ "$REPO_ROOT/kvs-install.sh" "$TMP_ROOT/unit.env" 2>&1) || true
[ -z "$out" ] || fail "saved_site_domain must not take the DOMAIN of the environment for the saved one: '${out}'"
echo 'PASS: the saved domain is read the way setup.sh reads .env'

# run_case <name> <.env> <completed import: yes|no> [VAR=value...]
# <.env> is "none" for a first install (the installer creates .env from
# .env.example), or the DOMAIN line of the .env an earlier run left, empty
# for none; that .env names the stack kvs-site and may hold a completed
# import. A KVS archive named for ARCHIVE_DOMAIN (new.example.com unless
# set) is in kvs-archive/.
# dockerInstall runs with no DOMAIN in the environment unless given and
# starts a copy of the real docker/setup.sh, headless, with Docker and the
# network stubbed and the pre-flight of the host's disk and network
# bypassed; the setup goes past the domain checks, then stops at the first
# runtime step the fixture does not provide. The timeout guards against a
# hang.
run_case() {
    local name="$1" domain_line="$2" completed="$3" tool archive_domain=${ARCHIVE_DOMAIN:-new.example.com}
    shift 3
    CASE=$name
    CASE_DIR="$TMP_ROOT/$name"
    WORK_DIR="$CASE_DIR/kvs/docker"
    mkdir -p "$CASE_DIR/kvs/.git" "$WORK_DIR/kvs-archive" "$WORK_DIR/bin" \
        "$CASE_DIR/stubs" "$CASE_DIR/logs" "$CASE_DIR/backup"
    cp "$REPO_ROOT/docker/.env.example" "$WORK_DIR/.env.example"
    if [ "$domain_line" != none ]; then
        cp "$REPO_ROOT/docker/.env.example" "$WORK_DIR/.env"
        sed -i \
            -e 's/^EMAIL=.*/EMAIL=ops@example.com/' \
            -e 's/^SITE_PREFIX=.*/SITE_PREFIX=kvs-site/' \
            -e 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=kvs-site/' \
            -e 's/^SSL_PROVIDER=.*/SSL_PROVIDER=selfsigned/' \
            -e 's/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=Generated1/' \
            -e 's/^MARIADB_PASSWORD=.*/MARIADB_PASSWORD=Generated2/' \
            "$WORK_DIR/.env"
        if [ -n "$domain_line" ]; then
            sed -i "s/^DOMAIN=.*/${domain_line}/" "$WORK_DIR/.env"
            grep -qxF "$domain_line" "$WORK_DIR/.env" || fail "${CASE}: the fixture .env has no '${domain_line}' line"
        else
            sed -i '/^DOMAIN=/d' "$WORK_DIR/.env"
            ! grep -q 'DOMAIN=' "$WORK_DIR/.env" || fail "${CASE}: the fixture .env still has a DOMAIN line"
        fi
        if [ "$completed" = yes ]; then
            printf "KVS_IMPORT_COMPLETED='2026-01-01 00:00:00'\n" >> "$WORK_DIR/.env"
        fi
    fi
    python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.writestr("index.php", "x\n"); z.close()' \
        "$WORK_DIR/kvs-archive/KVS_7.0.3_[${archive_domain}].zip"
    # Keep EUID literal while redirecting setup logs into the fixture.
    # shellcheck disable=SC2016
    sed \
        -e "s|/opt/kvs/logs|${CASE_DIR}/logs|g" \
        -e 's/if \[ "$EUID" -ne 0 \]; then/if false; then/' \
        "$REPO_ROOT/docker/setup.sh" > "$WORK_DIR/setup.sh"
    cp "$REPO_ROOT/docker/bin/resolve-bases.sh" "$WORK_DIR/bin/"
    cp "$REPO_ROOT/docker/images.lock" "$WORK_DIR/"
    cat > "$CASE_DIR/stubs/docker" << 'EOF'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then echo "Docker version 28.0.0, build test"; exit 0; fi
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then echo "Docker Compose version v2.35.0"; exit 0; fi
exit 0
EOF
    for tool in curl gum ss; do
        printf '#!/bin/bash\nexit 0\n' > "$CASE_DIR/stubs/$tool"
    done
    chmod +x "$CASE_DIR/stubs/"*
    set +e
    # shellcheck disable=SC2016 # expanded by the inner bash
    timeout 120 env -C "$CASE_DIR" \
        -u DOMAIN -u EMAIL -u KVS_EMAIL -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES \
        -u SITE_PREFIX -u SSL_PROVIDER -u SSL_CHOICE -u CACHE_CHOICE -u PREFIX_CHOICE \
        -u IMPORT_SOURCE -u VOLUME_CHOICE -u MODE \
        PATH="$CASE_DIR/stubs:/usr/bin:/bin" HEADLESS=y PREFLIGHT_BYPASS=y \
        KVS_INSTALL_DIR="$CASE_DIR/kvs" KVS_BACKUP_DIR="$CASE_DIR/backup" "$@" \
        bash -c '
            source "$1"
            refuse_during_kvsctl_run() { return 0; }
            recover_kvsctl_data() { return 0; }
            refuse_kvsctl_managed_install() { return 0; }
            ensure_docker_prerequisites() { return 0; }
            update_kvs_install() { return 0; }
            dockerInstall
        ' _ "$REPO_ROOT/kvs-install.sh" > "$CASE_DIR/output.log" 2>&1
    STATUS=$?
    set -e
    [ "$STATUS" -ne 124 ] || fail "${CASE}: the run did not end within 120 seconds: $(tail -n 5 "$CASE_DIR/output.log")"
}

saved_domain() {
    env_value "$WORK_DIR/.env" DOMAIN
}

domain_lines() {
    grep -E '^(export )?DOMAIN=' "$WORK_DIR/.env" || echo 'no DOMAIN line'
}

# The setup went past its domain checks with <domain> and saved it.
assert_domain_saved() {
    [ "$(saved_domain)" = "$1" ] ||
        fail "${CASE}: .env must save $1: $(domain_lines); $(grep -a -m 3 -i -e 'domain' -e 'error' "$CASE_DIR/output.log")"
    grep -Fq 'SSL Certificate Provider' "$CASE_DIR/output.log" ||
        fail "${CASE}: the setup must go past its domain checks: $(tail -n 5 "$CASE_DIR/output.log")"
}

assert_no_change_seen() {
    ! grep -Fq 'The domain changes from' "$CASE_DIR/output.log" ||
        fail "${CASE}: setup.sh must not see a change of domain: $(grep -a -m 1 'The domain changes from' "$CASE_DIR/output.log")"
}

# A first install, or a .env an earlier run left without a domain (none, an
# empty one, or the placeholder of .env.example, written plain or exported):
# the archive name gives the domain, and setup.sh saves it. The installer
# used to write it with a sed that matched neither a missing nor an exported
# line, and setup.sh then had no domain for a headless run.
for fresh in 'none' 'DOMAIN=example.com' 'export DOMAIN=example.com' 'DOMAIN=' ''; do
    case $fresh in
        none) label=no-env ;;
        '') label=no-domain-line ;;
        export*) label=exported-placeholder ;;
        DOMAIN=) label=empty-domain ;;
        *) label=placeholder ;;
    esac
    run_case "fresh-$label" "$fresh" no
    assert_domain_saved new.example.com
    grep -Fq 'Domain set to: new.example.com' "$CASE_DIR/output.log" ||
        fail "${CASE}: the installer must say the archive name set the domain: $(grep -a -m 3 -i 'domain' "$CASE_DIR/output.log")"
    ! grep -Fq 'Run again with DOMAIN=' "$CASE_DIR/output.log" ||
        fail "${CASE}: a .env without a domain must not keep one"
    assert_no_change_seen
done
echo 'PASS: the archive name gives the domain of a .env that saves none yet'

# A site installed under a subdomain of the licensed domain, run again
# without DOMAIN: the domain .env saves stays, the import completed under it
# still counts, and the installer names the archive's domain and how to
# switch to it. The same with an exported, quoted line, which setup.sh
# reads.
for saved in 'DOMAIN=dev.new.example.com' 'export DOMAIN="dev.new.example.com"'; do
    case $saved in export*) label=exported ;; *) label=plain ;; esac
    run_case "subdomain-$label" "$saved" yes
    assert_domain_saved dev.new.example.com
    assert_no_change_seen
    grep -q '^KVS_IMPORT_COMPLETED=' "$WORK_DIR/.env" ||
        fail "${CASE}: the import completed under the saved domain must still count"
    grep -Fq 'The archive name is for new.example.com; keeping dev.new.example.com, the domain saved in .env. Run again with DOMAIN=new.example.com to switch to it.' "$CASE_DIR/output.log" ||
        fail "${CASE}: the installer must name the archive's domain and how to switch: $(grep -a -m 3 -i 'domain' "$CASE_DIR/output.log")"
    grep -Fxq 'Domain: dev.new.example.com' "$CASE_DIR/output.log" ||
        fail "${CASE}: the installer must name the domain it keeps: $(grep -a -m 3 -i 'domain' "$CASE_DIR/output.log")"
    ! grep -Fq 'Domain set to: new.example.com' "$CASE_DIR/output.log" ||
        fail "${CASE}: the installer must not say it set the archive's domain"
done
# The archive name matches the saved domain, in another case: nothing to
# warn about. A name that is not a valid domain offers no switch either.
run_case same-domain 'DOMAIN=New.Example.com' yes
assert_domain_saved new.example.com
assert_no_change_seen
! grep -Fq 'Run again with DOMAIN=' "$CASE_DIR/output.log" ||
    fail "${CASE}: an archive name that matches the saved domain needs no warning"
ARCHIVE_DOMAIN=bad_name.example.com run_case invalid-archive-name 'DOMAIN=dev.new.example.com' yes
assert_domain_saved dev.new.example.com
assert_no_change_seen
! grep -Fq 'Run again with DOMAIN=' "$CASE_DIR/output.log" ||
    fail "${CASE}: an archive name that is not a valid domain must not be offered: $(grep -a -m 1 'Run again with DOMAIN=' "$CASE_DIR/output.log")"
echo 'PASS: a domain .env saves is kept when the archive name differs, with a warning'

# The same site imported again, headless, without DOMAIN: an ordinary re-run
# of the completed import under the saved domain, not an import under the
# archive's domain.
run_case subdomain-import 'DOMAIN=dev.new.example.com' yes \
    IMPORT_SITE_DIR="$TMP_ROOT/old-site" IMPORT_DB_DUMP="$TMP_ROOT/old-site.sql"
assert_domain_saved dev.new.example.com
assert_no_change_seen
grep -Fq 'the import source is ignored for this run' "$CASE_DIR/output.log" ||
    fail "${CASE}: the import completed under the saved domain must make this an ordinary re-run: $(tail -n 5 "$CASE_DIR/output.log")"
echo 'PASS: an import run again without DOMAIN stays under the saved domain'

# An explicit DOMAIN switches: setup.sh sees the change from the domain
# .env saves, saves the new one and drops the import completed under the
# old one, for a plain and an exported line.
for saved in 'DOMAIN=old.example.com' 'export DOMAIN=old.example.com'; do
    case $saved in export*) label=exported ;; *) label=plain ;; esac
    run_case "switch-$label" "$saved" yes DOMAIN=new.example.com
    assert_domain_saved new.example.com
    grep -Fq 'The domain changes from old.example.com to new.example.com' "$CASE_DIR/output.log" ||
        fail "${CASE}: setup.sh did not see the domain change: $(grep -a -m 3 -i 'domain' "$CASE_DIR/output.log")"
    ! grep -q '^KVS_IMPORT_COMPLETED=' "$WORK_DIR/.env" ||
        fail "${CASE}: the import completed under the old domain must not count for the new one"
done
echo 'PASS: DOMAIN switches the domain .env saves, and setup.sh sees the change'

# A headless import under the new DOMAIN goes on to the import, which stops
# in this fixture at the import library it does not provide, instead of the
# completed import turning it into a re-run.
run_case switch-import 'DOMAIN=old.example.com' yes DOMAIN=new.example.com \
    IMPORT_SITE_DIR="$TMP_ROOT/old-site" IMPORT_DB_DUMP="$TMP_ROOT/old-site.sql"
grep -Fq 'The domain changes from old.example.com to new.example.com' "$CASE_DIR/output.log" ||
    fail "${CASE}: setup.sh did not see the domain change: $(grep -a -m 3 -i 'domain' "$CASE_DIR/output.log")"
! grep -Fq 'the import source is ignored for this run' "$CASE_DIR/output.log" ||
    fail "${CASE}: the import completed under the old domain must not skip the import under the new one"
grep -Fq 'the import library' "$CASE_DIR/output.log" ||
    fail "${CASE}: the run must go on to the import: $(tail -n 5 "$CASE_DIR/output.log")"
echo 'PASS: an import under a new DOMAIN is not skipped as completed'

# A DOMAIN given but not valid still reaches setup.sh, which refuses it,
# instead of the archive name being written into .env beside it.
run_case invalid-domain 'DOMAIN=old.example.com' yes DOMAIN=bad_name.example.com
[ "$STATUS" -ne 0 ] || fail "${CASE}: an invalid DOMAIN must stop the setup"
grep -Fq 'Invalid domain format: bad_name.example.com' "$CASE_DIR/output.log" ||
    fail "${CASE}: setup.sh must refuse the DOMAIN given: $(grep -a -m 3 -i 'domain' "$CASE_DIR/output.log")"
[ "$(saved_domain)" = old.example.com ] ||
    fail "${CASE}: .env must keep its domain: $(domain_lines)"
! grep -Fq 'Run again with DOMAIN=' "$CASE_DIR/output.log" ||
    fail "${CASE}: a DOMAIN given must not be reported as a switch to make: $(grep -a -m 1 'Run again with DOMAIN=' "$CASE_DIR/output.log")"
! grep -Fxq 'Domain: old.example.com' "$CASE_DIR/output.log" ||
    fail "${CASE}: a DOMAIN given must not be reported as the saved domain"
echo 'PASS: a DOMAIN given but not valid is refused, not replaced by the archive name'
