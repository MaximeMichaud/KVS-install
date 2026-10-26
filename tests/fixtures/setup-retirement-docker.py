#!/usr/bin/python3
"""Strict synthetic engine; never forwards a mutating Docker command."""
from pathlib import Path
import json, os, signal, subprocess, sys
args = sys.argv[1:]
state_path = Path(os.environ.get('ENGINE_STATE', 'engine-state.json'))
log = Path(os.environ.get('CALLS', os.environ.get('DOCKER_CALL_LOG', 'calls.jsonl')))
with log.open('a') as f:
    f.write(json.dumps(['docker'] + args) + '\n')
if not state_path.exists():
    initial = {}
    for i, (name, digit) in enumerate([('kvs-saved', 'a'), ('kvs-other', 'b'), ('kvs-custom', 'c'), ('kvs-foreign', 'd'), ('kvs-decoy', 'e'), ('kvs-inherited', 'f'), ('kvs', '0')]):
        initial[name] = dict(id=digit * 64, existing=True, running=True, network=True, network_id=str(i + 1) * 64, network_owner=name, volume=True, ports=[80, 443])
    state_path.write_text(json.dumps(initial) + '\n')
state = json.loads(state_path.read_text())
if args == ['info', '--format', '{{.ID}}']:
    print(os.environ.get('ENGINE_ID', 'synthetic-engine-A'))
    sys.exit(0)

def reject():
    with log.open('a') as f:
        f.write(json.dumps(['FORBIDDEN_DOCKER'] + args) + '\n')
    sys.exit(99)

def fault(stage):
    if os.environ.get('API_FAIL') == stage:
        sys.exit(75)

def save(action, project):
    state_path.write_text(json.dumps(state, indent=2) + '\n')
    with Path(os.environ.get('ENGINE_EVENTS', 'engine-events.jsonl')).open('a') as f:
        f.write(json.dumps({'action': action, 'project': project, 'state': state}) + '\n')
    if os.environ.get('KILL_AT') == action:
        os.kill(int(os.environ['DRIVER_PID']), signal.SIGKILL)
    if os.environ.get('RETURN_ERROR_AFTER') == action:
        sys.exit(75)
if args[:2] == ['compose', 'config'] and args[2:] in [['--quiet'], ['--format', 'json']]:
    if os.environ.get('COMPOSE_STUB_ONLY') == 'yes':
        sys.exit(0)
    sys.exit(subprocess.run([os.environ['DOCKER_BIN']] + args, timeout=20).returncode)
if args == ['compose', 'version']:
    print('Docker Compose version v' + os.environ.get('COMPOSE_VERSION', '2.35.0'))
    sys.exit(0)
if args == ['compose', 'down']:
    project = os.environ.get('COMPOSE_PROJECT_NAME', '')
    if project not in state:
        reject()
    state[project].update(existing=False, running=False, network=False)
    save('compose-down', project)
    sys.exit(0)
if args == ['ps', '-a', '--format', '{{.Names}}']:
    if os.environ.get('ACME_RUNNING') == 'yes' and (not Path(os.environ['ACME_REMOVED']).exists()):
        print(os.environ['ACME_PREFIX'] + '-acme')
    sys.exit(0)
if args == ['ps', '--filter', 'name=^/kvs-caddy$', '--format', '{{.Names}}']:
    if os.environ.get('CADDY_RUNNING') == 'yes':
        print('kvs-caddy')
    sys.exit(0)
if args[:1] == ['ps']:
    fault('query')
    clean = [a for a in args if a != '--no-trunc']
    if len(clean) == 4 and clean[:3] == ['ps', '-aq', '--filter'] and clean[3].startswith('id='):
        for item in state.values():
            if item['existing'] and item['id'] == clean[3][3:]:
                print(item['id'])
        sys.exit(0)
    if len(clean) == 4 and clean[1] in ['-q', '-aq'] and (clean[2] == '--filter') and clean[3].startswith('label=com.docker.compose.project='):
        project = clean[3].split('=', 2)[-1]
        if project not in state:
            reject()
        item = state[project]
        if item['existing'] and (clean[1] == '-aq' or item['running']):
            print(item['id'])
        sys.exit(0)
    if len(args) == 5 and args[1] == '--filter' and args[2].startswith('label=com.docker.compose.project=') and (args[3] == '--format') and (args[4] in ['{{.Names}}', 'table {{.Names}}' + chr(92) + 't{{.Status}}', 'table {{.Names}}' + chr(92) * 2 + 't{{.Status}}']):
        project = args[2].split('=', 2)[-1]
        if project not in state:
            reject()
        if state[project]['existing'] and state[project]['running']:
            print(project + '-nginx')
        sys.exit(0)
if len(args) == 4 and args[:3] == ['inspect', '--format', '{{index .Config.Labels "com.docker.compose.project"}}']:
    fault('inspect')
    for name, item in state.items():
        if item['existing'] and item['id'] == args[3]:
            print(item.get('owner', name))
            sys.exit(0)
    sys.exit(1)
if len(args) == 7 and args[:4] == ['network', 'ls', '--no-trunc', '--filter'] and args[4].startswith('id=') and (args[5:] == ['--format', '{{.ID}}']):
    fault('network-query')
    for item in state.values():
        if item['network'] and item['network_id'] == args[4][3:]:
            print(item['network_id'])
    sys.exit(0)
if len(args) == 5 and args[:4] == ['network', 'inspect', '--format', '{{index .Labels "com.docker.compose.project"}}']:
    fault('network-inspect')
    for name, item in state.items():
        if item['network'] and item['network_id'] == args[4]:
            print(item['network_owner'])
            sys.exit(0)
    sys.exit(1)
if len(args) == 7 and args[:3] == ['network', 'ls', '--no-trunc'] and (args[3] == '--filter') and args[4].startswith('label=com.docker.compose.project=') and (args[5:] == ['--format', '{{.ID}}|{{.Name}}']):
    fault('network-query')
    project = args[4].split('=', 2)[-1]
    if project not in state:
        reject()
    for name, item in state.items():
        if item['network'] and item['network_owner'] == project:
            print(item['network_id'] + '|' + name + '_kvs-network')
    sys.exit(0)
if len(args) == 5 and args[:3] == ['volume', 'ls', '-q'] and (args[3] == '--filter') and args[4].startswith('label=com.docker.compose.project='):
    project = args[4].split('=', 2)[-1]
    if project not in state:
        reject()
    if state[project]['volume']:
        print(project + '-volume')
    sys.exit(0)
if len(args) == 2 and args[0] in ['stop', 'rm']:
    fault(args[0])
    for project, item in state.items():
        if args[1] == item['id']:
            if not item['existing']:
                sys.exit(1)
            if args[0] == 'stop':
                item['running'] = False
            elif item['running']:
                sys.exit(1)
            else:
                item['existing'] = False
            save(args[0], project)
            sys.exit(0)
    if args[1] in [p + '-' + service for p in state for service in ['memcached', 'dragonfly', 'acme']]:
        if args[1] == os.environ.get('ACME_PREFIX', '') + '-acme' and os.environ.get('ACME_RUNNING') == 'yes' and (not Path(os.environ['ACME_REMOVED']).exists()):
            if args[0] == 'rm':
                Path(os.environ['ACME_REMOVED']).write_text('removed\n')
            sys.exit(0)
        sys.exit(1)
if len(args) == 3 and args[:2] == ['network', 'rm']:
    fault('network-rm')
    for project, item in state.items():
        if args[2] in [item['network_id'], project + '_kvs-network']:
            if not item['network']:
                sys.exit(1)
            if item.get('network_busy'):
                sys.exit(75)
            item['network'] = False
            save('network-rm', project)
            sys.exit(0)
reject()
