#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/kvs-setup-existing-project.XXXXXX)
PROJECT_NAME="scope-target"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local expected="$2"

    grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_file_not_contains() {
    local file="$1"
    local unexpected="$2"

    if grep -Fq -- "$unexpected" "$file"; then
        fail "$file unexpectedly contains: $unexpected"
    fi
}

make_setup_copy() {
    local destination="$1"
    local log_dir="$2"

    # Keep EUID literal while redirecting setup logs into the disposable fixture.
    # shellcheck disable=SC2016
    sed \
        -e "s|/opt/kvs/logs|${log_dir}|g" \
        -e 's/if \[ "$EUID" -ne 0 \]; then/if false; then/' \
        "$REPO_ROOT/docker/setup.sh" > "$destination"
    chmod +x "$destination"
}

make_mocks() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_CALL_LOG"

if [ "${1:-}" = "--version" ]; then
    echo "Docker version 28.0.0, build test"
    exit 0
fi
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then
    echo "Docker Compose version v2.35.0"
    exit 0
fi

if [ "${1:-}" = "ps" ]; then
    if [[ " $* " == *" --filter label=com.docker.compose.project=${EXPECTED_PROJECT} "* ]]; then
        if [ "${INCLUDE_CURRENT_PROJECT:-false}" = "true" ]; then
            printf '%s\n' current-container-1 current-container-2
        fi
    else
        # A broad name-based query sees unrelated containers that deliberately
        # use the same service suffixes as KVS.
        printf '%s\n' unrelated-php unrelated-nginx unrelated-cron
    fi
    exit 0
fi

if [ "${1:-}" = "volume" ] && [ "${2:-}" = "ls" ]; then
    if [[ " $* " == *" --filter label=com.docker.compose.project=${EXPECTED_PROJECT} "* ]]; then
        if [ "${INCLUDE_CURRENT_PROJECT:-false}" = "true" ]; then
            echo current-volume-1
        fi
    else
        printf '%s\n' unrelated-volume-1 unrelated-volume-2
    fi
    exit 0
fi

exit 0
EOF
    cat > "$bin_dir/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$bin_dir/gum" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$bin_dir/ss" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$bin_dir/docker" "$bin_dir/curl" "$bin_dir/gum" "$bin_dir/ss"
}

run_case() {
    local case_name="$1"
    local include_current="$2"
    local case_dir="$TMP_ROOT/$case_name"
    local work_dir="$case_dir/work"
    local mock_bin="$case_dir/bin"
    local setup_copy="$case_dir/setup.sh"
    local output="$case_dir/output.log"
    local docker_calls="$case_dir/docker-calls.log"
    local status

    mkdir -p "$work_dir" "$case_dir/logs"
    cp "$REPO_ROOT/docker/.env.example" "$work_dir/.env"
    sed -i \
        -e 's/^DOMAIN=.*/DOMAIN=mysite.test/' \
        -e "s/^SITE_PREFIX=.*/SITE_PREFIX=${PROJECT_NAME}/" \
        -e "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=${PROJECT_NAME}/" \
        "$work_dir/.env"
    make_setup_copy "$setup_copy" "$case_dir/logs"
    make_mocks "$mock_bin"

    set +e
    (
        cd "$work_dir"
        env -u COMPOSE_PROJECT_NAME \
            PATH="$mock_bin:/usr/bin:/bin" \
            DOCKER_CALL_LOG="$docker_calls" \
            EXPECTED_PROJECT="$PROJECT_NAME" \
            INCLUDE_CURRENT_PROJECT="$include_current" \
            HEADLESS=y \
            PREFLIGHT_BYPASS=y \
            DOMAIN=mysite.test \
            EMAIL=ops@mysite.test \
            SSL_CHOICE=3 \
            "$setup_copy"
    ) > "$output" 2>&1
    status=$?
    set -e

    [ "$status" -ne 0 ] || fail "setup should stop because the KVS archive fixture is absent"
    assert_file_contains "$output" "No KVS archive found in ./kvs-archive/"
    assert_file_contains "$docker_calls" \
        "ps -aq --filter label=com.docker.compose.project=${PROJECT_NAME}"
    assert_file_contains "$docker_calls" \
        "volume ls -q --filter label=com.docker.compose.project=${PROJECT_NAME}"
    assert_file_not_contains "$docker_calls" "--format {{.Names}}"
    assert_file_not_contains "$docker_calls" "--filter name=docker_"
}

run_fresh_install_case() {
    local case_dir="$TMP_ROOT/fresh-install"
    local work_dir="$case_dir/docker"
    local mock_bin="$case_dir/bin"
    local setup_copy="$case_dir/setup.sh"
    local output="$case_dir/output.log"
    local docker_calls="$case_dir/docker-calls.log"
    local expected_project="kvs-mysite"
    local status

    mkdir -p "$work_dir" "$case_dir/logs"
    cp "$REPO_ROOT/docker/.env.example" "$work_dir/.env.example"
    make_setup_copy "$setup_copy" "$case_dir/logs"
    make_mocks "$mock_bin"

    set +e
    (
        cd "$work_dir"
        env -u COMPOSE_PROJECT_NAME \
            PATH="$mock_bin:/usr/bin:/bin" \
            DOCKER_CALL_LOG="$docker_calls" \
            EXPECTED_PROJECT="$expected_project" \
            INCLUDE_CURRENT_PROJECT=false \
            HEADLESS=y \
            PREFLIGHT_BYPASS=y \
            DOMAIN=mysite.test \
            EMAIL=ops@mysite.test \
            PREFIX_CHOICE=1 \
            SSL_CHOICE=3 \
            "$setup_copy"
    ) > "$output" 2>&1
    status=$?
    set -e

    [ "$status" -ne 0 ] || fail "fresh setup should stop because the KVS archive fixture is absent"
    assert_file_contains "$output" "No KVS archive found in ./kvs-archive/"
    assert_file_contains "$work_dir/.env" "COMPOSE_PROJECT_NAME=$expected_project"
    assert_file_contains "$docker_calls" \
        "ps -aq --filter label=com.docker.compose.project=${expected_project}"
    assert_file_contains "$docker_calls" \
        "volume ls -q --filter label=com.docker.compose.project=${expected_project}"
    assert_file_not_contains "$docker_calls" \
        "label=com.docker.compose.project=docker"
    assert_file_not_contains "$output" \
        "WARNING: Re-running on existing installation"
}

run_case foreign-only false
assert_file_not_contains "$TMP_ROOT/foreign-only/output.log" \
    "WARNING: Re-running on existing installation"

run_case current-project true
assert_file_contains "$TMP_ROOT/current-project/output.log" \
    "WARNING: Re-running on existing installation (2 container(s), 1 volume(s))"

echo "ok 1 - setup scopes existing-resource detection to the Compose project from .env"

run_fresh_install_case
echo "ok 2 - fresh setup detects resources only after deriving the final Compose project"

# A refused preparation keeps the earlier site running. Exercise the actual
# setup entry point through local synthetic import inspection and mode choice,
# then retry with only the rejected input corrected. No dump is loaded and the
# strict engine fixture forwards only Compose config to an unavailable socket.
python3 - "$REPO_ROOT" "$TMP_ROOT/preparation" <<'PY'
#!/usr/bin/env python3
"""Run setup preparation and retry through the actual local import inspection."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys

REPO=Path(sys.argv[1])
BASE=Path(sys.argv[2]);BASE.mkdir()
label='current'
source=(REPO/'docker/setup.sh').read_text()
cases = [
    dict(name='invalid-mode', mode='single', choice='3', retry={'MODE_CHOICE': '1'}),
    dict(name='missing-mode', mode='', choice='', retry={'MODE_CHOICE': '1'}),
    dict(name='ordinary-success', mode='single', choice='1', retry={}),
    dict(name='interrupted-stop', mode='single', choice='1', kill='stop', retry={'KILL_AT':''}),
    dict(name='custom-prefix-partial', mode='single', choice='1', custom=True, retry={'INTERRUPT_PREFIX':''}),
    dict(name='unsupported-zerossl', mode='single', choice='2', ssl='2', retry={'SSL_CHOICE': '3'}),
    dict(name='unsupported-compose', mode='single', choice='2', version='2.20.0', retry={'COMPOSE_VERSION': '2.35.0'}),
]
rows = []
for case in cases:
    root = BASE / ('preparation-' + label) / case['name']
    assert not root.exists(), root
    d = root / 'docker'
    for directory in ['lib', 'bin', 'kvs-archive', 'docker-config', 'multi-site', 'site', 'oldsite/admin/include']:
        (d / directory).mkdir(parents=True, exist_ok=True)
    for name in ['lib/import.sh', 'lib/database.sh', 'lib/native-import.sh', 'bin/resolve-bases.sh', 'images.lock', 'docker-compose.yml', 'docker-compose.multi.yml']:
        shutil.copy2(REPO / 'docker' / name, d / name)
    initial = ('DOMAIN=example.test\nSITE_PREFIX=kvs-saved\nCOMPOSE_PROJECT_NAME=kvs-saved\n'
               'EMAIL=admin@example.test\nSSL_PROVIDER=selfsigned\n'
               'MARIADB_VERSION=12.3\nMARIADB_PASSWORD=fixture\nMARIADB_ROOT_PASSWORD=fixture-root\n'
               'PHP_VERSION=8.1\nCOMPOSE_PROFILES=dragonfly,direct-tls\nIONCUBE=NO\nKEEP=stable\n'
               'MODE=' + case['mode'] + '\n')
    if case['name'] == 'invalid-mode':
        initial += 'KVS_IMPORT_COMPLETED=2026-10-01T10:00:00Z\n'
    (d / '.env').write_text(initial)
    (d / '.env').chmod(0o600)
    (d / 'RELEASE').write_text('synthetic-recovery-audit\n')
    old = d / 'oldsite/admin/include'
    (old / 'setup.php').write_text("<?php\n$config['project_path']='/var/www/old';\n$config['project_url']='https://example.test';\n$config['tables_prefix']='ktvs_';\n")
    (old / 'setup_db.php').write_text('<?php\n')
    (old / 'version.php').write_text("<?php\n$config['project_version']='7.0.2';\n")
    (old / 'functions_base.php').write_text('<?php // synthetic plain PHP\n')
    (d / 'dump.sql').write_text("CREATE TABLE `ktvs_options` (`variable` varchar(100), `value` text);\nINSERT INTO `ktvs_options` VALUES ('INITIAL_VERSION','7.0.2');\n-- Dump completed on 2026-10-26 12:00:00\n")
    engine = {}
    for i, name in enumerate(['kvs-saved', 'kvs-other', 'kvs-custom', 'kvs-foreign']):
        active = name == 'kvs-saved'
        engine[name] = dict(id=hex(i + 10)[2:] * 64, existing=active, running=active,
                            network=active, network_id=str(i + 1) * 64,
                            network_owner=name, volume=active, ports=[80, 443])
    (d / 'engine-state.json').write_text(json.dumps(engine, indent=2) + '\n')
    shutil.copyfile(REPO / 'tests/fixtures/setup-retirement-docker.py', d / 'bin/docker')
    (d / 'bin/docker').chmod(0o755)
    manager = d / 'multi-site/site-manager.sh'
    manager.write_text('#!/bin/bash\n[[ "$#" == 3 && "$1" == primary-remove && "$2" == other.test && ( "$3" == kvs-saved || "$3" == kvs-other ) ]] || exit 97\nprintf \'["site-manager","%s","%s","%s"]\\n\' "$@" >> "$CALLS"\n')
    manager.chmod(0o755)
    (d / 'bin/blocked').write_text('#!/bin/bash\nprintf "FORBIDDEN_COMMAND %s\\n" "$0" >&2\nexit 97\n')
    (d / 'bin/blocked').chmod(0o755)
    for tool in ['curl', 'wget', 'ssh', 'scp', 'rsync', 'sudo', 'apt', 'apt-get', 'pacman', 'paru', 'systemctl', 'git', 'gum', 'openssl']:
        (d / 'bin' / tool).symlink_to('blocked')
    body = source
    for old_text, new_text in [
        ('if [ "$EUID" -ne 0 ]; then', 'if false; then'),
        ('/opt/kvs/logs', str(d / 'logs')),
        ('\ninstall_gum >/dev/null 2>&1 || true\n', '\n: # No host installation.\n'),
        ('\npreflight_checks\n', '\n: # No host preflight.\n'),
    ]:
        assert body.count(old_text) == 1, old_text
        body = body.replace(old_text, new_text)
    body = body.replace('\n: # No host preflight.\n', '''
export DRIVER_PID=$BASHPID
mv() {
    command mv "$@" || return $?
    if [ "${INTERRUPT_PREFIX:-}" = yes ] && [ "${!#}" = .env ] &&
        [ "${key:-}" = SITE_PREFIX ] && [ "${value:-}" = kvs-custom ]; then
        kill -KILL "$DRIVER_PID"
    fi
}
''')
    body = body.replace('/var/www/', str(d / 'site') + '/')
    point = '\nprepare_multi_site_proxy() {\n'
    assert body.count(point) == 1
    body = body.replace(point, '''
/usr/bin/docker compose config --format json > current-model.json
/usr/bin/env -u COMPOSE_FILE -u COMPOSE_PROFILES -u COMPOSE_PROJECT_NAME -u SITE_PREFIX /usr/bin/docker compose config --format json > fresh-model.json
printf '%s' "${KVS_IMPORT_PENDING_RETIREMENT+x}" > pending-memory
/usr/bin/printenv KVS_IMPORT_PENDING_RETIREMENT > pending-child || true
printf 'PREPARATION_FINISHED\\n'
exit 0
''' + point)
    (d / 'setup.sh').write_text(body)
    env = dict(PATH=str(d / 'bin') + ':/usr/bin:/bin', TMPDIR=os.environ.get('TMPDIR',str(BASE)),
               HEADLESS='y', DOMAIN='other.test', SSL_CHOICE=case.get('ssl', '3'),
               MARIADB_VERSION_CONFIRMED='yes', KVS_PHP_VERSION='8.1', CACHE_CHOICE='1',
               PREFIX_CHOICE='3' if case.get('custom') else '1', MODE_CHOICE=case['choice'], IONCUBE_CHOICE='1',
               DOCKER_HOST='unix://' + str(d / 'absent.sock'), DOCKER_CONFIG=str(d / 'docker-config'),
               ENGINE_STATE=str(d / 'engine-state.json'), ENGINE_EVENTS=str(d / 'engine-events.jsonl'),
               CALLS=str(d / 'calls.jsonl'), DOCKER_BIN='/usr/bin/docker',
               KILL_AT=case.get('kill',''), INTERRUPT_PREFIX='yes' if case.get('custom') else '',
               COMPOSE_VERSION=case.get('version', '2.35.0'), ACME_RUNNING='no', CADDY_RUNNING='no',
               IMPORT_SITE_DIR=str(d / 'oldsite'), IMPORT_DB_DUMP=str(d / 'dump.sql'))

    def invoke(phase, selected_env):
        (d / 'calls.jsonl').write_text('')
        process = subprocess.run(['/bin/bash', './setup.sh'], cwd=d, env=selected_env,
                                 capture_output=True, text=True, input='kvs-custom\n' if case.get('custom') else '', timeout=40)
        output = process.stdout + process.stderr
        (d / ('output-' + phase + '.log')).write_text(output)
        calls = [json.loads(line) for line in (d / 'calls.jsonl').read_text().splitlines()]
        assert 'FORBIDDEN_' not in output and not any(c[0].startswith('FORBIDDEN') for c in calls), (case, output, calls)
        saved = subprocess.run(['/bin/bash', '-c', 'source .env; printf "%s\\0%s\\0%s\\0%s\\0%s\\0%s" "$DOMAIN" "$SITE_PREFIX" "$COMPOSE_PROJECT_NAME" "${MODE-}" "${KVS_IMPORT_PENDING_RETIREMENT-}" "$KEEP"'],
                               cwd=d, env={'PATH': '/usr/bin:/bin'}, capture_output=True, text=True, check=True).stdout.split('\0')
        models = {}
        if process.returncode == 0:
            for which in ['current', 'fresh']:
                config = json.loads((d / (which + '-model.json')).read_text())
                models[which] = {'name': config['name'], 'services': sorted(config['services'])}
        return dict(status=process.returncode, output=output, calls=calls, saved=saved,
                    pending_memory=(d / 'pending-memory').read_text() if process.returncode == 0 else None,
                    pending_child=(d / 'pending-child').read_text() if process.returncode == 0 else None,
                    file=(d / '.env').read_text(), models=models,
                    state=json.loads((d / 'engine-state.json').read_text()))

    first = invoke('first', env)
    if case['name']=='invalid-mode' and first['saved'][4]:
        # A saved exported receipt must disappear from both the later process
        # state and a fresh reader once retirement succeeds.
        pending_file=d/'.env'
        pending_text=pending_file.read_text()
        assert pending_text.count('KVS_IMPORT_PENDING_RETIREMENT=')==1
        pending_file.write_text(pending_text.replace('KVS_IMPORT_PENDING_RETIREMENT=', 'export KVS_IMPORT_PENDING_RETIREMENT='))
        foreign_env=dict(env,MODE_CHOICE='1',ENGINE_ID='another-synthetic-engine')
        before_foreign=(d/'.env').read_bytes()
        foreign=invoke('different-engine',foreign_env)
        assert foreign['status']==1 and (d/'.env').read_bytes()==before_foreign
        assert foreign['state']['kvs-saved']['running']
        assert not any(c[:2] in [['docker','stop'],['docker','rm']] or c[:3]==['docker','network','rm'] for c in foreign['calls'])
        assert 'different Docker engine' in foreign['output']
    second_env = dict(env)
    second_env.update(case['retry'])
    second = invoke('second', second_env)
    refused = bool(case['retry'])
    first_ok = first['status'] == (-9 if case.get('kill') or case.get('custom') else 1 if refused else 0)
    if case.get('kill'):
        first_ok = first_ok and first['state']['kvs-saved']['existing'] and not first['state']['kvs-saved']['running']
    elif refused:
        first_ok = first_ok and first['state']['kvs-saved']['running'] and first['state']['kvs-saved']['existing']
    else:
        first_ok = first_ok and not first['state']['kvs-saved']['existing']
    target_prefix='kvs-custom' if case.get('custom') else 'kvs-other'
    second_ok = (second['status'] == 0 and second['saved'][:3] == ['other.test', target_prefix, target_prefix]
                 and not second['saved'][4] and second['saved'][5] == 'stable'
                 and not second['state']['kvs-saved']['existing'] and not second['state']['kvs-saved']['network']
                 and second['state']['kvs-saved']['volume']
                 and second['pending_memory'] == '' and second['pending_child'] == ''
                 and second['models']['current'] == second['models']['fresh'])
    row = dict(case=case, passed=bool(first_ok and second_ok), first_ok=bool(first_ok), second_ok=bool(second_ok),
               first=first, second=second, source_sha256=hashlib.sha256(source.encode()).hexdigest(),
               environment_changes={k: [env.get(k), second_env[k]] for k in second_env if env.get(k) != second_env[k]})
    rows.append(row)
    assert row['passed'], (case, first['output'], second['output'], first['state'], second['state'])
    print(label, case['name'], 'first', first['status'], 'old running', first['state']['kvs-saved']['running'],
          'retry', second['status'], 'saved', second['saved'][:3], 'PASS' if row['passed'] else 'FAIL', flush=True)
(BASE / ('preparation-' + label + '.json')).write_text(json.dumps(rows, indent=2) + '\n')
print(label, sum(row['passed'] for row in rows), '/', len(rows), flush=True)

PY
echo 'ok 3 - invalid import preparation preserves the earlier project and remains recoverable'

# The earlier changed-domain import acts on the saved project before the
# final prefix is chosen. Run its actual loading and decision blocks; the
# executable Docker double also catches calls made through xargs.
awk '
    $0 == "remove_env_value() {" || $0 == "set_env_value() {" ||
        $0 == "validate_site_prefix() {" || $0 == "select_site_prefix() {" ||
        $0 == "compose_files_for() {" || $0 == "require_compose_config() {" ||
        $0 == "validate_domain() {" || /^retirement_[a-z_]+\(\) \{$/ { capture = 1 }
    capture { print }
    capture && /^}$/ { capture = 0 }
' "$REPO_ROOT/docker/setup.sh" > "$TMP_ROOT/project-functions.sh"
awk '
    $0 == "# Load environment" { capture = 1 }
    $0 == "# Domain validation" { capture = 0 }
    capture { print }
' "$REPO_ROOT/docker/setup.sh" > "$TMP_ROOT/project-load.sh"
awk '
    /^# An import under a new domain gets its own stack:/ { capture = 1 }
    /^# Site prefix for container naming / { exit }
    capture { print }
' "$REPO_ROOT/docker/setup.sh" > "$TMP_ROOT/project-retire.sh"
awk '
    $0 == "database_docker_query() {" { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' "$REPO_ROOT/docker/lib/database.sh" > "$TMP_ROOT/database-query.sh"
mkdir -p "$TMP_ROOT/prior-bin"
cp "$REPO_ROOT/tests/fixtures/setup-retirement-docker.py" "$TMP_ROOT/prior-bin/docker"
chmod +x "$TMP_ROOT/prior-bin/docker"
cat > "$TMP_ROOT/project-driver.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$PROJECT_TEST_ROOT/project-functions.sh"
source "$PROJECT_TEST_ROOT/database-query.sh"
COMPOSE_STUB_ONLY=yes
export COMPOSE_STUB_ONLY
MAX_SITE_PREFIX_LENGTH=235
RED='' GREEN='' YELLOW='' NC=''
check_mariadb_stop_grace_period() { :; }
check_cloudflare_configuration() { :; }
source "$PROJECT_TEST_ROOT/project-load.sh"
DOMAIN=$NEXT_DOMAIN
IMPORT_MODE=true
export DOMAIN
retirement_load initial
retirement_mask_completion
source "$PROJECT_TEST_ROOT/project-retire.sh"
retirement_finish
EOF

for project_form in plain quoted exported commented indented duplicate reference real_fake fake_only absent inherited empty legacy; do
    for domain_change in same changed; do
        case_dir="$TMP_ROOT/prior-$project_form-$domain_change"
        mkdir -p "$case_dir"
        printf 'DOMAIN=example.test\nSITE_PREFIX=kvs-saved\nMODE=single\n' > "$case_dir/.env"
        expected_project=kvs-saved
        case "$project_form" in
            plain|real_fake) echo 'COMPOSE_PROJECT_NAME=kvs-saved' >> "$case_dir/.env" ;;
            quoted) echo "COMPOSE_PROJECT_NAME='kvs-saved'" >> "$case_dir/.env" ;;
            exported) echo 'export COMPOSE_PROJECT_NAME=kvs-saved' >> "$case_dir/.env" ;;
            commented) echo 'COMPOSE_PROJECT_NAME=kvs-saved # saved project' >> "$case_dir/.env" ;;
            indented) echo '  COMPOSE_PROJECT_NAME=kvs-saved' >> "$case_dir/.env" ;;
            duplicate) printf 'COMPOSE_PROJECT_NAME=kvs-decoy\nexport COMPOSE_PROJECT_NAME=kvs-saved\n' >> "$case_dir/.env" ;;
            reference)
                # shellcheck disable=SC2016  # Expanded only when setup loads the fixture.
                printf 'PROJECT_SEED=kvs-saved\nCOMPOSE_PROJECT_NAME="${PROJECT_SEED}"\n' >> "$case_dir/.env" ;;
            fake_only|absent|inherited) expected_project='' ;;
            empty) echo "COMPOSE_PROJECT_NAME=''" >> "$case_dir/.env"; expected_project='' ;;
            legacy) echo 'COMPOSE_PROJECT_NAME=kvs' >> "$case_dir/.env"; expected_project='' ;;
        esac
        case "$project_form" in
            real_fake|fake_only) printf '%s\n' 'KEEP="first' 'COMPOSE_PROJECT_NAME=kvs-decoy' 'last"' >> "$case_dir/.env" ;;
        esac
        chmod 600 "$case_dir/.env"
        next_domain=example.test
        [ "$domain_change" = same ] || next_domain=other.test
        (
            cd "$case_dir"
            unset COMPOSE_PROJECT_NAME
            [ "$project_form" != inherited ] || export COMPOSE_PROJECT_NAME=kvs-inherited
            PATH="$TMP_ROOT/prior-bin:$PATH" DOCKER_CALL_LOG="$case_dir/calls" PROJECT_TEST_ROOT="$TMP_ROOT" NEXT_DOMAIN="$next_domain" \
                bash "$TMP_ROOT/project-driver.sh"
        ) > "$case_dir/output" 2>&1 || fail "$project_form/$domain_change failed: $(cat "$case_dir/output")"
        [ -f "$case_dir/calls" ] || : > "$case_dir/calls"
        python3 - "$case_dir/calls" "$expected_project" "$domain_change" <<'PY'
import json,sys
calls=[json.loads(line) for line in open(sys.argv[1])]
expected=[]
if sys.argv[2] and sys.argv[3]=='changed':
    expected=[['docker','stop','a'*64],['docker','rm','a'*64],['docker','network','rm','1'*64]]
mutations=[c for c in calls if c[:2] in [['docker','stop'],['docker','rm']] or c[:3]==['docker','network','rm']]
assert mutations==expected,(mutations,expected)
assert all(not c[0].startswith('FORBIDDEN') for c in calls)
for call in calls:
    for arg in call:
        if arg.startswith('label=com.docker.compose.project='):
            assert arg=='label=com.docker.compose.project=kvs-saved',call
if not expected:assert calls==[],calls
PY
        [ "$(stat -c %a "$case_dir/.env")" = 600 ] || fail 'the saved file mode changed'
    done
done
echo 'ok 4 - changed-domain imports select the parsed saved project and exclude inherited-only or multiline lookalikes'

# A setup run exports the selected project before it inspects resources.
# Read the saved settings in a fresh process too: that export must not hide
# an older duplicate, a missing assignment, or damage to another value.
for prefix_path in choose normalize; do
    for project_form in plain quoted exported indented commented duplicate reference real_fake export_fake fake_only absent inherited shared_export; do
        case_dir="$TMP_ROOT/persist-$prefix_path-$project_form"
        work_dir="$case_dir/docker"
        mock_bin="$case_dir/bin"
        mkdir -p "$work_dir" "$case_dir/logs"
        saved_prefix=scope-target
        expected_project=scope-target
        if [ "$prefix_path" = choose ]; then saved_prefix=kvs; expected_project=kvs-mysite; fi
        sed -e 's/^DOMAIN=.*/DOMAIN=mysite.test/' -e "s/^SITE_PREFIX=.*/SITE_PREFIX=$saved_prefix/" \
            -e '/^COMPOSE_PROJECT_NAME=/d' "$REPO_ROOT/docker/.env.example" > "$work_dir/.env"
        printf '\nEXTRA=preserved\n' >> "$work_dir/.env"
        case "$project_form" in
            plain|real_fake) echo 'COMPOSE_PROJECT_NAME=kvs-old' >> "$work_dir/.env" ;;
            quoted) echo "COMPOSE_PROJECT_NAME='kvs-old'" >> "$work_dir/.env" ;;
            exported|export_fake) echo 'export COMPOSE_PROJECT_NAME=kvs-old' >> "$work_dir/.env" ;;
            indented) echo '  COMPOSE_PROJECT_NAME=kvs-old' >> "$work_dir/.env" ;;
            commented) echo 'COMPOSE_PROJECT_NAME=kvs-old # saved project' >> "$work_dir/.env" ;;
            duplicate) printf 'COMPOSE_PROJECT_NAME=kvs-decoy\nexport COMPOSE_PROJECT_NAME=kvs-old\n' >> "$work_dir/.env" ;;
            reference)
                # shellcheck disable=SC2016  # Expanded by the real setup loader.
                printf 'PROJECT_SEED=kvs-old\nCOMPOSE_PROJECT_NAME="${PROJECT_SEED}"\n' >> "$work_dir/.env" ;;
            shared_export) echo 'export COMPOSE_PROJECT_NAME="kvs-old" RELATED="preserved"' >> "$work_dir/.env" ;;
        esac
        case "$project_form" in
            real_fake|export_fake|fake_only) printf '%s\n' 'KEEP="first' 'COMPOSE_PROJECT_NAME=kvs-decoy' 'last"' >> "$work_dir/.env" ;;
        esac
        make_setup_copy "$case_dir/setup.sh" "$case_dir/logs"
        make_mocks "$mock_bin"
        status=0
        project_environment=()
        [ "$project_form" != inherited ] || project_environment=(COMPOSE_PROJECT_NAME=kvs-inherited)
        (
            cd "$work_dir"
            env -u COMPOSE_PROJECT_NAME "${project_environment[@]}" \
                PATH="$mock_bin:/usr/bin:/bin" DOCKER_CALL_LOG="$case_dir/docker-calls" \
                EXPECTED_PROJECT="$expected_project" INCLUDE_CURRENT_PROJECT=false \
                HEADLESS=y PREFLIGHT_BYPASS=y PREFIX_CHOICE=1 SSL_CHOICE=3 \
                "$case_dir/setup.sh"
        ) > "$case_dir/output" 2>&1 || status=$?
        [ "$status" -ne 0 ] || fail 'the fixture must stop before building, with no KVS archive'
        assert_file_contains "$case_dir/output" 'No KVS archive found in ./kvs-archive/'
        assert_file_contains "$case_dir/docker-calls" "ps -aq --filter label=com.docker.compose.project=$expected_project"
        assert_file_contains "$case_dir/docker-calls" "volume ls -q --filter label=com.docker.compose.project=$expected_project"
        (
            cd "$work_dir"
            # shellcheck disable=SC2016  # Read saved values in the fresh child shell.
            env -u COMPOSE_PROJECT_NAME -u KEEP -u RELATED \
                EXPECTED_PROJECT="$expected_project" PROJECT_FORM="$project_form" bash -c '
                set -eu
                source .env
                [ "${COMPOSE_PROJECT_NAME-}" = "$EXPECTED_PROJECT" ]
                [ "$SITE_PREFIX" = "$EXPECTED_PROJECT" ]
                [ "$EXTRA" = preserved ]
                case "$PROJECT_FORM" in
                    real_fake|export_fake|fake_only)
                        expected_keep=$(printf "%s\n" first COMPOSE_PROJECT_NAME=kvs-decoy last)
                        [ "$KEEP" = "$expected_keep" ] ;;
                    shared_export) [ "$RELATED" = preserved ] ;;
                esac
            '
        ) || fail "$prefix_path/$project_form did not preserve the saved project and unrelated values"
        [ "$(stat -c %a "$work_dir/.env")" = 600 ] || fail 'project persistence changed file permissions'
    done
done
echo 'ok 5 - selected and normalized projects survive a fresh load without changing unrelated values'

# The selected prefix itself must survive the reload that follows a
# changed-domain reset and the later reloads before the images are built.
awk '
    $0 == "# Only ask about prefix if using default" { capture = 1 }
    $0 == "warn_if_existing_project_resources \"$COMPOSE_PROJECT_NAME\"" { exit }
    capture { print }
' "$REPO_ROOT/docker/setup.sh" > "$TMP_ROOT/prefix-flow.sh"
cat > "$TMP_ROOT/prefix-driver.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$PROJECT_TEST_ROOT/project-functions.sh"
source "$PROJECT_TEST_ROOT/database-query.sh"
COMPOSE_STUB_ONLY=yes
export COMPOSE_STUB_ONLY
MAX_SITE_PREFIX_LENGTH=235
RED='' GREEN='' YELLOW='' CYAN='' NC=''
HEADLESS=y PREFIX_CHOICE=1 MAX_SITE_PREFIX_LENGTH=235
KVS_EMAIL_OVERRIDE_SET=false KVS_EMAIL_OVERRIDE=''
check_mariadb_stop_grace_period() { :; }
check_cloudflare_configuration() { :; }
source "$PROJECT_TEST_ROOT/project-load.sh"
DOMAIN=$NEXT_DOMAIN
IMPORT_MODE=true
export DOMAIN
retirement_load initial
retirement_mask_completion
source "$PROJECT_TEST_ROOT/project-retire.sh"
source "$PROJECT_TEST_ROOT/prefix-flow.sh"
EOF
for prefix_path in choose reset; do
    for prefix_form in plain quoted exported indented commented duplicate reference real_fake export_fake shared_export; do
        case_dir="$TMP_ROOT/prefix-$prefix_path-$prefix_form"
        mkdir -p "$case_dir"
        saved_prefix=kvs expected_prefix=kvs-example next_domain=example.test
        if [ "$prefix_path" = reset ]; then saved_prefix=kvs-saved; expected_prefix=kvs-other; next_domain=other.test; fi
        printf 'DOMAIN=example.test\nMODE=single\nCOMPOSE_PROJECT_NAME=kvs-saved\nEXTRA=preserved\n' > "$case_dir/.env"
        case "$prefix_form" in
            plain|real_fake) printf 'SITE_PREFIX=%s\n' "$saved_prefix" >> "$case_dir/.env" ;;
            quoted) printf "SITE_PREFIX='%s'\n" "$saved_prefix" >> "$case_dir/.env" ;;
            exported|export_fake) printf 'export SITE_PREFIX=%s\n' "$saved_prefix" >> "$case_dir/.env" ;;
            indented) printf '  SITE_PREFIX=%s\n' "$saved_prefix" >> "$case_dir/.env" ;;
            commented) printf 'SITE_PREFIX=%s # saved prefix\n' "$saved_prefix" >> "$case_dir/.env" ;;
            duplicate) printf 'SITE_PREFIX=kvs-decoy\nexport SITE_PREFIX=%s\n' "$saved_prefix" >> "$case_dir/.env" ;;
            reference)
                printf 'PREFIX_SEED=%s\n' "$saved_prefix" >> "$case_dir/.env"
                # shellcheck disable=SC2016  # Expanded by the actual loader.
                echo 'SITE_PREFIX="${PREFIX_SEED}"' >> "$case_dir/.env" ;;
            shared_export) printf 'export SITE_PREFIX="%s" RELATED="preserved"\n' "$saved_prefix" >> "$case_dir/.env" ;;
        esac
        case "$prefix_form" in
            real_fake|export_fake) printf '%s\n' 'KEEP="first' 'SITE_PREFIX=kvs-decoy' 'last"' >> "$case_dir/.env" ;;
        esac
        chmod 600 "$case_dir/.env"
        (
            cd "$case_dir"
            env -u SITE_PREFIX -u COMPOSE_PROJECT_NAME PATH="$TMP_ROOT/prior-bin:$PATH" \
                DOCKER_CALL_LOG="$case_dir/calls" PROJECT_TEST_ROOT="$TMP_ROOT" NEXT_DOMAIN="$next_domain" \
                bash "$TMP_ROOT/prefix-driver.sh"
        ) > "$case_dir/output" 2>&1 || fail "$prefix_path/$prefix_form setup failed: $(cat "$case_dir/output")"
        (
            cd "$case_dir"
            # shellcheck disable=SC2016  # Neither exported parent value may hide a stale saved prefix.
            env -u SITE_PREFIX -u COMPOSE_PROJECT_NAME -u KEEP -u RELATED \
                EXPECTED_PREFIX="$expected_prefix" PREFIX_FORM="$prefix_form" bash -c '
                set -eu
                source .env
                [ "$SITE_PREFIX" = "$EXPECTED_PREFIX" ]
                [ "$COMPOSE_PROJECT_NAME" = "$EXPECTED_PREFIX" ]
                [ "$EXTRA" = preserved ]
                case "$PREFIX_FORM" in
                    real_fake|export_fake)
                        expected_keep=$(printf "%s\n" first SITE_PREFIX=kvs-decoy last)
                        [ "$KEEP" = "$expected_keep" ] ;;
                    shared_export) [ "$RELATED" = preserved ] ;;
                esac
            '
        ) || fail "$prefix_path/$prefix_form saved an inconsistent prefix or changed another value"
        [ "$(stat -c %a "$case_dir/.env")" = 600 ] || fail 'prefix persistence changed saved file permissions'
    done
done
echo 'ok 6 - selected and reset prefixes preserve exported, interpolated and multiline settings'

# Retirement uses the prior installation's parsed mode. The newly accepted
# mode may differ; it must not turn a multi-site installation into an old
# single-site project or treat text inside another value as a mode setting.
# shellcheck disable=SC2016  # Expanded by the isolated driver after preparation.
sed 's/^retirement_finish$/MODE=$ACCEPTED_MODE\nretirement_finish/' \
    "$TMP_ROOT/project-driver.sh" > "$TMP_ROOT/mode-driver.sh"
for mode_form in single multi quoted_single single_quoted_multi double_quoted_multi commented_multi exported_multi indented_multi \
    duplicate_multi reference_multi real_and_multiline multiline_only inherited_multi inherited_single absent empty; do
    for accepted_mode in single multi; do
        case_dir="$TMP_ROOT/mode-$mode_form-$accepted_mode"
        mkdir -p "$case_dir"
        printf 'DOMAIN=example.test\nSITE_PREFIX=kvs-saved\nCOMPOSE_PROJECT_NAME=kvs-saved\nEXTRA=preserved\n' > "$case_dir/.env"
        previous_mode=single
        mode_environment=()
        case "$mode_form" in
            single|real_and_multiline) echo 'MODE=single' >> "$case_dir/.env" ;;
            multi) echo 'MODE=multi' >> "$case_dir/.env"; previous_mode=multi ;;
            quoted_single) echo "MODE='single'" >> "$case_dir/.env" ;;
            single_quoted_multi) echo "MODE='multi'" >> "$case_dir/.env"; previous_mode=multi ;;
            double_quoted_multi) echo 'MODE="multi"' >> "$case_dir/.env"; previous_mode=multi ;;
            commented_multi) echo 'MODE=multi # existing installation' >> "$case_dir/.env"; previous_mode=multi ;;
            exported_multi) echo 'export MODE=multi' >> "$case_dir/.env"; previous_mode=multi ;;
            indented_multi) echo '  MODE=multi' >> "$case_dir/.env"; previous_mode=multi ;;
            duplicate_multi) printf 'MODE=single\nexport MODE=multi\n' >> "$case_dir/.env"; previous_mode=multi ;;
            reference_multi)
                # shellcheck disable=SC2016  # Expanded only by the actual setup load.
                printf 'MODE_SEED=multi\nMODE="${MODE_SEED}"\n' >> "$case_dir/.env"
                previous_mode=multi ;;
            inherited_multi) mode_environment=(MODE=multi); previous_mode=multi ;;
            inherited_single) mode_environment=(MODE=single) ;;
            empty) echo "MODE=''" >> "$case_dir/.env" ;;
        esac
        case "$mode_form" in
            real_and_multiline|multiline_only) printf 'KEEP="first\nMODE=multi\nlast"\n' >> "$case_dir/.env" ;;
        esac
        chmod 600 "$case_dir/.env"
        (
            cd "$case_dir"
            env -u MODE "${mode_environment[@]}" PATH="$TMP_ROOT/prior-bin:$PATH" \
                DOCKER_CALL_LOG="$case_dir/calls" PROJECT_TEST_ROOT="$TMP_ROOT" NEXT_DOMAIN=other.test \
                ACCEPTED_MODE="$accepted_mode" bash "$TMP_ROOT/mode-driver.sh"
        ) > "$case_dir/output" 2>&1 || fail "$mode_form/$accepted_mode failed: $(cat "$case_dir/output")"
        [ -f "$case_dir/calls" ] || : > "$case_dir/calls"
        python3 - "$case_dir/calls" "$previous_mode" <<'PY'
import json,sys
calls=[json.loads(line) for line in open(sys.argv[1])]
mutations=[c for c in calls if c[:2] in [['docker','stop'],['docker','rm']] or c[:3]==['docker','network','rm']]
expected=[] if sys.argv[2]=='multi' else [['docker','stop','a'*64],['docker','rm','a'*64],['docker','network','rm','1'*64]]
assert mutations==expected,(mutations,expected)
assert all(not c[0].startswith('FORBIDDEN') for c in calls)
PY
        # shellcheck disable=SC2016  # A separate reader checks the persisted neighbor.
        saved_extra=$(env -u MODE -u EXTRA bash -c 'source "$1/.env"; printf "%s" "$EXTRA"' bash "$case_dir")
        [ "$saved_extra" = preserved ] || fail 'prior-mode handling changed an unrelated value'
    done
done
echo 'ok 7 - retirement follows the parsed prior mode, independently of the next mode'
