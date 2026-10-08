#!/bin/bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$TEST_DIR/lib" "$TEST_DIR/bin" "$TEST_DIR/site/admin/data/plugins/external_search" "$TEST_DIR/api"
cp "$ROOT_DIR/docker/reconfigure.sh" "$TEST_DIR/"
cp "$ROOT_DIR/docker/lib/"{database,manticore}.sh "$TEST_DIR/lib/"
touch "$TEST_DIR/docker-compose.yml"
cat > "$TEST_DIR/.env" <<'ENV'
DOMAIN=example.com
SITE_PREFIX=kvs-test
MARIADB_PASSWORD=test-only
ENABLE_MANTICORE=false
COMPOSE_PROFILES=redis,direct-tls
ENV
# The manticore-data volume is $TEST_ROOT/volume: a request for a rebuild
# lands there, and a start of the container consumes it the way the
# entrypoint does, unless TEST_START_KEEPS_REQUEST says the start did not.
# At some starts searchd offers TLS it cannot complete: a client that
# accepts the offer fails there, as the image's client does by default.
# TEST_TABLES lists the tables searchd serves; TEST_BUILD_FAILED and
# TEST_REBUILD_FAILED are what the entrypoint recorded. TEST_REQUESTED_BUILD
# says the start of the container builds every index on the request in the
# volume, a build that ends at the TEST_BUILD_ENDS_AFTER-th look at the
# request. The Compose takes "run --build", and the stack builds its
# manticore image, as one without a release override does.
cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/calls"
case "$*" in
    'compose version') echo 'Docker Compose version v2.40.3' ;;
    'compose --profile manticore config manticore') printf '%s\n' services: '  manticore:' '    build:' '      context: manticore' ;;
    'compose exec -T mariadb sh -c '*) exit 0 ;;
    'compose --profile manticore build manticore') exit "${TEST_BUILD_FAILURE:-0}" ;;
    'compose --profile manticore run --rm --no-deps -T --entrypoint touch manticore /var/lib/manticore/kvs-rebuild-before-start')
        [ "${TEST_REQUEST_FAILURE:-no}" != yes ] || exit 1
        touch "$TEST_ROOT/volume/kvs-rebuild-before-start" ;;
    'compose --profile manticore rm --stop --force manticore') exit 0 ;;
    'compose --profile manticore up '*)
        [ "${TEST_UP_FAILURE:-0}" = 0 ] || exit "$TEST_UP_FAILURE"
        [ "${TEST_START_KEEPS_REQUEST:-no}" = yes ] || rm -f "$TEST_ROOT/volume/kvs-rebuild-before-start" ;;
    'compose --profile manticore exec -T manticore mysql '*)
        [[ " $* " == *' --skip-ssl '* ]] ||
            { echo 'ERROR 2026 (HY000): TLS/SSL error: sslv3 alert handshake failure' >&2; exit 1; }
        [ "${TEST_INDEX_FAILURE:-no}" != yes ] || exit 1
        for table in ${TEST_TABLES:-videos albums searches}; do printf 'example_com_%s\tplain\n' "$table"; done ;;
    'compose --profile manticore exec -T manticore test ! -e /var/lib/manticore/kvs-rebuild-before-start')
        if [ -n "${TEST_BUILD_ENDS_AFTER:-}" ]; then
            echo look >> "$TEST_ROOT/looks"
            [ "$(wc -l < "$TEST_ROOT/looks")" -lt "$TEST_BUILD_ENDS_AFTER" ] ||
                rm -f "$TEST_ROOT/volume/kvs-rebuild-before-start"
        fi
        [ ! -e "$TEST_ROOT/volume/kvs-rebuild-before-start" ] ;;
    'compose --profile manticore exec -T manticore sh -c test -e "$1" && test -e "$2" sh /var/run/manticore/kvs-requested-build /var/lib/manticore/kvs-rebuild-before-start')
        [ "${TEST_REQUESTED_BUILD:-no}" = yes ] && [ -e "$TEST_ROOT/volume/kvs-rebuild-before-start" ] ;;
    'compose --profile manticore exec -T manticore cat /var/run/manticore/kvs-build-failed /var/run/manticore/kvs-rebuild-failed')
        status=0
        for recorded in "${TEST_BUILD_FAILED:-}" "${TEST_REBUILD_FAILED:-}"; do
            if [ -n "$recorded" ]; then printf '%s\n' "$recorded"; else status=1; fi
        done
        exit "$status" ;;
    'compose --profile manticore ps -a -q manticore') echo fixture ;;
    inspect*) echo "${TEST_CONTAINER_STATE:-0 exited}" ;;
    'compose --profile manticore ps -a manticore'|'compose --profile manticore stop manticore') exit 0 ;;
    'compose --profile manticore logs '*) exit 0 ;;
    'compose --profile setup run '*)
        [ "${TEST_INIT_FAILURE:-no}" != yes ] || exit 1
        if [[ "$*" == *ENABLE_MANTICORE=true* ]]; then
            php -r '
                $data=[];
                foreach (["videos"=>"", "albums"=>"_albums", "searches"=>"_searches"] as $kind=>$suffix) {
                    $data["enable_external_search".$suffix]=1;
                    $data["display_results".$suffix]=0;
                    $data["api_call".$suffix]="http://manticore-api:8080/kvs_manticore_search_".$kind.".php?query=%QUERY%&limit=%LIMIT%&from=%FROM%";
                    touch(getenv("TEST_ROOT")."/api/kvs_manticore_search_".$kind.".php");
                }
                file_put_contents(getenv("TEST_ROOT")."/site/admin/data/plugins/external_search/data.dat",serialize($data));
            '
        else
            rm -f "$TEST_ROOT/site/admin/data/plugins/external_search/data.dat" "$TEST_ROOT"/api/*.php
        fi ;;
    'compose exec -T php-fpm php -r '*)
        code=${7//\/var\/www\/kvs/$TEST_ROOT/site}
        code=${code//\/var\/www\/manticore-api/$TEST_ROOT/api}
        php -r "$code" "${8}" ;;
    *) echo "Unexpected Docker call: $*" >&2; exit 90 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/docker"
mkdir "$TEST_DIR/volume"
# The line number of the first call that starts with $1, 0 when none does.
call_line() { awk -v call="$1" 'index($0, call) == 1 { print NR; found = 1; exit } END { if (!found) print 0 }' calls; }
export TEST_ROOT="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH"
cd "$TEST_DIR"
# A fresh process reloads .env and reads the serialized plugin configuration.
bash reconfigure.sh --manticore enable > enabled.log 2>&1 || { cat enabled.log; fail enable; }
grep -Fxq 'ENABLE_MANTICORE=true' .env || fail 'enable was not persisted'
grep -Fxq 'COMPOSE_PROFILES=redis,direct-tls,manticore' .env || fail 'enable lost other profiles'
# The volume may keep indexes from before search was disabled: enable asks
# the start for a build from the database, removes a container that read the
# volume before the request, and switches KVS only once searchd answers with
# no request left.
build=$(call_line 'compose --profile manticore build manticore')
request=$(call_line 'compose --profile manticore run --rm --no-deps -T --entrypoint touch manticore /var/lib/manticore/kvs-rebuild-before-start')
removal=$(call_line 'compose --profile manticore rm --stop --force manticore')
start=$(call_line 'compose --profile manticore up -d --no-deps manticore')
pending=$(call_line 'compose --profile manticore exec -T manticore test ! -e /var/lib/manticore/kvs-rebuild-before-start')
plugin=$(call_line 'compose --profile setup run ')
[ "$request" -gt 0 ] || fail 'enable did not ask for a rebuild from the database before Manticore answers'
[ "$build" -gt 0 ] && [ "$build" -lt "$request" ] || fail 'enable must build the image before it runs it to ask for the rebuild'
[ "$removal" -gt "$request" ] && [ "$start" -gt "$removal" ] ||
    fail 'enable must remove the container after the request and start a new one after that'
[ "$pending" -gt "$start" ] && [ "$plugin" -gt "$pending" ] ||
    fail 'enable switched KVS before it saw the requested build done'
grep -Fq 'Indexes built from the current database' enabled.log || fail 'enable did not say the indexes come from the current database'
bash reconfigure.sh --manticore status > status.log 2>&1 || { cat status.log; fail 'enabled status'; }
bash reconfigure.sh --manticore enable > repeated.log 2>&1 || fail 'repeated enable'
[ "$(grep -c '^COMPOSE_PROFILES=' .env)" = 1 ] || fail 'duplicate profiles setting'
# A rebuild behind searchd that failed is a failed status, with its reason,
# and so is a build before searchd that failed on a table, which searchd
# then does not serve.
if TEST_REBUILD_FAILED='2026-10-06T10:00:00Z Background index rebuild failed, searchd keeps the previous indexes' \
    bash reconfigure.sh --manticore status > status.log 2>&1; then
    fail 'status passed although the rebuild behind searchd failed'
fi
grep -Fq 'index: 2026-10-06T10:00:00Z Background index rebuild failed' status.log ||
    fail "status did not print why the rebuild failed: $(cat status.log)"
if grep -Fq 'Verified:' status.log; then fail 'status verified search after a failed rebuild'; fi
if TEST_BUILD_FAILED='2026-10-06T10:00:00Z Initial indexing failed on some tables' TEST_TABLES='videos albums' \
    bash reconfigure.sh --manticore status > status.log 2>&1; then
    fail 'status passed although the build before searchd failed on a table'
fi
grep -Fq 'index: 2026-10-06T10:00:00Z Initial indexing failed on some tables' status.log ||
    fail "status did not print why the build before searchd failed: $(cat status.log)"
bash reconfigure.sh --manticore disable > disabled.log 2>&1 || { cat disabled.log; fail disable; }
grep -Fxq 'ENABLE_MANTICORE=false' .env || fail 'disable was not persisted'
grep -Fxq 'COMPOSE_PROFILES=redis,direct-tls' .env || fail 'disable lost other profiles'
bash reconfigure.sh --manticore status > status.log 2>&1 || fail 'disabled status'
[ ! -e site/admin/data/plugins/external_search/data.dat ] || fail 'plugin still enabled'
cp .env expected.env
for mode in UP INDEX INIT BUILD REQUEST; do
    case "$mode" in UP|BUILD) value=1 ;; *) value=yes ;; esac
    if env "TEST_${mode}_FAILURE=$value" bash reconfigure.sh --manticore enable > failure.log 2>&1; then
        fail "$mode failure accepted"
    fi
    cmp .env expected.env || fail "$mode failure changed saved search settings"
    [ ! -e site/admin/data/plugins/external_search/data.dat ] || fail "$mode failure switched the plugin"
done
# A requested build that failed on a table leaves searchd up without it,
# and the request in place: enable says why at once, instead of waiting out
# MANTICORE_WAIT_SECONDS for a table that will not come, and KVS is not
# switched.
rm -f volume/kvs-rebuild-before-start
status=0
TEST_START_KEEPS_REQUEST=yes TEST_CONTAINER_STATE='0 running' TEST_TABLES='videos albums' \
    TEST_BUILD_FAILED='2026-10-06T10:00:00Z The requested index rebuild failed on some tables' \
    MANTICORE_WAIT_SECONDS=3600 timeout 60 bash reconfigure.sh --manticore enable > failure.log 2>&1 || status=$?
[ "$status" -ne 0 ] || fail 'enable accepted a requested build that failed on a table'
[ "$status" -ne 124 ] || fail 'enable waited for a requested build that had already failed'
grep -Fq 'The requested index rebuild failed on some tables' failure.log ||
    fail "enable did not say why the requested build failed: $(cat failure.log)"
cmp .env expected.env || fail 'a requested build that failed changed saved search settings'
[ ! -e site/admin/data/plugins/external_search/data.dat ] || fail 'a requested build that failed switched the plugin'
# A start that served the kept indexes without the requested build, as an
# image older than the request does, never gets KVS switched to them.
rm -f volume/kvs-rebuild-before-start
if TEST_START_KEEPS_REQUEST=yes TEST_CONTAINER_STATE='0 running' MANTICORE_WAIT_SECONDS=1 \
    bash reconfigure.sh --manticore enable > failure.log 2>&1; then
    fail 'enable accepted indexes served before the requested build'
fi
cmp .env expected.env || fail 'a start without the requested build changed saved search settings'
[ ! -e site/admin/data/plugins/external_search/data.dat ] || fail 'a start without the requested build switched the plugin'
if grep -Fq 'enable again to wait for it' failure.log; then
    fail 'enable said a build goes on although no start builds on the request'
fi
# A start still building every index on an earlier request, one that
# outlasted the wait of an earlier enable for instance, is waited for:
# enable neither asks again nor removes the container, which would start the
# build over, and switches KVS once that build made every table.
rm -f looks
touch volume/kvs-rebuild-before-start
mark=$(wc -l < calls)
TEST_REQUESTED_BUILD=yes TEST_BUILD_ENDS_AFTER=2 TEST_CONTAINER_STATE='0 running' \
    bash reconfigure.sh --manticore enable > waited.log 2>&1 || { cat waited.log; fail 'enable during a requested build'; }
tail -n +"$((mark + 1))" calls > waited.calls
if grep -Eq 'entrypoint touch|rm --stop --force|manticore up ' waited.calls; then
    fail "enable started the requested build in progress over: $(cat waited.calls)"
fi
grep -Fq 'still building every index from the database on an earlier request' waited.log ||
    fail "enable did not say it waits for the build in progress: $(cat waited.log)"
checked=$(awk 'index($0, "compose --profile manticore exec -T manticore sh -c test -e") == 1 { print NR; exit }' waited.calls)
built=$(awk 'index($0, "compose --profile manticore exec -T manticore test ! -e") == 1 { n++; if (n == 2) { print NR; exit } }' waited.calls)
switched=$(awk 'index($0, "compose --profile setup run ") == 1 { print NR; exit }' waited.calls)
[ -n "$checked" ] && [ -n "$built" ] && [ -n "$switched" ] && [ "$checked" -lt "$built" ] && [ "$built" -lt "$switched" ] ||
    fail "enable must see the build in progress, wait until it ends, then switch KVS: $(cat waited.calls)"
grep -Fxq 'ENABLE_MANTICORE=true' .env || fail 'enable after the build in progress was not persisted'
[ -e site/admin/data/plugins/external_search/data.dat ] || fail 'enable after the build in progress did not switch the plugin'
grep -Fq 'Indexes built from the current database' waited.log || fail 'enable after the build in progress did not say where the indexes come from'
# A container Docker restarted, or one whose start does not build on the
# request, gets a new request and a new container, as before.
for state in restarted serving; do
    touch volume/kvs-rebuild-before-start
    mark=$(wc -l < calls)
    case "$state" in
        restarted) TEST_REQUESTED_BUILD=yes TEST_CONTAINER_STATE='1 running' bash reconfigure.sh --manticore enable > again.log 2>&1 ;;
        serving) TEST_CONTAINER_STATE='0 running' bash reconfigure.sh --manticore enable > again.log 2>&1 ;;
    esac || { cat again.log; fail "enable over a $state container"; }
    tail -n +"$((mark + 1))" calls > again.calls
    request=$(awk 'index($0, "compose --profile manticore run --rm --no-deps -T --entrypoint touch ") == 1 { print NR; exit }' again.calls)
    removal=$(awk '$0 == "compose --profile manticore rm --stop --force manticore" { print NR; exit }' again.calls)
    start=$(awk '$0 == "compose --profile manticore up -d --no-deps manticore" { print NR; exit }' again.calls)
    [ -n "$request" ] && [ -n "$removal" ] && [ -n "$start" ] && [ "$request" -lt "$removal" ] && [ "$removal" -lt "$start" ] ||
        fail "enable over a $state container must ask again and start a new one: $(cat again.calls)"
done
# Out of time while that build goes on, enable says it goes on and that
# running it again waits for it, and changes nothing.
touch volume/kvs-rebuild-before-start
cp .env waiting.env
if TEST_REQUESTED_BUILD=yes TEST_CONTAINER_STATE='0 running' MANTICORE_WAIT_SECONDS=1 \
    timeout 60 bash reconfigure.sh --manticore enable > hint.log 2>&1; then
    fail 'enable accepted a build that had not ended'
fi
grep -Fq 'The build of every index from the database goes on: run ./reconfigure.sh --manticore enable again to wait for it.' hint.log ||
    fail "enable did not say the build goes on: $(cat hint.log)"
cmp .env waiting.env || fail 'enable out of time changed saved search settings'
rm -f volume/kvs-rebuild-before-start
if grep -Eq 'compose (down|up)|volume rm|--force-recreate|/init-kvs.sh' calls; then fail 'search operation changed the whole installation'; fi
if grep -E 'compose (--profile [a-z]+ )*rm ' calls | grep -Fvxq 'compose --profile manticore rm --stop --force manticore'; then
    fail 'search operation removed another container than Manticore'
fi
if bash reconfigure.sh --manticore enable --import-status >/dev/null 2>&1; then fail 'mixed actions accepted'; fi
if bash reconfigure.sh --watch >/dev/null 2>&1; then fail 'watch accepted without import-status'; fi
echo 'PASS: Manticore enable/disable/status persistence, idempotence, rebuild before use and failure paths'
