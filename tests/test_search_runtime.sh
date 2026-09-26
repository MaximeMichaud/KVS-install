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
cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/calls"
case "$*" in
    'compose exec -T mariadb sh -c '*) exit 0 ;;
    'compose --profile manticore up '*) exit "${TEST_UP_FAILURE:-0}" ;;
    'compose --profile manticore exec -T manticore mysql '*)
        [ "${TEST_INDEX_FAILURE:-no}" != yes ] || exit 1
        printf 'example_com_videos\tplain\nexample_com_albums\tplain\nexample_com_searches\tplain\n' ;;
    'compose --profile manticore ps -a -q manticore') echo fixture ;;
    inspect*) echo '0 exited' ;;
    'compose --profile manticore ps -a manticore'|'compose --profile manticore stop manticore') exit 0 ;;
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
export TEST_ROOT="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH"
cd "$TEST_DIR"
# A fresh process reloads .env and reads the serialized plugin configuration.
bash reconfigure.sh --manticore enable > enabled.log 2>&1 || { cat enabled.log; fail enable; }
grep -Fxq 'ENABLE_MANTICORE=true' .env || fail 'enable was not persisted'
grep -Fxq 'COMPOSE_PROFILES=redis,direct-tls,manticore' .env || fail 'enable lost other profiles'
bash reconfigure.sh --manticore status > status.log 2>&1 || { cat status.log; fail 'enabled status'; }
bash reconfigure.sh --manticore enable > repeated.log 2>&1 || fail 'repeated enable'
[ "$(grep -c '^COMPOSE_PROFILES=' .env)" = 1 ] || fail 'duplicate profiles setting'
bash reconfigure.sh --manticore disable > disabled.log 2>&1 || { cat disabled.log; fail disable; }
grep -Fxq 'ENABLE_MANTICORE=false' .env || fail 'disable was not persisted'
grep -Fxq 'COMPOSE_PROFILES=redis,direct-tls' .env || fail 'disable lost other profiles'
bash reconfigure.sh --manticore status > status.log 2>&1 || fail 'disabled status'
[ ! -e site/admin/data/plugins/external_search/data.dat ] || fail 'plugin still enabled'
cp .env expected.env
for mode in UP INDEX INIT; do
    if env "TEST_${mode}_FAILURE=$([ "$mode" = UP ] && echo 1 || echo yes)" bash reconfigure.sh --manticore enable > failure.log 2>&1; then
        fail "$mode failure accepted"
    fi
    cmp .env expected.env || fail "$mode failure changed saved search settings"
    [ ! -e site/admin/data/plugins/external_search/data.dat ] || fail "$mode failure switched the plugin"
done
if grep -Eq 'compose (down|up)|volume rm|--force-recreate|/init-kvs.sh' calls; then fail 'search operation changed the whole installation'; fi
if bash reconfigure.sh --manticore enable --import-status >/dev/null 2>&1; then fail 'mixed actions accepted'; fi
if bash reconfigure.sh --watch >/dev/null 2>&1; then fail 'watch accepted without import-status'; fi
echo 'PASS: Manticore enable/disable/status persistence, idempotence and failure paths'
