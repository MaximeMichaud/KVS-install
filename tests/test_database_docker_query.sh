#!/bin/bash
# Docker metadata queries have a time limit, for a daemon that no longer
# answers. A host busy with the import answers some of them late: one
# answer after more than three seconds stopped the setup during the
# replay, or a recovery after the KVS initialization with cron never
# started. A late answer is waited for; a missing one still stops.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/kvs-docker-query.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$fixture/docker" <<'SH'
#!/bin/bash
sleep "$DOCKER_DELAY"
echo 0123456789abcdef
SH
chmod +x "$fixture/docker"
export PATH="$fixture:$PATH"
# shellcheck source=/dev/null
source "$root/docker/lib/database.sh"

answer=$(DOCKER_DELAY=4 database_docker_query compose ps -a -q mariadb) ||
    fail "a Docker query that answered after four seconds was cut off"
[ "$answer" = 0123456789abcdef ] || fail "unexpected answer: $answer"
answer=$(DOCKER_DELAY=4 DOCKER_QUERY_TIMEOUT_SECONDS=soon database_docker_query compose ps -a -q mariadb) ||
    fail "an unusable DOCKER_QUERY_TIMEOUT_SECONDS did not fall back to the default limit"
echo 'PASS: a Docker query that answers late is waited for.'

start=$SECONDS
if DOCKER_DELAY=30 DOCKER_QUERY_TIMEOUT_SECONDS=1 database_docker_query compose ps -a -q mariadb > /dev/null; then
    fail 'a Docker query that never answered succeeded'
fi
[ "$((SECONDS - start))" -le 4 ] || fail "the limit was not applied ($((SECONDS - start)) s)"
echo 'PASS: a Docker query that never answers stops at its limit.'
