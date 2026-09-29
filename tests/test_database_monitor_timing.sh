#!/bin/bash
# Measure output as it is emitted, including slow probes and an already-ready DB.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root" <<'PY'
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='kvs-monitor-timing.') as directory:
    fixture = Path(directory)
    docker = fixture / 'docker'
    docker.write_text('''#!/bin/bash
case "$*" in
    'compose ps -a -q mariadb')
        if [ "$MONITOR_CASE" = docker-hung ]; then sleep 30; fi
        echo fixture-container ;;
    'inspect --format '*)
        if [ "$MONITOR_CASE" = logs-hung ]; then echo '1 running'; else echo '0 running'; fi ;;
    'compose logs --no-color --tail 500 mariadb')
        if [ "$MONITOR_CASE" = logs-hung ]; then sleep 30; fi ;;
    *) echo "Unexpected Docker call: $*" >&2; exit 97 ;;
esac
''')
    docker.chmod(0o755)
    script = '''
set -eu
source "$MONITOR_LIBRARY"
database_root_query() {
    if [ "$MONITOR_CASE" = ready ]; then return 0; fi
    sleep 4
    return 1
}
database_import_snapshot() {
    if [ "$MONITOR_CASE" = ready ]; then echo forbidden-snapshot >&2; return 97; fi
    sleep 4
    printf 'tables\\t3\\nactive\\t1\\noperation\\tUpdate\\t0\\tktvs_videos\\t0.0\\n'
}
database_dump_position() {
    if [ "$MONITOR_CASE" = ready ]; then echo forbidden-reader >&2; return 97; fi
    sleep 4
    printf '1048576\\t2097152\\n'
}
database_wait_ready 0 yes
'''

    def run(case):
        # The hung cases stop at the Docker query limit, set short here.
        env = dict(os.environ, MONITOR_CASE=case, DOCKER_QUERY_TIMEOUT_SECONDS='3',
                   MONITOR_LIBRARY=str(root / 'docker/lib/database.sh'),
                   PATH=str(fixture) + ':' + os.environ['PATH'])
        start = time.monotonic()
        process = subprocess.Popen(['bash', '-c', script], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        events = []
        pending = b''
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            try:
                while selector.get_map():
                    if time.monotonic() - start > 20:
                        raise AssertionError(f'{case}: monitor or child process hung')
                    for key, _ in selector.select(timeout=0.2):
                        data = os.read(key.fileobj.fileno(), 65536)
                        if not data:
                            if pending:
                                events.append((time.monotonic() - start, pending.decode()))
                            selector.unregister(key.fileobj)
                            continue
                        pending += data
                        while b'\n' in pending:
                            line, pending = pending.split(b'\n', 1)
                            events.append((time.monotonic() - start, line.decode().rstrip()))
                status = process.wait(timeout=2)
            finally:
                # Only this test's isolated process group is eligible for cleanup.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        elapsed = time.monotonic() - start
        assert events and events[0][0] < 2, (case, 'no immediate status', events)
        if case == 'slow':
            assert status == 0, (case, status, events)
            assert any('dump read' in line and '50%' in line for _, line in events), events
            times = [0] + [stamp for stamp, _ in events] + [elapsed]
            gap = max(b - a for a, b in zip(times, times[1:]))
            assert gap < 7, (case, f'{gap:.2f}s without output', events)
            print(f'PASS: slow probes remain visible (longest silence {gap:.2f}s).')
        elif case == 'ready':
            assert status == 0 and elapsed < 2, (case, status, elapsed, events)
            assert any('accepts TCP connections' in line for _, line in events), events
            assert not any('waiting' in line.lower() or 'forbidden-' in line for _, line in events), events
            print(f'PASS: already-ready MariaDB returns immediately ({elapsed:.2f}s), without import polling.')
        else:
            assert status != 0 and elapsed < 7, (case, status, elapsed, events)
            assert any('ERROR:' in line for _, line in events), events
            if case == 'logs-hung':
                assert any('stopped or restarted during initialization' in line for _, line in events), events
                assert any('last 500 lines' in line for _, line in events), events
                print(f'PASS: hung failure logs stay bounded ({elapsed:.2f}s) and preserve the failure status.')
            else:
                print(f'PASS: a hung Docker probe is bounded ({elapsed:.2f}s) and reported.')

    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(run, ['slow', 'ready', 'docker-hung', 'logs-hung']))
PY
