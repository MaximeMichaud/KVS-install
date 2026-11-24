#!/bin/bash
# Exercise the manager's route and live-proxy checks without starting a stack.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
install=$(mktemp -d)
trap 'rm -rf "$install"' EXIT
work=$install/docker
mkdir "$work"
(cd "$root/docker" && cp --parents images.lock bin/resolve-bases.sh lib/host-validation.sh lib/kvs-php.sh init/lib/kvs-archive.sh \
    multi-site/site-manager.sh multi-site/docker-compose.site.yml.template "$work")
manager=$work/multi-site/site-manager.sh
routes=$work/multi-site/caddy/sites
site=$work/multi-site/sites/site.example
export work KVS_WEBROOT_BASE=$work/www
mkdir -p "$routes" "$work/kvs-archive"
python3 "$root/tests/fixtures/kvs-prefix-archive.py" "$work/kvs-archive/KVS_test.zip"
unset ACME_EMAIL CADDY_TLS_MODE
fail() { cat "$work/out" >&2; echo "FAIL: $*" >&2; exit 1; }
# shellcheck disable=SC2329  # Used by the manager.
chown() { :; }
# shellcheck disable=SC2329
docker() {
    printf '%s\n' "$*" >> "$work/calls"
    case "$*" in
        'ps --format {{.Names}}') echo kvs-caddy ;;
        'ps '*|'volume '*) return 0 ;;
        'inspect --format '*ACME_EMAIL*' kvs-caddy')
            if grep -Fxq 'compose stop cron' "$work/calls" &&
                flock -n "$work/multi-site/.locks/.routes" true; then
                touch "$work/unlocked"
            fi
            printf '%s\n' "$3" > "$work/inspect-template"
            cat "$work/live" || return 1
            if [[ -f $work/next ]]; then mv "$work/next" "$work/live"; fi ;;
        'compose --profile setup config --format json kvs-init')
            printf '{"services":{"kvs-init":{"volumes":[{"type":"bind","source":"%s","target":"/kvs-archive/KVS_test.zip"}]}}}\n' \
                "$work/kvs-archive/KVS_test.zip" ;;
        'compose '*|'exec kvs-caddy caddy reload '*) return 0 ;;
        *) return 90 ;;
    esac
}
export -f docker chown
check() {
    local expected=$1 rc=0
    shift
    : > "$work/calls"
    bash "$manager" "$@" > "$work/out" 2>&1 || rc=$?
    [[ $rc == "$expected" ]] || fail "$*: expected $expected, got $rc"
}
# The new public site does not appear in the routes directory yet.
check 1 add site.example
grep -Fq 'No ACME email for Caddy' "$work/out" || fail 'wrong reason for refusing add'
[[ ! -e $site && ! -e $work/www/site.example && ! -e $routes/site.example.caddy ]] || fail 'partial public add'
# An unrelated public block must not turn an internal add into a public one.
printf 'other.example {\n    respond ok\n}\n' > "$routes/other.caddy"
CADDY_TLS_MODE=internal check 0 add site.example
rm "$routes/other.caddy"
check 0 caddy-acme-check
route=$routes/site.example.caddy
printf 'site.example {\n    tls internal\n}\npublic.example {\n    respond "public"\n}\n' > "$route"
check 1 caddy-acme-check
for bad in admin@example.com x@EXAMPLE.NET x@example.org x@sub.TEST x@sub.Example x@sub.invalid x@sub.LOCALHOST \
    x@-.example.com x@a..example.com x@site.xn--x- 'oops' '.dot@sub.example.com' 'dot..dot@sub.example.com'; do
    ACME_EMAIL=$bad check 1 caddy-acme-check
done
# Check both independent address limits using otherwise valid DNS labels.
printf -v label '%063d' 0
printf -v mailbox '%064d' 0
long_host=$label.$label.${label:0:49}.example.com
ACME_EMAIL=$mailbox@$long_host check 0 caddy-acme-check
ACME_EMAIL=$mailbox@${long_host%.example.com}x.example.com check 1 caddy-acme-check
ACME_EMAIL=${mailbox}x@sub.example.com check 1 caddy-acme-check
ACME_EMAIL=dev@localhost.LOCAL check 1 caddy-acme-check
mv "$work/lib/host-validation.sh" "$work/validator"
ACME_EMAIL=x@sub.example.com check 1 caddy-acme-check
grep -Fq 'lib/host-validation.sh' "$work/out" || fail 'missing validator not identified'
if grep -Fq 'No ACME email' "$work/out"; then fail 'missing library reported as a bad address'; fi
mv "$work/validator" "$work/lib/host-validation.sh"
ACME_EMAIL=x@sub.Example.COM check 0 caddy-acme-check
printf 'site.example {\n    tls %s\n}\n' ops@sub.example.com > "$route"
check 0 caddy-acme-check
sed -i 's/sub.example.com/example.com/' "$route"
ACME_EMAIL=x@sub.example.com check 1 caddy-acme-check
printf 'internal.example {\n    tls internal\n}\nhttp://plain.example {\n    respond ok\n}\nplain.example:80 {\n    respond ok\n}\n' > "$route"
ACME_EMAIL=dev@localhost.local check 0 caddy-acme-check
# Exercise setup's own policy for the development mailbox in both modes.
eval "$(sed -n '/^validate_email() {/,/^}/p' "$root/docker/setup.sh")"
# shellcheck source=docker/lib/host-validation.sh
source "$root/docker/lib/host-validation.sh"
SSL_PROVIDER=selfsigned validate_email dev@localhost.local || fail 'internal setup rejected the dev mailbox'
if SSL_PROVIDER=letsencrypt validate_email dev@localhost.LOCAL; then fail 'public setup accepted .local'; fi
# Imported TLS settings belong to the block that imports them.
cat > "$route" <<'CADDY'
(site-tls) {
    tls {args[0]}
}
site.example {
    import site-tls internal
}
public.example {
    import site-tls ops@sub.example.com
}
CADDY
check 0 caddy-acme-check
sed -i 's/ops@sub.example.com/ops@example.com/' "$route"
ACME_EMAIL=x@sub.example.com check 1 caddy-acme-check
printf 'site.example {\n    tls "/path with spaces/cert.pem" /key.pem\n}\n' > "$route"
check 0 caddy-acme-check
printf 'public.example {\n    respond "public"\n}\n' >> "$route"
check 1 caddy-acme-check

echo EMAIL=ops@sub.example.com > "$work/.env"
for bad in ACME_EMAIL=admin@example.com '' ACME_EMAIL=incorrect; do
    echo "$bad" > "$work/live"
    check 1 start site.example
    if [[ $bad == ACME_EMAIL=admin@example.com ]]; then
        grep -Fq 'The running Caddy still uses the example contact. Run site-manager.sh caddy-start, then retry.' "$work/out" ||
            fail 'missing live-proxy recovery command'
    fi
    if grep -Eq 'compose .*down|compose stop cron|docker-compose.caddy.yml up|caddy reload' "$work/calls"; then
        fail 'start changed services before refusing the live contact'
    fi
done
rm "$work/live"
check 1 start site.example
grep -Fq 'inspect' "$work/out" || fail 'inspection failure treated as a missing contact'
echo ACME_EMAIL=ops@sub.example.com > "$work/live"
echo ACME_EMAIL=admin@example.com > "$work/next"
KVS_ADMIN_PASSWORD=fixture check 1 start site.example
grep -Fxq 'compose stop cron' "$work/calls" || fail 'start failed before the proxy replacement'
if grep -Fq 'caddy reload' "$work/calls"; then fail 'start reloaded a replacement with the example contact'; fi
echo ACME_EMAIL=ops@sub.example.com > "$work/live"
KVS_ADMIN_PASSWORD=fixture check 0 start site.example
grep -Fq 'caddy reload' "$work/calls" || fail 'missing reload'
[[ ! -e $work/unlocked ]] || fail 'live contact rechecked outside the route lock'
image=$(awk '/^    image: caddy:/{print $2}' "$root/docker/multi-site/docker-compose.caddy.yml")
if command docker image inspect "$image" >/dev/null 2>&1 ||
    { [[ ${CI:-} == true ]] && command docker pull -q "$image" >/dev/null; }; then
    printf 'site.example {\n    tls ops@sub.example.com\n}\ninternal.example {\n    tls internal\n}\n' > "$route"
    command docker run --network none --pull never --rm -i -v "$routes:/etc/caddy/sites:ro" \
        "$image" caddy adapt --adapter caddyfile --config - < "$root/docker/multi-site/caddy/Caddyfile" > "$work/adapted"
    jq -e '.apps.tls.automation.policies |
        any(.[]; .subjects == ["site.example"] and any(.issuers[]; .email == "ops@sub.example.com")) and
        any(.[]; .subjects == ["internal.example"] and any(.issuers[]; .module == "internal"))' "$work/adapted" >/dev/null
    (
        id=$(command docker create --network none --pull never -e ACME_EMAIL=first@sub.example.com \
            -e ACME_EMAIL=ops@sub.example.com -e ACME_EMAIL_X=unrelated "$image")
        trap 'command docker rm -v "$id" >/dev/null' EXIT
        setting=$(command docker inspect --format "$(cat "$work/inspect-template")" "$id")
        [[ $setting == ACME_EMAIL=ops@sub.example.com ]] || fail 'wrong live contact from Docker inspect'
    )
    echo 'PASS: pinned Caddy per-host policies and Docker inspect template'
elif [[ ${CI:-} == true ]]; then
    fail "Pinned Caddy image $image could not be loaded for the engine checks"
else
    echo 'SKIP: pinned Caddy image unavailable locally for adapt and Docker inspect'
fi
echo 'PASS: Caddy contacts checked per block, before add, before stopping cron and before reload'
