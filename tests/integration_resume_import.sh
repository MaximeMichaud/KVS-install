#!/bin/bash
# Optional local MariaDB proof that a timed-out wait can resume the same import.
# shellcheck disable=SC2034  # Monitoring and recovery helpers read these globals.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export DATABASE_TEST_IMAGE=${DATABASE_TEST_IMAGE:-mariadb:12.3.3}
if [ -n "${DOCKER_CONTEXT:-}" ]; then
    endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
else
    endpoint=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}
fi
case "$endpoint" in
    unix://*) ;;
    *) echo 'ERROR: this integration test requires a local Docker socket' >&2; exit 1 ;;
esac
docker image inspect "$DATABASE_TEST_IMAGE" >/dev/null
test_dir=$(mktemp -d /tmp/kvs-resume-integration.XXXXXX)
export COMPOSE_PROJECT_NAME="kvs-resume-test-$RANDOM-$$"
export COMPOSE_FILE="$test_dir/compose.yml"
export DATABASE_TEST_ROOT_PASSWORD
DATABASE_TEST_ROOT_PASSWORD=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')

cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        docker compose logs --tail 35 mariadb >&2 2>/dev/null || true
        [ ! -f "$test_dir/first-wait.log" ] || tail -n 15 "$test_dir/first-wait.log" >&2
    fi
    docker compose down -v >/dev/null 2>&1 || true
    rm -rf "$test_dir"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Timestamp each line when it arrives, rather than after a buffered command.
cat > "$test_dir/time-monitor.py" <<'PY'
import json
import subprocess
import sys
import time

library, database, prefix, budget, report = sys.argv[1:]
command = ['bash', '-c', '''
set -euo pipefail
source "$1"
DOMAIN=$2
TABLES_PREFIX=$3
IMPORT_DUMP_TABLES=2
database_wait_ready "$4"
''', 'monitor', library, database, prefix, budget]
started = time.monotonic()
lines = []
with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                      text=True, bufsize=1) as process:
    for line in process.stdout:
        lines.append([time.monotonic() - started, line.rstrip('\n')])
        print(line, end='', flush=True)
    status = process.wait()
with open(report, 'w') as output:
    json.dump({'lines': lines, 'duration': time.monotonic() - started,
               'status': status}, output)
sys.exit(status)
PY
timed_monitor() {
    local budget=$1 report=$2
    timeout --kill-after=2 80 python3 "$test_dir/time-monitor.py" "$root/docker/lib/database.sh" \
        "$DOMAIN" "$TABLES_PREFIX" "$budget" "$report"
}

mkdir "$test_dir/init"
cat > "$COMPOSE_FILE" <<'YAML'
services:
  mariadb:
    image: ${DATABASE_TEST_IMAGE}
    network_mode: none
    mem_limit: 512m
    cpus: 1
    command: ["--innodb-buffer-pool-size=128M"]
    environment:
      MARIADB_ROOT_PASSWORD: ${DATABASE_TEST_ROOT_PASSWORD}
      MARIADB_DATABASE: resume_fixture
    volumes:
      - ./init:/docker-entrypoint-initdb.d:ro
      - data:/var/lib/mysql
volumes:
  data:
YAML
cat > "$test_dir/source.sql" <<'SQL'
CREATE TABLE ktvs_options (variable VARCHAR(255) PRIMARY KEY, value TEXT NOT NULL) ENGINE=InnoDB;
CREATE TABLE ktvs_resume_audit (id INT PRIMARY KEY, value VARCHAR(100)) ENGINE=InnoDB;
INSERT INTO ktvs_resume_audit VALUES (1,'executed once');
SELECT SLEEP(18);
INSERT INTO ktvs_resume_audit VALUES (2,'finished after timeout');
SQL
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
# shellcheck source=/dev/null
source "$root/docker/lib/database.sh"
DOMAIN=resume_fixture
TABLES_PREFIX=ktvs_
IMPORT_DUMP_TABLES=2
token=20260926T230000Z-a1b2c3d4
import_prepare_dump "$test_dir/source.sql" ktvs_ 7.0.2 /var/www/kvs /var/www/kvs \
    "$test_dir/init/10-kvs-import.sql" "$token" >/dev/null
gzip "$test_dir/init/10-kvs-import.sql"
docker compose up -d --pull never >/dev/null
container=$(docker compose ps -a -q mariadb)
seen=no
for ((attempt = 0; attempt < 60; attempt++)); do
    rows=$(database_root_query --batch --skip-column-names --database="$DOMAIN" \
        -e 'SELECT COUNT(*) FROM ktvs_resume_audit;' 2>/dev/null) || rows=''
    if [ "$rows" = 1 ]; then seen=yes; break; fi
    sleep 1
done
[ "$seen" = yes ] || fail 'the fixture did not enter its paused SQL replay'
identity_before=$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' "$container")
if timed_monitor 1 "$test_dir/first-wait.json" > "$test_dir/first-wait.log" 2>&1; then
    fail 'the initial wait unexpectedly completed before SQL replay finished'
fi
grep -q 'left running' "$test_dir/first-wait.log" || fail 'the initial failure was not a timeout preserving MariaDB'
[ "$(docker inspect --format '{{.State.Status}}' "$container")" = running ] || fail 'the timeout stopped MariaDB'
[ "$(database_root_query --batch --skip-column-names --database="$DOMAIN" \
    -e "SELECT COUNT(*) FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';")" = 0 ] || fail 'the completion marker appeared before replay finished'
echo 'PASS: the readiness timeout leaves the original container and SQL replay running.'

# The recovery-helper checks below use the same staged artifact as old installs.
# shellcheck source=/dev/null
source "$root/docker/lib/import-resume.sh"
import_resume_discover "$test_dir/init" "$DOMAIN" "$TABLES_PREFIX"
[ "$IMPORT_STAGED_DUMP" = "$test_dir/init/10-kvs-import.sql.gz" ] || fail 'resume did not select the existing staged SQL artifact'
timed_monitor 60 "$test_dir/active-monitor.json"
recovered_token=$(import_resume_token "$IMPORT_STAGED_DUMP")
[ "$recovered_token" = "$token" ] || fail 'resume recovered a different completion token'
import_resume_verify "$DOMAIN" "$TABLES_PREFIX" "$recovered_token"
identity_after=$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' "$container")
[ "$identity_after" = "$identity_before" ] || fail 'resume restarted or replaced the database container'
[ "$(docker compose ps -a -q mariadb)" = "$container" ] || fail 'resume changed the Compose database container'
readback=$(database_root_query --batch --skip-column-names --database="$DOMAIN" \
    -e 'SELECT id,value FROM ktvs_resume_audit ORDER BY id;')
[ "$readback" = $'1\texecuted once\n2\tfinished after timeout' ] || fail 'resume lost or replayed import data'
version=$(database_root_query --batch --skip-column-names -e 'SELECT VERSION();')
echo "PASS: MariaDB $version resumes the existing SQL load and verifies its final marker without container restart, replacement or SQL replay."

# Recovery can be invoked after the SQL load has already completed. That path
# must confirm readiness directly, preserve its marker and avoid a fake wait.
timed_monitor 10 "$test_dir/ready-monitor.json"
import_resume_verify "$DOMAIN" "$TABLES_PREFIX" "$recovered_token"
[ "$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' "$container")" = "$identity_before" ] || fail 'monitoring an already-ready database changed its container'
python3 - "$test_dir/first-wait.json" "$test_dir/active-monitor.json" "$test_dir/ready-monitor.json" <<'PY'
import json
import sys

initial, active, ready = [json.load(open(path)) for path in sys.argv[1:]]
for label, result in [('initial', initial), ('active', active), ('ready', ready)]:
    messages = [(stamp, line) for stamp, line in result['lines'] if line.strip()]
    assert messages and 'MariaDB' in messages[0][1], (label, 'no database status output', result)
    assert messages[0][0] < 2, (label, 'initial status was delayed', result)
assert active['status'] == ready['status'] == 0
progress = [(stamp, line) for stamp, line in active['lines'] if 'MariaDB:' in line]
assert len(progress) >= 2, ('active import did not report periodic progress', active)
assert any('User sleep' in line for _, line in active['lines']), active
timestamps = [0] + [stamp for stamp, line in active['lines'] if line.strip()] + [active['duration']]
longest_silence = max(end - start for start, end in zip(timestamps, timestamps[1:]))
assert longest_silence < 7, ('active import monitoring fell silent', longest_silence, active)
assert ready['duration'] < 5, ('already-ready detection was delayed', ready)
assert not any('waiting' in line.lower() for _, line in ready['lines']), ready
print('PASS: active and ready checks report immediately '
      f"({active['lines'][0][0]:.3f}s/{ready['lines'][0][0]:.3f}s); "
      f'longest active silence {longest_silence:.3f}s; '
      f"already-ready check {ready['duration']:.3f}s without a false waiting phase.")
PY

# A controlling terminal exposes Compose's default interactive stdin even
# with -T. timeout creates another process group; unattended argument queries
# must not read that terminal, while the snapshot's SQL heredoc must still work.
python3 - "$root" "$DOMAIN" "$TABLES_PREFIX" "$recovered_token" <<'PY'
import errno
import os
import pty
import select
import signal
import subprocess
import sys
import time

script = '''
set -euo pipefail
[ -t 0 ]
source "$1/docker/lib/database.sh"
source "$1/docker/lib/import-resume.sh"
DOMAIN=$2
TABLES_PREFIX=$3
IMPORT_DUMP_TABLES=2
database_wait_ready 10
marker=$(import_resume_marker "$DOMAIN" "$TABLES_PREFIX")
[ "$marker" = "$4" ]
import_resume_verify "$DOMAIN" "$TABLES_PREFIX" "$4"
rows=$(database_root_query --batch --skip-column-names --database="$DOMAIN" \
    -e 'SELECT COUNT(*) FROM ktvs_resume_audit;' 2>/dev/null)
[ "$rows" = 2 ]
snapshot=$(database_import_snapshot)
[[ "$snapshot" == *$'tables\\t2'* ]]
echo PTY_RESUME_OK
'''
started = time.monotonic()
child, terminal = pty.fork()
if child == 0:
    os.execv('/bin/bash', ['bash', '--noprofile', '--norc', '-c', script, 'resume-pty'] + sys.argv[1:])
output = bytearray()
status = None
try:
    while time.monotonic() - started < 25:
        if select.select([terminal], [], [], .1)[0]:
            try:
                chunk = os.read(terminal, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
    else:
        raise AssertionError('PTY readiness check did not finish: ' + output.decode(errors='replace'))
    _, status = os.waitpid(child, 0)
    elapsed = time.monotonic() - started
    text = output.decode(errors='replace')
    assert os.waitstatus_to_exitcode(status) == 0, text
    assert 'PTY_RESUME_OK' in text and 'waiting' not in text.lower(), text
    assert elapsed < 5, (elapsed, text)
    print(f'PASS: real controlling-terminal readiness, marker queries and SQL heredoc complete in {elapsed:.3f}s without SIGTTIN or false waiting.')
finally:
    if status is None:
        # timeout descendants have separate process groups but share this
        # private PTY session. Never signal another session's processes.
        processes = subprocess.run(['ps', '-e', '-o', 'pid=,sid='],
                                   check=True, text=True, capture_output=True).stdout
        for line in processes.splitlines():
            process, session = map(int, line.split())
            if session == child:
                try:
                    os.kill(process, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        os.waitpid(child, 0)
    os.close(terminal)
PY
import_resume_verify "$DOMAIN" "$TABLES_PREFIX" "$recovered_token"
[ "$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' "$container")" = "$identity_before" ] || fail 'PTY recovery changed the database container'

if import_resume_verify "$DOMAIN" "$TABLES_PREFIX" 20260926T230000Z-ffffffff > "$test_dir/wrong-marker.log" 2>&1; then
    fail 'resume accepted a different import completion token'
fi
database_root_query --database="$DOMAIN" -e "DELETE FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';"
if import_resume_verify "$DOMAIN" "$TABLES_PREFIX" "$recovered_token" > "$test_dir/missing-marker.log" 2>&1; then
    fail 'resume accepted a ready database without its completion marker'
fi
[ "$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' "$container")" = "$identity_before" ] || fail 'a refused resume changed the database container'
[ "$(database_root_query --batch --skip-column-names --database="$DOMAIN" -e 'SELECT COUNT(*) FROM ktvs_resume_audit;')" = 2 ] || fail 'a refused resume changed imported rows'
echo 'PASS: wrong and missing completion markers refuse recovery without changing the database container or imported rows.'
