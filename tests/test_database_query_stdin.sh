#!/bin/bash
# Exercise the real query helpers with a terminal and piped SQL, without Docker.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/kvs-query-stdin.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
python3 - "$root" "$fixture" <<'PY'
import os
from pathlib import Path
import pty
import re
import select
import shlex
import signal
import subprocess
import sys
import time

root, fixture = map(Path, sys.argv[1:])
source = (root / 'docker/setup.sh').read_text()
match = re.search(r'^run_root_mariadb\(\) \{\n.*?^\}\n', source, re.M | re.S)
assert match, 'Missing setup SQL helper'
helpers = fixture / 'helpers.sh'
helpers.write_text('source ' + shlex.quote(str(root / 'docker/lib/database.sh')) + '\n' + match.group())
binary = fixture / 'docker'
binary.write_text('''#!/usr/bin/python3
import os
from pathlib import Path
import sys
Path(os.environ['DOCKER_PROCESS']).write_text(f'{os.getpid()} {os.getpgrp()}')
Path(os.environ['STDIN_CAPTURE']).write_bytes(sys.stdin.buffer.read())
print('query-completed')
''')
binary.chmod(0o755)
env = dict(os.environ, PATH=str(fixture) + os.pathsep + os.environ['PATH'],
           DOCKER_PROCESS=str(fixture / 'docker-process'), STDIN_CAPTURE=str(fixture / 'stdin'))


def command(helper, args):
    return ['bash', '--noprofile', '--norc', '-c', 'source "$1"; "$2" "${@:3}"',
            'query-test', str(helpers), helper, *args]


def terminal_query(helper, args):
    process_file = Path(env['DOCKER_PROCESS'])
    process_file.unlink(missing_ok=True)
    pid, master = pty.fork()
    if pid == 0:
        os.execvpe('bash', command(helper, args), env)
    output = bytearray()
    status = None
    started = time.monotonic()
    try:
        while time.monotonic() - started < 3:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
        else:
            raise AssertionError(f'{helper} read from the terminal for {args[0]}')
        _, status = os.waitpid(pid, 0)
        assert os.waitstatus_to_exitcode(status) == 0, output.decode()
        assert b'query-completed' in output, output.decode()
        assert Path(env['STDIN_CAPTURE']).read_bytes() == b'', 'Argument SQL inherited stdin'
    finally:
        # GNU timeout may create a separate process group for the Docker CLI.
        # Clean up both groups if a regression leaves the reader stopped.
        if status is None:
            groups = {pid}
            if process_file.exists():
                groups.add(int(process_file.read_text().split()[1]))
            for group in groups:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            os.waitpid(pid, 0)
        os.close(master)


for helper in ('database_root_query', 'run_root_mariadb'):
    for args in (['-e', 'SELECT 1'], ['-eSELECT 1'],
                 ['--execute', 'SELECT 1'], ['--execute=SELECT 1']):
        terminal_query(helper, args)
    sql = b'SELECT 1;\nSELECT 2;\n'
    result = subprocess.run(command(helper, ['--batch']), env=env, input=sql,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3, check=True)
    assert result.stdout == b'query-completed\n', result.stderr.decode()
    assert Path(env['STDIN_CAPTURE']).read_bytes() == sql, f'{helper} discarded piped SQL'
    print(f'PASS: {helper} detaches terminal stdin for execute options and preserves piped SQL.')
PY
