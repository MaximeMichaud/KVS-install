#!/bin/bash
# The domain and email checks ended their pattern with [a-z]{2,} or
# [a-zA-Z]{2,}, which rejects every punycode (IDN) TLD such as xn--p1ai, so a
# valid internationalised domain or email could not be installed. The same
# pattern lived in six places across three files; each now also accepts an
# xn-- label (in kvs-install.sh one that does not end with a hyphen, and in
# either case for an email). The Docker install's archive-name reader also
# stopped treating a renamed archive's whole file name as a domain, and a
# DOMAIN from the environment is left for setup.sh to apply, so it still sees
# the domain .env had and notices a change.
set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$TEST_DIR/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Behavioural: extract a file's functions and exercise them in their own shell
# (validate_domain/validate_email exist in two files, so keep them apart).
extract() {
    local file=$1 fn
    shift
    for fn in "$@"; do
        awk -v f="$fn" '$0 ~ "^(function )?" f "\\(\\) \\{" {c=1} c {print} c && /^}/ {exit}' \
            "$ROOT_DIR/$file"
    done
}

# kvs-install.sh: domain and email validators and the archive-name reader.
extract kvs-install.sh validate_kvs_domain email_is_valid archive_domain_from_name > "$WORK/kvs.sh"
# docker/setup.sh and docker/reconfigure.sh: their domain and email validators.
extract docker/setup.sh validate_domain validate_email > "$WORK/setup.sh"
extract docker/reconfigure.sh validate_domain validate_email > "$WORK/reconf.sh"

check_domain_file() {
    local src=$1 fn=$2
    # shellcheck disable=SC1090
    bash -c '
        source "$1"
        '"$fn"' "xn--e1afmkfd.xn--p1ai" || { echo "fail: all-punycode"; exit 1; }
        '"$fn"' "sub.example.xn--90ais"  || { echo "fail: mixed punycode"; exit 1; }
        '"$fn"' "example.com"            || { echo "fail: plain"; exit 1; }
        '"$fn"' "nodot"                  && { echo "fail: accepted a name with no TLD"; exit 1; }
        echo ok
    ' _ "$src"
}

check_email_file() {
    local src=$1 fn=$2
    bash -c '
        source "$1"
        '"$fn"' "user@example.xn--p1ai"  || { echo "fail: punycode email"; exit 1; }
        '"$fn"' "ops@example.com"         || { echo "fail: plain email"; exit 1; }
        '"$fn"' "not-an-email"            && { echo "fail: accepted a non-email"; exit 1; }
        echo ok
    ' _ "$src"
}

[ "$(check_domain_file "$WORK/kvs.sh" validate_kvs_domain)" = ok ] ||
    fail "validate_kvs_domain does not accept punycode domains"
[ "$(check_email_file "$WORK/kvs.sh" email_is_valid)" = ok ] ||
    fail "the kvs-install.sh email check does not accept a punycode TLD"
# A label cannot end with a hyphen, and an email domain is case-insensitive.
bash -c 'source "$1"; validate_kvs_domain "example.xn--p1ai-"' _ "$WORK/kvs.sh" &&
    fail "validate_kvs_domain accepted a punycode label ending with a hyphen"
bash -c 'source "$1"; email_is_valid "user@example.xn--"' _ "$WORK/kvs.sh" &&
    fail "the email check accepted an empty punycode label"
bash -c 'source "$1"; email_is_valid "User@Example.XN--P1AI"' _ "$WORK/kvs.sh" ||
    fail "the email check refused an uppercase punycode TLD"
[ "$(check_domain_file "$WORK/setup.sh" validate_domain)" = ok ] ||
    fail "docker/setup.sh validate_domain does not accept punycode domains"
[ "$(check_email_file "$WORK/setup.sh" validate_email)" = ok ] ||
    fail "docker/setup.sh validate_email does not accept a punycode TLD"
[ "$(check_domain_file "$WORK/reconf.sh" validate_domain)" = ok ] ||
    fail "docker/reconfigure.sh validate_domain does not accept punycode domains"
[ "$(check_email_file "$WORK/reconf.sh" validate_email)" = ok ] ||
    fail "docker/reconfigure.sh validate_email does not accept a punycode TLD"

# archive_domain_from_name: a bracketed name yields the domain, a renamed
# archive yields nothing (so a valid install is no longer blocked), and the
# result is lowercased.
read_name() {
    bash -c 'source "$1"; archive_domain_from_name "$2"' _ "$WORK/kvs.sh" "$1"
}
[ "$(read_name 'KVS_7.0.3_[sub.example.xn--90ais].zip')" = "sub.example.xn--90ais" ] ||
    fail "the domain must be read from the archive name brackets"
[ -z "$(read_name 'KVS_7.0.3.zip')" ] ||
    fail "a renamed archive with no brackets must yield no domain"
[ "$(read_name 'KVS_7.0.3_[EXAMPLE.COM].zip')" = "example.com" ] ||
    fail "the archive-name domain must be lowercased"

# A DOMAIN from the environment must not be written into .env before setup.sh
# runs: setup.sh compares it with the domain .env holds to notice a change (a
# site imported again under a new name), and finds none once they match. The
# stub setup.sh reads both the way docker/setup.sh does.
if ! command -v unzip > /dev/null 2>&1 || ! command -v python3 > /dev/null 2>&1; then
    echo "ok - unzip or python3 is not installed here, the Docker case is left to the CI runner"
    exit 0
fi
mkdir -p "$WORK/kvs/.git" "$WORK/kvs/docker/kvs-archive" "$WORK/backup"
printf 'DOMAIN=old.example.com\nKVS_IMPORT_COMPLETED=1\n' > "$WORK/kvs/docker/.env"
python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.writestr("index.php", "x\n"); z.close()' \
    "$WORK/kvs/docker/kvs-archive/KVS_7.0.3_[new.example.com].zip"
cat > "$WORK/kvs/docker/setup.sh" << 'EOF'
#!/bin/bash
KVS_DOMAIN_OVERRIDE="${DOMAIN:-}"
source .env
echo "SETUP previous=${DOMAIN,,} override=${KVS_DOMAIN_OVERRIDE,,}"
EOF
chmod +x "$WORK/kvs/docker/setup.sh"
# shellcheck disable=SC2034,SC2329 # read and called by dockerInstall
(
    # The domain is set but not exported, as a caller's shell variable may be.
    DOMAIN=New.Example.com
    export KVS_INSTALL_DIR="$WORK/kvs" KVS_BACKUP_DIR="$WORK/backup"
    # shellcheck disable=SC1091
    source "$ROOT_DIR/kvs-install.sh"
    docker() { return 0; }
    refuse_during_kvsctl_run() { return 0; }
    recover_kvsctl_data() { return 0; }
    refuse_kvsctl_managed_install() { return 0; }
    ensure_docker_prerequisites() { return 0; }
    update_kvs_install() { return 0; }
    dockerInstall
) > "$WORK/docker.out" 2>&1 || fail "dockerInstall failed: $(tail -n 3 "$WORK/docker.out")"
grep -qx 'DOMAIN=old.example.com' "$WORK/kvs/docker/.env" ||
    fail "the environment DOMAIN must not be written into .env before setup.sh: $(grep '^DOMAIN=' "$WORK/kvs/docker/.env")"
grep -qx 'SETUP previous=old.example.com override=new.example.com' "$WORK/docker.out" ||
    fail "setup.sh must see the saved domain and the new one: $(grep SETUP "$WORK/docker.out")"

echo "ok - domain and email checks accept punycode TLDs and the archive name reader is safe"
