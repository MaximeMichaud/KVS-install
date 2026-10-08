#!/bin/bash
# shellcheck disable=SC2016,SC2034,SC2329  # Literal code of setup.sh; the variables and stubs are used by the extracted functions.
# kvsctl manages an installation from the moment it adopts it: kvsctl adopt
# writes kvsctl/state.json beside the docker directory, and the first
# release kvsctl installs adds docker-compose.release.yml, which pins the
# images. setup.sh then keeps the MariaDB series (kvsctl upgrade
# --mariadb-series changes it, with a backup) and records in MARIADB_VERSION
# the series of the MariaDB image kvsctl runs, and keeps the PHP series
# (kvsctl upgrade installs the images of a new one). Only the release
# override needs the Docker Compose that reads it. Any other installation
# behaves as before kvsctl: the MariaDB question, the PHP series it picks,
# no word about kvsctl. Every installation needs Compose 2.10.0: this
# script starts the services with "up --pull missing" (2.8.0 and newer) and
# passes values through the environment, which 2.8.0 and 2.9.0 let .env
# override.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-setup-kvsctl.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

awk '
    $0 == "kvsctl_manages_stack() {" || $0 == "preflight_checks() {" ||
        $0 == "kvsctl_keep_mariadb_series() {" || $0 == "choose_mariadb_version() {" ||
        $0 == "kvsctl_note_php_change() {" || $0 == "preflight_kernel_writeback_status() {" ||
        $0 == "set_env_value() {" { capture = 1 }
    capture { print }
    capture && /^}$/ { capture = 0 }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/functions.sh"
declare -F kvsctl_manages_stack preflight_checks kvsctl_keep_mariadb_series choose_mariadb_version \
    kvsctl_note_php_change > /dev/null ||
    fail 'setup.sh must define kvsctl_manages_stack, preflight_checks, kvsctl_keep_mariadb_series, choose_mariadb_version and kvsctl_note_php_change'

CYAN='' GREEN='' RED='' YELLOW='' NC=''
DOCKER_DIR="$TEST_DIR/root/docker"

# workdir <kind>: the docker directory setup.sh runs from, in an
# installation root. "adopted" holds the record kvsctl adopt writes and no
# release override yet, "release" both, "override" the release override
# alone, "plain" neither, and "stray" a kvsctl directory without a record.
workdir() {
    rm -rf "$TEST_DIR/root"
    mkdir -p "$DOCKER_DIR"
    case "$1" in
        adopted|release|stray) mkdir -p "$TEST_DIR/root/kvsctl" ;;
    esac
    case "$1" in
        adopted|release) printf '{}\n' > "$TEST_DIR/root/kvsctl/state.json" ;;
    esac
    case "$1" in
        release|override) printf 'services: {}\n' > "$DOCKER_DIR/docker-compose.release.yml" ;;
    esac
    cd "$DOCKER_DIR"
}

# One definition of "managed": the record of kvsctl adopt, or the release
# override.
for kind in adopted release override; do
    workdir "$kind"
    kvsctl_manages_stack || fail "an installation with the $kind files of kvsctl must count as managed"
done
for kind in plain stray; do
    workdir "$kind"
    if kvsctl_manages_stack; then fail "a $kind installation must not count as managed"; fi
done
echo 'PASS: an installation is managed from kvsctl adopt on'

# The preflight on a host whose Compose plugin is the given version.
preflight() (
    COMPOSE=$1
    DEV_MODE='' PREFLIGHT_BYPASS='' IMPORT_MODE=false
    docker() {
        case "$1" in
            --version) echo 'Docker version 29.0.0, build test' ;;
            compose) echo "Docker Compose version v${COMPOSE}" ;;
        esac
    }
    preflight_free_disk_gb() { echo '40 /'; }
    free() {
        echo '               total        used        free      shared  buff/cache   available'
        echo 'Mem:            8000        1000        5000           0        2000        7000'
    }
    check_internet() { return 0; }
    uname() { echo 7.2.9; }
    curl() { :; }
    unzip() { :; }
    ss() { :; }
    preflight_checks < /dev/null
)

# accepts <kind> <compose version>
accepts() {
    workdir "$1"
    preflight "$2" > "$TEST_DIR/out" 2>&1 ||
        fail "a $1 installation must accept Docker Compose $2: $(cat "$TEST_DIR/out")"
    grep -Fxq "✓ Docker Compose installed: $2" "$TEST_DIR/out" || fail "the Compose line is missing: $(cat "$TEST_DIR/out")"
}

# refuses <kind> <compose version> <reason>
refuses() {
    workdir "$1"
    if preflight "$2" > "$TEST_DIR/out" 2>&1; then
        fail "a $1 installation must refuse Docker Compose $2: $(cat "$TEST_DIR/out")"
    fi
    grep -Fxq "✗ Docker Compose $2 is too old" "$TEST_DIR/out" || fail "the old Compose must be named: $(cat "$TEST_DIR/out")"
    grep -Fq "$3" "$TEST_DIR/out" || fail "the refusal must say why: $(cat "$TEST_DIR/out")"
}

setup_reason='this script starts the services with docker compose up --pull missing (Docker Compose 2.8.0 and newer) and passes values to Compose through the environment, which 2.8.0 and 2.9.0 let .env override'
override_reason='kvsctl manages this installation, and its release override needs Docker Compose 2.19.0 or newer'
for old in 2.7.0 2.8.0 2.9.0; do
    refuses plain "$old" "$setup_reason"
done
accepts plain 2.10.0
accepts plain 2.20.2
# An adopted installation still builds its images from the compose file:
# no release override to read yet.
refuses adopted 2.9.0 "$setup_reason"
accepts adopted 2.10.0
# 2.18 reads "build: !reset null" as a build from a directory named null;
# 2.19.0 is the first that clears the build section.
refuses release 2.18.1 "$override_reason"
accepts release 2.19.0
refuses override 2.18.1 "$override_reason"
echo 'PASS: Docker Compose 2.10.0 for every installation, 2.19.0 once a release override is there'

# choose <kind> <MARIADB_VERSION> [KEEP_VERSION] [KVS_MARIADB_IMAGE]: the
# MariaDB selection on a .env with those values, with select_mariadb_version
# recording that it ran. The .env it started from is kept in env.before.
choose() (
    workdir "$1"
    printf 'MARIADB_VERSION=%s\n' "$2" > .env
    if [ -n "${4:-}" ]; then
        printf 'KVS_MARIADB_IMAGE=%s\n' "$4" >> .env
    fi
    cp .env "$TEST_DIR/env.before"
    MARIADB_VERSION=$2 KEEP_VERSION=${3:-} KVS_MARIADB_IMAGE=${4:-}
    MARIADB_VERSION_CONFIRMED='' MARIADB_DEFAULT_VERSION=12.3
    select_mariadb_version() { echo 'select_mariadb_version ran'; }
    choose_mariadb_version < /dev/null
)
env_unchanged() { cmp -s "$TEST_DIR/env.before" "$DOCKER_DIR/.env"; }
digest="sha256:$(printf '%064d' 0 | tr 0 a)"

for kind in adopted release; do
    choose "$kind" 11.8 n > "$TEST_DIR/out" 2>&1 || fail "the selection failed: $(cat "$TEST_DIR/out")"
    if grep -Fq 'select_mariadb_version ran' "$TEST_DIR/out"; then
        fail "the MariaDB series was offered for change on a $kind installation"
    fi
    grep -Fq 'kvsctl manages this installation, so MariaDB stays on 11.8.' "$TEST_DIR/out" ||
        fail "the series kept must be named: $(cat "$TEST_DIR/out")"
    grep -Fq 'kvsctl upgrade --mariadb-series <series> changes the series' "$TEST_DIR/out" ||
        fail "the way to change the series must be named: $(cat "$TEST_DIR/out")"
    grep -Fq 'that backup is the way back to 11.8.' "$TEST_DIR/out" ||
        fail "the way back must be named: $(cat "$TEST_DIR/out")"
    env_unchanged || fail "MARIADB_VERSION must stay when kvsctl names no MariaDB image: $(cat "$DOCKER_DIR/.env")"
    choose "$kind" 12.3 > "$TEST_DIR/out" 2>&1 || fail "the selection failed: $(cat "$TEST_DIR/out")"
    if grep -Fq 'select_mariadb_version ran' "$TEST_DIR/out"; then
        fail "the default series was offered for change on a $kind installation"
    fi
done

# kvsctl moved the series to 12.3 with KVS_MARIADB_IMAGE: MARIADB_VERSION
# names the series that runs, or the check of the data volume would take
# the 12.3 volume for a downgrade from 11.8.
choose release 11.8 '' "mariadb:12.3.3@${digest}" > "$TEST_DIR/out" 2>&1 ||
    fail "the selection failed: $(cat "$TEST_DIR/out")"
if grep -Fq 'select_mariadb_version ran' "$TEST_DIR/out"; then
    fail "the MariaDB series was offered for change on an installation kvsctl manages"
fi
grep -Fq 'MARIADB_VERSION read 11.8; it now reads 12.3, the series of the image' "$TEST_DIR/out" ||
    fail "the new MARIADB_VERSION must be reported: $(cat "$TEST_DIR/out")"
grep -Fq 'MariaDB stays on 12.3.' "$TEST_DIR/out" || fail "the series that runs must be named: $(cat "$TEST_DIR/out")"
if ! { [ "$(grep -c '^MARIADB_VERSION=' "$DOCKER_DIR/.env")" -eq 1 ] &&
    grep -Fxq 'MARIADB_VERSION=12.3' "$DOCKER_DIR/.env" &&
    grep -Fxq "KVS_MARIADB_IMAGE=mariadb:12.3.3@${digest}" "$DOCKER_DIR/.env"; }; then
    fail "MARIADB_VERSION must name the series of KVS_MARIADB_IMAGE: $(cat "$DOCKER_DIR/.env")"
fi
choose release 11.8 '' "mariadb:11.8.9@${digest}" > "$TEST_DIR/out" 2>&1 ||
    fail "the selection failed: $(cat "$TEST_DIR/out")"
env_unchanged || fail "a MARIADB_VERSION that names the series that runs must stay: $(cat "$DOCKER_DIR/.env")"
if grep -Fq 'now reads' "$TEST_DIR/out"; then fail "nothing changed, nothing must be reported: $(cat "$TEST_DIR/out")"; fi

# Without kvsctl, the questions stay what they were.
choose plain 12.3 > "$TEST_DIR/out" 2>&1 || fail "the selection failed: $(cat "$TEST_DIR/out")"
grep -Fq 'select_mariadb_version ran' "$TEST_DIR/out" || fail "the default series must still offer the list"
choose plain 11.8 n > "$TEST_DIR/out" 2>&1 || fail "the selection failed: $(cat "$TEST_DIR/out")"
grep -Fq 'select_mariadb_version ran' "$TEST_DIR/out" || fail "declining to keep 11.8 must still offer the list"
choose plain 11.8 Y "mariadb:12.3.3@${digest}" > "$TEST_DIR/out" 2>&1 ||
    fail "the selection failed: $(cat "$TEST_DIR/out")"
grep -Fxq 'Keeping MariaDB 11.8' "$TEST_DIR/out" || fail "keeping 11.8 must still be said: $(cat "$TEST_DIR/out")"
if grep -Fq 'kvsctl' "$TEST_DIR/out"; then fail "an installation kvsctl does not manage must not hear of it"; fi
env_unchanged || fail "without kvsctl, .env must stay as the operator left it: $(cat "$DOCKER_DIR/.env")"
echo 'PASS: setup.sh keeps the MariaDB series kvsctl runs, records it in MARIADB_VERSION, and asks as before otherwise'

# php_version_in_env: the one PHP_VERSION line of .env, or a failure.
php_version_in_env() {
    [ "$(grep -c '^PHP_VERSION=' "$DOCKER_DIR/.env")" -eq 1 ] || return 1
    sed -n 's/^PHP_VERSION=//p' "$DOCKER_DIR/.env"
}

# note <kind> <PHP_VERSION before> <PHP_VERSION after>
note() (
    workdir "$1"
    printf 'IONCUBE=YES\nPHP_VERSION=%s\n' "$3" > .env
    KVSCTL_PHP_CHANGE=''
    kvsctl_note_php_change "$2"
    printf 'repeated at the end: %s\n' "$KVSCTL_PHP_CHANGE"
)

kept_message="kvsctl manages this installation, so PHP stays on 8.1 instead of the 8.3 selected above. To move the site to PHP 8.3, set PHP_VERSION=8.3 in .env and run 'kvsctl upgrade', which installs the images of that series."
for kind in adopted release; do
    note "$kind" 8.1 8.3 > "$TEST_DIR/out" 2>&1 || fail "the note failed: $(cat "$TEST_DIR/out")"
    [ "$(php_version_in_env)" = 8.1 ] ||
        fail "a $kind installation must keep its PHP series: $(cat "$DOCKER_DIR/.env")"
    grep -Fxq 'IONCUBE=YES' "$DOCKER_DIR/.env" || fail "the rest of .env must stay: $(cat "$DOCKER_DIR/.env")"
    grep -Fxq "$kept_message" "$TEST_DIR/out" || fail "the series kept and the way to change it must be said: $(cat "$TEST_DIR/out")"
    grep -Fxq "repeated at the end: $kept_message" "$TEST_DIR/out" ||
        fail "the note must be kept for the end of the setup: $(cat "$TEST_DIR/out")"
done
note release 8.1 8.1 > "$TEST_DIR/out" 2>&1 || fail "the note failed: $(cat "$TEST_DIR/out")"
[ "$(cat "$TEST_DIR/out")" = 'repeated at the end: ' ] || fail "an unchanged PHP_VERSION needs no note: $(cat "$TEST_DIR/out")"
[ "$(php_version_in_env)" = 8.1 ] || fail "an unchanged PHP_VERSION must stay: $(cat "$DOCKER_DIR/.env")"
note release '' 8.3 > "$TEST_DIR/out" 2>&1 || fail "the note failed: $(cat "$TEST_DIR/out")"
[ "$(cat "$TEST_DIR/out")" = 'repeated at the end: ' ] || fail "a .env without a PHP series keeps the one picked: $(cat "$TEST_DIR/out")"
[ "$(php_version_in_env)" = 8.3 ] || fail "a .env without a PHP series keeps the one picked: $(cat "$DOCKER_DIR/.env")"
note plain 8.1 8.3 > "$TEST_DIR/out" 2>&1 || fail "the note failed: $(cat "$TEST_DIR/out")"
[ "$(cat "$TEST_DIR/out")" = 'repeated at the end: ' ] ||
    fail "setup.sh builds the new series itself without kvsctl: $(cat "$TEST_DIR/out")"
[ "$(php_version_in_env)" = 8.3 ] || fail "without kvsctl the series picked must stay: $(cat "$DOCKER_DIR/.env")"
grep -Fq 'if [ -n "${KVSCTL_PHP_CHANGE:-}" ]; then' "$ROOT_DIR/docker/setup.sh" ||
    fail "the end of the setup must repeat the PHP note"
echo 'PASS: an installation kvsctl manages keeps its PHP series and is pointed at kvsctl upgrade'

# The PHP selection of the setup flow itself, from the PHP_VERSION it
# starts with to the bases it pins: the note runs after the selection and
# before the bases are written, so a managed installation keeps its series
# and its bases, and any other gets the series picked.
awk '
    /^PHP_VERSION_BEFORE_SETUP=/ { capture = 1 }
    capture { print }
    capture && $0 == "set_php_bases" { exit }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/php-flow.sh"
grep -Fxq 'set_php_bases' "$TEST_DIR/php-flow.sh" ||
    fail "setup.sh must capture PHP_VERSION_BEFORE_SETUP and then pin the bases: $(cat "$TEST_DIR/php-flow.sh")"

# php_flow <kind>: that part of setup.sh on a .env holding PHP 8.1, with a
# selection that picks 8.3 and bases that record the series they are for.
php_flow() (
    workdir "$1"
    printf 'PHP_VERSION=8.1\n' > .env
    KVSCTL_PHP_CHANGE=''
    select_php_version() { set_env_value PHP_VERSION 8.3; }
    set_php_bases() { printf 'bases pinned for %s\n' "$(sed -n 's/^PHP_VERSION=//p' .env)"; }
    # shellcheck source=/dev/null
    source "$TEST_DIR/php-flow.sh"
)

php_flow release > "$TEST_DIR/out" 2>&1 || fail "the PHP selection failed: $(cat "$TEST_DIR/out")"
grep -Fq "PHP stays on 8.1 instead of the 8.3 selected above" "$TEST_DIR/out" ||
    fail "the setup flow must tell a managed installation that its PHP series stays: $(cat "$TEST_DIR/out")"
grep -Fxq 'bases pinned for 8.1' "$TEST_DIR/out" ||
    fail "a managed installation must get the bases of the series it keeps: $(cat "$TEST_DIR/out")"
[ "$(php_version_in_env)" = 8.1 ] || fail "the setup flow must keep the PHP series of a managed installation: $(cat "$DOCKER_DIR/.env")"
php_flow adopted > "$TEST_DIR/out" 2>&1 || fail "the PHP selection failed: $(cat "$TEST_DIR/out")"
grep -Fxq 'bases pinned for 8.1' "$TEST_DIR/out" ||
    fail "an adopted installation must keep its PHP series: $(cat "$TEST_DIR/out")"
php_flow plain > "$TEST_DIR/out" 2>&1 || fail "the PHP selection failed: $(cat "$TEST_DIR/out")"
grep -Fxq 'bases pinned for 8.3' "$TEST_DIR/out" ||
    fail "an installation kvsctl does not manage must get the series picked: $(cat "$TEST_DIR/out")"
if grep -Fq 'kvsctl' "$TEST_DIR/out"; then fail "an installation kvsctl does not manage must not hear of it: $(cat "$TEST_DIR/out")"; fi
echo 'PASS: the setup flow notes a PHP change after the selection and before the bases'

# kvsctl backup and kvsctl restore run on any installation, adopted or not,
# and every kvsctl run that changes one holds kvsctl/lock; one that did not
# finish leaves kvsctl/journal.json, from which kvsctl recover finishes or
# undoes it. setup.sh must not start containers beside it: it stops right
# after its root check, before its logs and anything else, and names the
# reason, and for the journal the way out when recover leaves the run to be
# finished by hand. A run that holds the lock while its journal is there is
# running, not interrupted. A check that cannot take the lock (flock fails)
# cannot tell, and stops too. A lock no run holds, one held shared as
# kvsctl status holds it while it reads, or no kvsctl at all stops nothing.
# The copy here passes the root check (the suite runs as a user) and keeps
# its logs in the case; docker, curl, gum and ss are stand-ins that log
# their calls, and a Docker without Compose ends a run that got past the
# check in the preflight.
mkdir -p "$TEST_DIR/stub"
for tool in docker curl gum ss; do
    cat > "$TEST_DIR/stub/$tool" <<'EOF'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >> "$SETUP_CALLS"
case "${0##*/} $*" in
    'docker --version') echo 'Docker version 29.0.0, build test' ;;
    'docker compose '*) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/stub/$tool"
done
# A flock that fails other than on a held lock: it cannot open the file.
mkdir -p "$TEST_DIR/flock-fails"
printf '#!/bin/bash\necho "flock: cannot open lock file" >&2\nexit 66\n' > "$TEST_DIR/flock-fails/flock"
chmod +x "$TEST_DIR/flock-fails/flock"

# setup_run <case> <kvsctl files: none, idle, watched, running,
# interrupted, both or unknown> [arguments of setup.sh]
setup_run() {
    local case_root="$TEST_DIR/kvsctl-run/$1" files="$2" path="$TEST_DIR/stub:/usr/bin:/bin"
    shift 2
    rm -rf "$case_root"
    mkdir -p "$case_root/docker"
    # shellcheck disable=SC2016  # The EUID test is matched literally.
    sed -e "s|/opt/kvs/logs|${case_root}/logs|g" -e 's/if \[ "$EUID" -ne 0 \]; then/if false; then/' \
        "$ROOT_DIR/docker/setup.sh" > "$case_root/docker/setup.sh"
    case "$files" in
        idle | watched | running | interrupted | both | unknown)
            mkdir -p "$case_root/kvsctl"
            : > "$case_root/kvsctl/lock"
            ;;
    esac
    [ "$files" != unknown ] || path="$TEST_DIR/flock-fails:$path"
    case "$files" in
        interrupted | both) printf '{"action":"upgrade"}\n' > "$case_root/kvsctl/journal.json" ;;
    esac
    : > "$TEST_DIR/calls"
    (
        case "$files" in
            # Held as kvsctl holds it, on a descriptor of its own.
            running | both) exec 9< "$case_root/kvsctl/lock" && flock --exclusive 9 ;;
            # Held as kvsctl status holds it while it reads.
            watched) exec 9< "$case_root/kvsctl/lock" && flock --shared 9 ;;
        esac
        cd "$case_root/docker"
        SETUP_CALLS="$TEST_DIR/calls" PATH="$path" bash ./setup.sh "$@" < /dev/null
    ) > "$TEST_DIR/out" 2> "$TEST_DIR/err"
}

# refused <case> <kvsctl files> <reason> [arguments of setup.sh]
refused() {
    local name="$1" case_root="$TEST_DIR/kvsctl-run/$1" files="$2" reason="$3" status=0
    shift 3
    setup_run "$name" "$files" "$@" || status=$?
    [ "$status" -eq 1 ] || fail "setup.sh $* went on beside kvsctl ($files, status $status): $(cat "$TEST_DIR/out" "$TEST_DIR/err")"
    grep -Fxq "ERROR: $reason Nothing was changed." "$TEST_DIR/err" ||
        fail "setup.sh $* does not say why it stops ($files): $(cat "$TEST_DIR/err")"
    [ ! -s "$TEST_DIR/calls" ] || fail "setup.sh $* ran commands beside kvsctl ($files): $(cat "$TEST_DIR/calls")"
    [ ! -e "$case_root/logs" ] || fail "setup.sh $* wrote its logs beside kvsctl ($files)"
    [ ! -s "$TEST_DIR/out" ] || fail "setup.sh $* printed more than the refusal ($files): $(cat "$TEST_DIR/out")"
}

running_reason="kvsctl is running on this installation (it holds $TEST_DIR/kvsctl-run/%s/kvsctl/lock): wait until it is done; 'kvsctl status' shows what it does."
interrupted_reason="an interrupted kvsctl run left $TEST_DIR/kvsctl-run/%s/kvsctl/journal.json: run 'kvsctl recover' first. Where recover says to finish by hand and that takes setup.sh, remove that file, then run setup.sh again."
unknown_reason="could not tell whether kvsctl is running: flock $TEST_DIR/kvsctl-run/%s/kvsctl/lock failed with status 66."
# shellcheck disable=SC2059  # The reasons are the formats.
for args in '' '--dev' '--resume-import'; do
    name=${args:-plain}
    name=${name#--}
    refused "running-$name" running "$(printf "$running_reason" "running-$name")" $args
    refused "both-$name" both "$(printf "$running_reason" "both-$name")" $args
    refused "interrupted-$name" interrupted "$(printf "$interrupted_reason" "interrupted-$name")" $args
    refused "unknown-$name" unknown "$(printf "$unknown_reason" "unknown-$name")" $args
done

for files in idle watched none; do
    status=0
    setup_run "past-$files" "$files" || status=$?
    [ "$status" -eq 1 ] || fail "the stand-in Docker without Compose must end the run ($files, status $status): $(cat "$TEST_DIR/out" "$TEST_DIR/err")"
    grep -Fq 'Pre-flight Checks' "$TEST_DIR/out" ||
        fail "setup.sh did not get past the check of kvsctl ($files): $(cat "$TEST_DIR/out" "$TEST_DIR/err")"
    if grep -Fq 'kvsctl' "$TEST_DIR/out" "$TEST_DIR/err"; then
        fail "an installation kvsctl does not run on must not hear of it ($files): $(cat "$TEST_DIR/out" "$TEST_DIR/err")"
    fi
done
echo 'PASS: setup.sh starts nothing while kvsctl runs or after a kvsctl run that did not finish'

# Step 1 of the setup builds the images Compose builds on this stack: all
# of them on a checkout, Manticore only when it is enabled, and none on a
# stack kvsctl installed a release on, whose docker-compose.release.yml
# pins the image of every service the release builds and clears its build
# section, as kvsctl-release writes it. There the setup says that nothing
# is to be built, where Compose only warned "No services to build". A
# configuration Compose cannot read is left to the build, which says why.
# The docker CLI is a stand-in that logs every call and hands config to the
# real Docker Compose, which renders copies of the real compose files
# without a daemon.
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME
REAL_DOCKER=$(type -P docker) || fail 'docker is required to render the compose files'
export REAL_DOCKER BUILD_CALLS="$TEST_DIR/build-calls"
mkdir -p "$TEST_DIR/build-bin"
cat > "$TEST_DIR/build-bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$BUILD_CALLS"
[ "$1 $2" != 'compose config' ] || exec "$REAL_DOCKER" "$@"
exit 0
EOF
chmod +x "$TEST_DIR/build-bin/docker"
awk '
    $0 == "compose_services_to_build() {" || $0 == "setup_build_images() {" { capture = 1 }
    capture { print }
    capture && /^}$/ { capture = 0 }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/build-functions.sh"

# build_images <stack> <ENABLE_MANTICORE>: Step 1 on a copy of the docker
# directory, a "checkout" as kvs-install.sh clones it, a "release" stack
# with the release override and the images kvsctl writes to .env, or an
# "unreadable" one, whose .env lacks those images.
build_images() (
    local stack="$1" dir="$TEST_DIR/build-$1" digest
    digest="sha256:$(printf 'a%.0s' {1..64})"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp -R "$ROOT_DIR/docker/." "$dir/"
    printf '%s\n' DOMAIN=example.com SITE_PREFIX=kvs-example MARIADB_ROOT_PASSWORD=root-password \
        MARIADB_PASSWORD=site-password > "$dir/.env"
    if [ "$stack" != checkout ]; then
        cat > "$dir/docker-compose.release.yml" <<EOF
services:
  nginx:
    build: !reset null
    image: "ghcr.io/example/kvs-install/nginx:26.10.0@${digest}"
  php-fpm:
    build: !reset null
    image: "\${KVS_PHP_FPM_IMAGE:?kvsctl writes it to .env when it applies a release}"
  mariadb:
    image: "\${KVS_MARIADB_IMAGE:?kvsctl writes it to .env when it applies a release}"
  manticore:
    build: !reset null
    image: "ghcr.io/example/kvs-install/manticore:26.10.0@${digest}"
  cron:
    build: !reset null
    image: "\${KVS_CRON_IMAGE:?kvsctl writes it to .env when it applies a release}"
  kvs-init:
    build: !reset null
    image: "ghcr.io/example/kvs-install/init:26.10.0@${digest}"
EOF
        echo 'COMPOSE_FILE=docker-compose.yml:docker-compose.release.yml' >> "$dir/.env"
    fi
    if [ "$stack" = release ]; then
        printf '%s\n' "KVS_PHP_FPM_IMAGE=ghcr.io/example/kvs-install/php:26.10.0-php8.1@${digest}" \
            "KVS_CRON_IMAGE=ghcr.io/example/kvs-install/cron:26.10.0-php8.1@${digest}" \
            "KVS_MARIADB_IMAGE=mariadb:11.8.9@${digest}" >> "$dir/.env"
    fi
    : > "$BUILD_CALLS"
    cd "$dir"
    PATH="$TEST_DIR/build-bin:$PATH"
    progress_bar() { :; }
    run_step() { shift && "$@"; }
    ENABLE_MANTICORE=$2
    DOCKER_BUILD_FLAGS=''
    # shellcheck source=/dev/null
    source "$TEST_DIR/build-functions.sh"
    setup_build_images
)
builds() { grep '^compose build' "$BUILD_CALLS" | paste -sd'|' -; }

build_images checkout false > "$TEST_DIR/out" 2>&1 || fail "Step 1 failed on a checkout: $(cat "$TEST_DIR/out")"
[ "$(builds)" = 'compose build php-fpm|compose build cron|compose build nginx kvs-init' ] ||
    fail "a checkout must build every image but Manticore's: $(cat "$BUILD_CALLS")"
build_images checkout true > "$TEST_DIR/out" 2>&1 || fail "Step 1 failed on a checkout: $(cat "$TEST_DIR/out")"
[ "$(builds)" = 'compose build php-fpm|compose build cron|compose build nginx kvs-init manticore' ] ||
    fail "a checkout with search must build the Manticore image too: $(cat "$BUILD_CALLS")"
if grep -Fq 'nothing to build' "$TEST_DIR/out"; then fail "a checkout builds its images: $(cat "$TEST_DIR/out")"; fi

build_images release true > "$TEST_DIR/out" 2>&1 || fail "Step 1 failed on a release stack: $(cat "$TEST_DIR/out")"
[ -z "$(builds)" ] || fail "a release stack must build none of the images its release pins: $(cat "$BUILD_CALLS")"
for line in 'PHP-FPM container: its image is pinned, nothing to build' \
    'Cron container: its image is pinned, nothing to build' \
    'Nginx and initialization containers: their images are pinned, nothing to build'; do
    grep -Fxq "  ✓ $line" "$TEST_DIR/out" || fail "a release stack must say what it does not build: $(cat "$TEST_DIR/out")"
done

build_images unreadable true > "$TEST_DIR/out" 2>&1 || fail "Step 1 failed: $(cat "$TEST_DIR/out")"
[ "$(builds)" = 'compose build php-fpm|compose build cron|compose build nginx kvs-init manticore' ] ||
    fail "a configuration Compose cannot read must be left to the build: $(cat "$BUILD_CALLS")"
echo 'PASS: setup.sh builds the images Compose builds, none on a stack that runs the images of a release'
