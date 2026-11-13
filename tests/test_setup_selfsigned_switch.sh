#!/bin/bash
# A single site moved from Let's Encrypt or ZeroSSL to a self-signed
# certificate (SSL_CHOICE=3, for instance when it goes behind Cloudflare)
# kept the certificate acme.sh had installed in the acme-certs volume: the
# setup removed the ACME container, the Nginx entrypoint keeps any valid
# pair, and its monitor only renews a self-signed one. Nothing renewed the
# certificate, which expired within 90 days, while the setup said a
# self-signed certificate was in use. configure_mode now removes the pair
# acme.sh installed, recognised by the key acme.sh keeps, before the ACME
# container goes; Nginx generates its self-signed pair when it starts. Any
# other pair stays.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kvs-selfsigned-switch.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

functions="$WORK/functions.sh"
: > "$functions"
for name in add_compose_profile remove_compose_profile require_multi_compose_version \
    compose_files_for set_compose_file remove_env_value select_mode \
    setup_drop_acme_installed_pair configure_direct_tls_profile configure_mode; do
    awk -v signature="${name}() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$ROOT_DIR/docker/setup.sh" >> "$functions"
    grep -q "^${name}() {" "$functions" || fail "$name is not defined in docker/setup.sh"
done

# The harness: the functions of the setup, a .env writer, and a docker that
# keeps the ACME container as a marker file. "docker run" runs the script
# it is given, with /etc/nginx/ssl and /acme.sh mapped to the two volumes of
# the case, as the container borrowing the volumes of the ACME one sees them.
cat > "$WORK/harness.sh" <<'HARNESS'
RED='' GREEN='' YELLOW='' CYAN='' NC=''
set_env_value() {
    if grep -q "^$1=" .env; then
        sed -i "s|^$1=.*|$1=$2|" .env
    else
        printf '%s=%s\n' "$1" "$2" >> .env
    fi
}
version_at_least() { [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]; }
docker() {
    local arg mapped=()
    printf '%s\n' "$*" >> "$CASE/docker.log"
    case "$1" in
        ps)
            if [ "${2:-}" = -a ] && [ -e "$CASE/acme-container" ]; then
                echo "${SITE_PREFIX}-acme"
            fi
            ;;
        inspect)
            [ -e "$CASE/acme-container" ] && [ "${DOCKER_INSPECT_FAILS:-false}" = false ] || return 1
            echo sha256:acme-image
            ;;
        run)
            [ "${DOCKER_RUN_FAILS:-false}" = false ] || return 125
            [[ " $* " == *" --network none "* ]] || { echo "docker run without --network none" >&2; return 99; }
            [[ " $* " == *" --volumes-from ${SITE_PREFIX}-acme "* ]] || { echo "docker run without the ACME volumes" >&2; return 99; }
            [[ " $* " == *" --rm "* ]] || { echo "docker run without --rm" >&2; return 99; }
            while [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done
            shift
            for arg in "$@"; do
                arg=${arg/#\/etc\/nginx\/ssl/$CASE/acme-certs}
                arg=${arg/#\/acme.sh/$CASE/acme-data}
                mapped+=("$arg")
            done
            sh -c "${mapped[@]}"
            ;;
        stop) ;;
        rm) rm -f "$CASE/acme-container" ;;
        compose) [ "${2:-}" = version ] && echo "Docker Compose version v2.35.0" ;;
        *) return 64 ;;
    esac
}
HARNESS

# new_case <name> <provider before>: a single site whose ACME container
# installed the pair of key "acme" in the volume, as acme.sh lays it out.
new_case() {
    local dir="$WORK/$1"
    mkdir -p "$dir/acme-certs/site.example.com" "$dir/acme-data/site.example.com_ecc"
    printf 'MODE=single\nDOMAIN=site.example.com\nSITE_PREFIX=kvs\nSSL_PROVIDER=%s\nCOMPOSE_PROFILES=dragonfly,direct-tls\n' "$2" > "$dir/.env"
    printf 'acme key\n' > "$dir/acme-data/site.example.com_ecc/site.example.com.key"
    printf 'acme fullchain\n' > "$dir/acme-data/site.example.com_ecc/fullchain.cer"
    cp "$dir/acme-data/site.example.com_ecc/site.example.com.key" "$dir/acme-certs/site.example.com/key.pem"
    cp "$dir/acme-data/site.example.com_ecc/fullchain.cer" "$dir/acme-certs/site.example.com/cert.pem"
    : > "$dir/acme-container"
    : > "$dir/docker.log"
}

# run_configure <name> <provider>: configure_mode headless in the case's
# directory, as setup.sh calls it once the provider is chosen.
run_configure() {
    local dir="$WORK/$1"
    # shellcheck disable=SC2016
    (cd "$dir" && CASE="$dir" MODE=single DOMAIN=site.example.com SITE_PREFIX=kvs SSL_PROVIDER="$2" \
        COMPOSE_PROFILES=dragonfly,direct-tls HEADLESS=y MODE_CHOICE='' \
        bash -c 'source "$1"; source "$2"; configure_mode; echo "rc=$?"' _ "$WORK/harness.sh" "$functions") 2>&1
}

live() { echo "$WORK/$1/acme-certs/site.example.com"; }

# Let's Encrypt to self-signed: the pair acme.sh installed goes, before the
# container, and the setup says so.
new_case switch letsencrypt
out=$(run_configure switch selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "the switch to self-signed must succeed: $out"
[ ! -e "$(live switch)/cert.pem" ] && [ ! -e "$(live switch)/key.pem" ] ||
    fail "the pair acme.sh installed must be removed: $(ls -A "$(live switch)")"
grep -q 'Nginx generates a self-signed one when it starts' <<< "$out" || fail "the removal must be reported: $out"
[ ! -e "$WORK/switch/acme-container" ] || fail "the ACME container must still be removed"
run_line=$(grep -n '^run ' "$WORK/switch/docker.log" | cut -d: -f1)
rm_line=$(grep -n '^rm kvs-acme$' "$WORK/switch/docker.log" | cut -d: -f1)
[ -n "$run_line" ] && [ -n "$rm_line" ] && [ "$run_line" -lt "$rm_line" ] ||
    fail "the pair must be checked before the ACME container goes: $(cat "$WORK/switch/docker.log")"
pass "the pair acme.sh installed goes with the ACME container"

# acme.sh renewed the certificate and keeps the key: the installed pair is
# recognised by its key, whatever the certificate it holds.
new_case renewed letsencrypt
printf 'renewed fullchain\n' > "$WORK/renewed/acme-data/site.example.com_ecc/fullchain.cer"
out=$(run_configure renewed selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "the switch after a renewal must succeed: $out"
[ ! -e "$(live renewed)/key.pem" ] || fail "the pair acme.sh installed before a renewal must be removed"
pass "the pair is recognised by the key acme.sh keeps"

# An RSA certificate of an older run sits in a directory without _ecc.
new_case rsa zerossl
mv "$WORK/rsa/acme-data/site.example.com_ecc" "$WORK/rsa/acme-data/site.example.com"
out=$(run_configure rsa selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "the switch from an RSA certificate must succeed: $out"
[ ! -e "$(live rsa)/key.pem" ] || fail "the RSA pair acme.sh installed must be removed"
pass "an RSA pair acme.sh installed goes too"

# A pair from anywhere else stays: an operator's own certificate, a private
# CA, Cloudflare Origin CA, or the self-signed pair Nginx made.
new_case operator letsencrypt
printf 'operator key\n' > "$(live operator)/key.pem"
printf 'operator cert\n' > "$(live operator)/cert.pem"
out=$(run_configure operator selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "the switch with an operator pair must succeed: $out"
if ! grep -qx 'operator key' "$(live operator)/key.pem" || ! grep -qx 'operator cert' "$(live operator)/cert.pem"; then
    fail "a pair acme.sh did not install must be kept"
fi
grep -q 'Nginx generates' <<< "$out" && fail "nothing must be reported for a kept pair: $out"
[ ! -e "$WORK/operator/acme-container" ] || fail "the ACME container must be removed"
pass "a pair acme.sh did not install is kept"

# A re-run after a run cut short between the removal and the container's.
new_case rerun letsencrypt
rm -f "$(live rerun)/cert.pem" "$(live rerun)/key.pem"
out=$(run_configure rerun selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "a re-run after the removal must succeed: $out"
[ ! -e "$WORK/rerun/acme-container" ] || fail "the re-run must remove the ACME container"
pass "a re-run after the removal finishes the switch"

# Staying on Let's Encrypt keeps the pair, the container and its volumes.
new_case kept letsencrypt
out=$(run_configure kept letsencrypt)
grep -qx 'rc=0' <<< "$out" || fail "a Let's Encrypt run must succeed: $out"
cmp -s "$WORK/kept/acme-data/site.example.com_ecc/site.example.com.key" "$(live kept)/key.pem" ||
    fail "a Let's Encrypt run must keep the pair acme.sh installed"
[ -e "$WORK/kept/acme-container" ] || fail "a Let's Encrypt run must keep the ACME container"
grep -q '^run ' "$WORK/kept/docker.log" && fail "a Let's Encrypt run must not look into the volumes"
pass "a site that stays on ACME keeps its pair"

# Self-signed with no ACME container (a fresh site): nothing to look at.
new_case fresh selfsigned
rm -f "$WORK/fresh/acme-container"
out=$(run_configure fresh selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "a self-signed run without ACME must succeed: $out"
grep -q -E '^(run|inspect) ' "$WORK/fresh/docker.log" && fail "nothing must be read without an ACME container: $(cat "$WORK/fresh/docker.log")"
[ -e "$(live fresh)/key.pem" ] || fail "nothing must be removed without an ACME container"
pass "a site without an ACME container is left alone"

# Multi mode: Caddy serves TLS, the volume of Nginx is not looked at.
new_case multi letsencrypt
out=$(cd "$WORK/multi" && CASE="$WORK/multi" MODE=multi DOMAIN=site.example.com SITE_PREFIX=kvs SSL_PROVIDER=selfsigned \
    bash -c 'source "$1"; source "$2"; setup_drop_acme_installed_pair; echo "rc=$?"' _ "$WORK/harness.sh" "$functions" 2>&1)
grep -qx 'rc=0' <<< "$out" || fail "multi mode must not fail: $out"
[ -e "$(live multi)/key.pem" ] || fail "multi mode must not remove the pair"
grep -q '^run ' "$WORK/multi/docker.log" && fail "multi mode must not look into the volumes"
pass "multi mode is left alone"

# A check that cannot run stops the setup before the container goes, so a
# re-run tries again.
new_case failed letsencrypt
out=$(DOCKER_RUN_FAILS=true run_configure failed selfsigned)
grep -qx 'rc=0' <<< "$out" && fail "a failed check must fail configure_mode: $out"
grep -q 'Could not check the certificate kvs-acme installed' <<< "$out" || fail "a failed check must be reported: $out"
[ -e "$WORK/failed/acme-container" ] || fail "a failed check must keep the ACME container for the re-run"
[ -e "$(live failed)/key.pem" ] || fail "a failed check must not remove the pair"
new_case uninspectable letsencrypt
out=$(DOCKER_INSPECT_FAILS=true run_configure uninspectable selfsigned)
grep -qx 'rc=0' <<< "$out" && fail "an ACME container that cannot be inspected must fail configure_mode: $out"
[ -e "$WORK/uninspectable/acme-container" ] || fail "an ACME container that cannot be inspected must be kept for the re-run"
[ -e "$(live uninspectable)/key.pem" ] || fail "an ACME container that cannot be inspected must not lose its pair"
pass "a check that cannot run stops before the ACME container goes"
