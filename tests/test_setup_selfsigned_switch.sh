#!/bin/bash
# A single site moved from Let's Encrypt or ZeroSSL to a self-signed
# certificate (SSL_CHOICE=3, for instance when it goes behind Cloudflare)
# kept the certificate acme.sh had installed in the acme-certs volume: the
# setup removed the ACME container, the Nginx entrypoint keeps any valid
# pair, and its monitor only renews a self-signed one. Nothing renewed the
# certificate, which expired within 90 days, while the setup said a
# self-signed certificate was in use. configure_mode now removes the pair
# acme.sh installed, matched against both files acme.sh keeps, before the ACME
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
for name in add_compose_profile remove_compose_profile compose_version_at_least require_multi_compose_version \
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
docker() {
    local arg mapped=()
    printf '%s\n' "$*" >> "$CASE/docker.log"
    case "$1" in
        ps)
            if [ "${2:-}" = -a ] && [ -e "$CASE/acme-container" ]; then
                echo "${SITE_PREFIX}-acme"
            fi

            ;;
        image)
            [ "$*" = 'image inspect --format {{.Id}} origin:test' ] || return 1
            echo sha256:origin-image ;;
        volume)
            if [ "$2" = ls ]; then
                [ "$*" = 'volume ls -q --filter label=com.docker.compose.project=kvs --filter label=com.docker.compose.volume=cache' ] || return 91
                if [ -e "$CASE/legacy" ] && [ -d "$CASE/acme-data" ]; then
                    printf '%s\n' "${LABELLED_VOLUME:-override-cache}"
                fi
                return 0
            fi
            [ -e "$CASE/legacy" ] || return 1
            [ "$*" = 'volume inspect --format {{if and (eq .Driver "local") (not .Options)}}{{.Mountpoint}}{{end}} override-cache' ] || return 91
            [ -d "$CASE/acme-data" ] || return 1
            echo "$CASE/acme-data" ;;
        inspect)
            [ -e "$CASE/acme-container" ] && [ "${DOCKER_INSPECT_FAILS:-false}" = false ] || return 1
            echo sha256:acme-image
            ;;
        run)
            [ "${DOCKER_RUN_FAILS:-false}" = false ] || return 125
            [[ " $* " == *" --network none "* ]] || { echo "docker run without --network none" >&2; return 99; }
            if [ -e "$CASE/legacy" ]; then
                [[ " $* " == *" --mount type=bind,source=$CASE/acme-certs,target=/etc/nginx/ssl "* && " $* " == *" --mount type=bind,source=$CASE/acme-data,target=/acme.sh,readonly "* && " $* " == *' sha256:origin-image '* ]] || return 99
            else
                [[ " $* " == *" --volumes-from ${SITE_PREFIX}-acme "* ]] || return 99
            fi
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
        compose)
            case "$*" in
                'compose version') echo "Docker Compose version v2.35.0" ;;
                'compose --profile direct-tls config acme nginx')
                    cat <<MODEL
name: kvs
services:
  nginx:
    image: origin:test
    volumes:
      - type: bind
        source: $CASE/acme-certs
        target: /etc/nginx/ssl
${LIVE_MOUNT_EXTRA:-}
  acme:
    volumes:
      - type: ${CACHE_TYPE:-volume}
        source: ${CACHE_SOURCE:-cache}
        target: /acme.sh
volumes:
  cache:
    name: override-cache
MODEL
                    ;;
                *) return 64 ;;
            esac ;;
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

# A certificate replaced independently of the cached chain may reuse its key.
new_case renewed letsencrypt
printf 'different fullchain\n' > "$(live renewed)/cert.pem"
out=$(run_configure renewed selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "$out"
grep -q 'Keeping the TLS files' <<< "$out" || fail "no ambiguity reported: $out"
grep -qx 'different fullchain' "$(live renewed)/cert.pem" || fail "operator certificate lost"
[ -s "$(live renewed)/key.pem" ] || fail "operator key lost"

new_case legacy selfsigned
rm "$WORK/legacy/acme-container"
touch "$WORK/legacy/legacy"
out=$(run_configure legacy selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "$out"
[ ! -e "$(live legacy)/cert.pem" ] && [ ! -e "$(live legacy)/key.pem" ] || fail "old ACME pair retained"
out=$(run_configure legacy selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "$out"

# A pair of dangling links is ambiguous and must be reported.
new_case dangling selfsigned
for file in cert.pem key.pem; do
    rm "$(live dangling)/$file"
    ln -s "unavailable-$file" "$(live dangling)/$file"
done
out=$(run_configure dangling selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "$out"
grep -q 'Keeping the TLS files' <<< "$out" || fail "unreported dangling pair: $out"
for file in key.pem cert.pem; do
    [ -L "$(live dangling)/$file" ] || fail "dangling TLS link changed: $file"
done

new_case absent selfsigned
rm "$WORK/absent/acme-container"
touch "$WORK/absent/legacy"
mv "$WORK/absent/acme-data" "$WORK/absent/elsewhere"
out=$(run_configure absent selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "$out"
[ ! -e "$WORK/absent/acme-data" ] && [ -e "$(live absent)/key.pem" ] || fail "missing cache or live key changed"
! grep -q 'Keeping the TLS' <<< "$out" || fail "no cache should be silent: $out"
! grep -q '^run ' "$WORK/absent/docker.log" || fail "a missing cache was mounted"

for source in acme-data acme-certs; do
    name=missing-bind-$source
    new_case "$name" selfsigned
    dir=$WORK/$name
    rm "$dir/acme-container"
    touch "$dir/legacy"
    mv "$dir/$source" "$dir/removed-bind"
    out=$(CACHE_TYPE=bind CACHE_SOURCE="$dir/acme-data" run_configure "$name" selfsigned)
    grep -qx 'rc=0' <<< "$out" || fail "missing $source bind blocked setup: $out"
    ! grep -q '^run ' "$dir/docker.log" || fail "attempted to mount the missing $source bind"
    [ ! -e "$dir/$source" ] || fail "recreated the missing $source bind"
done
pass "missing cache and live bind directories skip the legacy comparison"

new_case wrong-label selfsigned
rm "$WORK/wrong-label/acme-container"
touch "$WORK/wrong-label/legacy"
out=$(LABELLED_VOLUME=another-cache run_configure wrong-label selfsigned)
grep -qx 'rc=0' <<< "$out" || fail "$out"
grep -Fq 'labelled volumes for /acme.sh disagree with Compose (override-cache)' <<< "$out" || fail "$out"
! grep -Eq '^volume inspect |^run ' "$WORK/wrong-label/docker.log" || fail "used a different labelled volume"
for file in cert.pem key.pem; do [ -s "$(live wrong-label)/$file" ] || fail "removed $file"; done
pass "a mismatched labelled volume is reported before inspection and both live files stay"

for detail in '        read_only: true' $'        volume:\n          subpath: old'; do
    new_case overridden selfsigned
    rm "$WORK/overridden/acme-container"
    touch "$WORK/overridden/legacy"
    out=$(LIVE_MOUNT_EXTRA="$detail" run_configure overridden selfsigned)
    case "$detail" in *read_only*) reason=read-only ;; *) reason='subpath old' ;; esac
    grep -Fq "$reason" <<< "$out" || fail "missing mount reason: $out"
    grep -Fq '/etc/nginx/ssl' <<< "$out" || fail "missing mount path: $out"
    [ -s "$(live overridden)/cert.pem" ] || fail "changed an unsupported mount"
done

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
grep -Eq 'Keeping the TLS|Nginx generates' <<< "$out" && fail "nothing must be reported for a kept pair: $out"
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
grep -q 'Could not check the certificate installed for site.example.com' <<< "$out" || fail "a failed check must be reported: $out"
[ -e "$WORK/failed/acme-container" ] || fail "a failed check must keep the ACME container for the re-run"
[ -e "$(live failed)/key.pem" ] || fail "a failed check must not remove the pair"
new_case uninspectable letsencrypt
out=$(DOCKER_INSPECT_FAILS=true run_configure uninspectable selfsigned)
grep -qx 'rc=0' <<< "$out" && fail "an ACME container that cannot be inspected must fail configure_mode: $out"
[ -e "$WORK/uninspectable/acme-container" ] || fail "an ACME container that cannot be inspected must be kept for the re-run"
[ -e "$(live uninspectable)/key.pem" ] || fail "an ACME container that cannot be inspected must not lose its pair"
pass "a check that cannot run stops before the ACME container goes"
