#!/bin/bash
# shellcheck disable=SC2016  # Literal script patterns and fixtures for fresh Bash/Compose loads.
# The MariaDB series the Docker setup and the standalone installer offer, the
# defaults of the Compose files, .env.example, the multi-site manager and the
# README must name the same LTS series with the same default, newest first,
# and docker/images.lock must pin an image of each series the setup offers.
# A bump made in one file must not leave another one on the previous default.
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MARIADB_TEST_PATH=$PATH
EXPECTED_DEFAULT=12.3
EXPECTED_SERIES="12.3 11.8 11.4"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

series=$(sed -n -E 's/^readonly MARIADB_LTS_VERSIONS=\((.*)\)$/\1/p' "$ROOT_DIR/docker/setup.sh" | tr -d '"')
[ "$series" = "$EXPECTED_SERIES" ] || fail "docker/setup.sh offers '$series', expected '$EXPECTED_SERIES'"
grep -Fq 'MARIADB_DEFAULT_VERSION="${MARIADB_LTS_VERSIONS[0]}"' "$ROOT_DIR/docker/setup.sh" ||
    fail "docker/setup.sh must take its default from the first LTS series"
grep -Fq 'for version in "${MARIADB_LTS_VERSIONS[@]}"; do' "$ROOT_DIR/docker/setup.sh" ||
    fail "the Docker menu must list MARIADB_LTS_VERSIONS"
grep -Fq '[ "$MARIADB_VERSION" != "$MARIADB_DEFAULT_VERSION" ]' "$ROOT_DIR/docker/setup.sh" ||
    fail "the keep-this-version question must compare with MARIADB_DEFAULT_VERSION"

default=$(sed -n -E 's/^ *database_ver=\$\{database_ver:-\$\{DATABASE_VER:-([0-9.]+)\}\}$/\1/p' "$ROOT_DIR/kvs-install.sh")
[ "$default" = "$EXPECTED_DEFAULT" ] || fail "kvs-install.sh headless default is '$default'"
series=$(sed -n -E 's/^ *database_ver="([0-9.]+)"$/\1/p' "$ROOT_DIR/kvs-install.sh" | tr '\n' ' ' | sed 's/ $//')
[ "$series" = "$EXPECTED_SERIES" ] || fail "kvs-install.sh menu maps to '$series'"
grep -Fq "MariaDB ${EXPECTED_DEFAULT} (Stable) (LTS) (Default)" "$ROOT_DIR/kvs-install.sh" ||
    fail "kvs-install.sh menu does not mark ${EXPECTED_DEFAULT} as the default"

for file in docker/docker-compose.yml docker/multi-site/docker-compose.site.yml.template; do
    grep -Fq "image: mariadb:\${MARIADB_VERSION:-${EXPECTED_DEFAULT}}" "$ROOT_DIR/$file" ||
        fail "$file does not default to mariadb:${EXPECTED_DEFAULT}"
done
grep -Fqx "MARIADB_VERSION=${EXPECTED_DEFAULT}" "$ROOT_DIR/docker/.env.example" ||
    fail "docker/.env.example does not carry MARIADB_VERSION=${EXPECTED_DEFAULT}"
grep -Fq "MARIADB_VERSION=${EXPECTED_DEFAULT}" "$ROOT_DIR/docker/multi-site/site-manager.sh" ||
    fail "site-manager.sh does not write MARIADB_VERSION=${EXPECTED_DEFAULT}"

# A stack keeps its MariaDB series across releases, and a release publishes
# the series docker/images.lock pins: every series setup.sh offers needs its
# tag in docker/bin/resolve-bases.sh and its line in the lock, or no release
# can upgrade a stack installed on it. The tag names a patch release, the
# version kvsctl compares with the build a server already runs.
tab=$'\t'
offered=$(sed -n -E 's/^readonly MARIADB_LTS_VERSIONS=\((.*)\)$/\1/p' "$ROOT_DIR/docker/setup.sh" | tr -d '"')
for one in $offered; do
    pattern=${one//./\\.}
    grep -Eq "^[[:space:]]*\"mariadb${tab}${pattern}${tab}mariadb:${pattern}\.[0-9]+\"$" "$ROOT_DIR/docker/bin/resolve-bases.sh" ||
        fail "docker/bin/resolve-bases.sh has no patch tag for MariaDB $one in RUNTIME_IMAGES"
    grep -Eq "^mariadb${tab}${pattern}${tab}mariadb:${pattern}\.[0-9]+@sha256:[0-9a-f]{64}$" "$ROOT_DIR/docker/images.lock" ||
        fail "docker/images.lock pins no image for MariaDB $one; run docker/bin/resolve-bases.sh"
done

readme=$(tr -d '\r' < "$ROOT_DIR/README.md")
grep -Fq "MariaDB version (1=12.3, 2=11.8, 3=11.4)" <<< "$readme" || fail "README DB_CHOICE row is out of date"
grep -Fq "database_ver=${EXPECTED_DEFAULT} " <<< "$readme" || fail "README standalone example is out of date"
grep -Fq "MariaDB 11.4 LTS, 11.8 LTS or 12.3 LTS (Default)" <<< "$readme" || fail "README feature list is out of date"
grep -Eq '10\.6|10\.11' <<< "$readme" && fail "README still mentions a MariaDB series that is no longer offered"

echo "PASS: MariaDB series aligned (${EXPECTED_SERIES}, default ${EXPECTED_DEFAULT})"

# setup.sh reads the MariaDB version of an existing database volume with
# the Alpine docker/images.lock pins, the one phpmyadmin-init runs, never
# whatever alpine:latest is on the day it pulls. A lock without that entry
# runs nothing and leaves the version unknown, which the setup then asks
# about. ask_existing_volume runs in a copy of the docker directory, beside
# the resolver; the docker CLI is a stand-in that logs its calls, finds the
# volume and reads MariaDB 11.8.9 from it. VOLUME_CHOICE=2 keeps it.
TEST_DIR=$(mktemp -d /tmp/kvs-mariadb-versions.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/docker/bin" "$TEST_DIR/stub"
cp "$ROOT_DIR/docker/bin/resolve-bases.sh" "$TEST_DIR/docker/bin/"
awk '
    $0 == "ask_existing_volume() {" { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/docker/volume.sh"
cat > "$TEST_DIR/stub/docker" <<'EOF'
#!/bin/bash
printf '%s|' "$@" >> "$DOCKER_CALLS"
echo >> "$DOCKER_CALLS"
case "$1 $2" in
    'compose config') printf 'volumes:\n  mariadb-data:\n    name: kvs_mariadb-data\n' ;;
    'volume ls') echo kvs_mariadb-data ;;
    'run --rm') echo 11.8.9-MariaDB ;;
esac
EOF
chmod +x "$TEST_DIR/stub/docker"

# check_volume <lock>: ask_existing_volume with that images.lock.
check_volume() (
    cd "$TEST_DIR/docker" || exit 1
    cp "$1" images.lock
    : > "$TEST_DIR/calls"
    export PATH="$TEST_DIR/stub:$PATH" DOCKER_CALLS="$TEST_DIR/calls"
    # shellcheck disable=SC2034  # Read by ask_existing_volume.
    CYAN='' GREEN='' RED='' YELLOW='' NC='' MARIADB_VERSION=11.8 VOLUME_CHOICE=2
    # shellcheck source=/dev/null
    source ./volume.sh
    ask_existing_volume
    echo "KEEP_EXISTING_DB=$KEEP_EXISTING_DB"
)

alpine=$(awk -F '\t' '$1 == "alpine" && $2 == "-" { print $3 }' "$ROOT_DIR/docker/images.lock")
[[ "$alpine" =~ ^alpine:[0-9.]+@sha256:[0-9a-f]{64}$ ]] ||
    fail "docker/images.lock pins no Alpine by digest: '$alpine'"
check_volume "$ROOT_DIR/docker/images.lock" > "$TEST_DIR/out" 2>&1 ||
    fail "the check of an existing volume failed: $(cat "$TEST_DIR/out")"
if [ "$(grep -c '^run|' "$TEST_DIR/calls")" -ne 1 ] ||
    ! grep -Fq "run|--rm|-v|kvs_mariadb-data:/data:ro|${alpine}|sh|-c|" "$TEST_DIR/calls"; then
    fail "the version of the volume must be read with $alpine, the Alpine of docker/images.lock: $(cat "$TEST_DIR/calls")"
fi
if ! grep -Fxq '  MariaDB version in volume: 11.8' "$TEST_DIR/out" || ! grep -Fxq 'KEEP_EXISTING_DB=true' "$TEST_DIR/out"; then
    fail "the version read from the volume must reach the question: $(cat "$TEST_DIR/out")"
fi

grep -v '^alpine' "$ROOT_DIR/docker/images.lock" > "$TEST_DIR/no-alpine.lock"
check_volume "$TEST_DIR/no-alpine.lock" > "$TEST_DIR/out" 2>&1 ||
    fail "the check of an existing volume failed: $(cat "$TEST_DIR/out")"
if grep -q '^run|' "$TEST_DIR/calls"; then
    fail "a lock without Alpine must run no image: $(cat "$TEST_DIR/calls")"
fi
if ! grep -Fq 'no entry for alpine' "$TEST_DIR/out" || ! grep -Fq 'VOLUME VERSION UNKNOWN' "$TEST_DIR/out"; then
    fail "a lock without Alpine must leave the version unknown and say why: $(cat "$TEST_DIR/out")"
fi
echo 'PASS: setup.sh reads the MariaDB version of an existing volume with the Alpine of docker/images.lock'


# A selected series must survive a new shell and Compose load without
# changing neighboring settings, including text that only resembles a key.
for function_name in prompt_read remove_env_value set_env_value mariadb_choice_is_valid select_mariadb_version choose_mariadb_version; do
    awk -v name="$function_name" '
        $0 == name "() {" { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$ROOT_DIR/docker/setup.sh" >> "$TEST_DIR/selector-functions.sh"
done
grep '^readonly MARIADB_LTS_VERSIONS=\|^readonly MARIADB_DEFAULT_VERSION=' "$ROOT_DIR/docker/setup.sh" >> "$TEST_DIR/selector-functions.sh"
printf '[{"cycle":"12.3","eol":"2035-01-01","support":"2034-01-01"},{"cycle":"11.8","eol":"2035-01-01","support":"2034-01-01"},{"cycle":"11.4","eol":"2035-01-01","support":"2034-01-01"}]\n' > "$TEST_DIR/api.json"
cat > "$TEST_DIR/selector-driver.sh" <<'EOF'
set -e
RED='' GREEN='' YELLOW='' CYAN='' NC=''
curl() {
    [ "$*" = '-s --connect-timeout 5 https://endoflife.date/api/mariadb.json' ] || return 99
    # CURL_FAIL=yes: endoflife.date does not answer (curl exit 28, a timeout).
    [ "${CURL_FAIL:-}" != yes ] || return 28
    cat "$MARIADB_TEST_ROOT/api.json"
}
source "$MARIADB_TEST_ROOT/selector-functions.sh"
source .env
if [ "${FAIL_WRITE:-}" = yes ]; then
    set_env_value() { return 23; }
fi
# KVSCTL_MANAGED=yes: kvsctl manages the stack and keeps its series.
kvsctl_manages_stack() { [ "${KVSCTL_MANAGED:-}" = yes ]; }
kvsctl_keep_mariadb_series() { echo KVSCTL_KEPT_SERIES; }
# SELECTION_ENTRY=choose_mariadb_version runs the step the setup runs, with
# its keep-this-version branch, instead of the selection alone.
"${SELECTION_ENTRY:-select_mariadb_version}"
echo SELECTION_FINISHED
EOF

for form in plain quoted exported indented commented duplicate interpolated multiline absent shadow_only real_shadow shared_first shared_last fake_only; do
    for choice in 1 2 3; do
        case_dir="$TEST_DIR/selection-$form-$choice"
        mkdir -p "$case_dir"
        case "$choice" in
            1) expected=12.3 ;;
            2) expected=11.8 ;;
            3) expected=11.4 ;;
        esac
        case "$form" in
            plain|multiline|real_shadow) settings='MARIADB_VERSION=11.8' ;;
            quoted) settings="MARIADB_VERSION='11.8'" ;;
            exported) settings='export MARIADB_VERSION=11.8' ;;
            indented) settings='  MARIADB_VERSION=11.8' ;;
            commented) settings='MARIADB_VERSION=11.8 # existing series' ;;
            duplicate) settings=$'MARIADB_VERSION=11.4\nexport MARIADB_VERSION=11.8' ;;
            interpolated) settings=$'DB_SEED=11.8\nMARIADB_VERSION="${DB_SEED}"' ;;
            shared_first) settings='export MARIADB_VERSION="11.8" EXTRA="neighbor"' ;;
            shared_last) settings='export EXTRA="neighbor" MARIADB_VERSION="11.8"' ;;
            *) settings='' ;;
        esac
        keep=stable shadow=''
        case "$form" in multiline|fake_only) keep=$'first\nMARIADB_VERSION=11.4\nlast' ;; esac
        case "$form" in shadow_only|real_shadow) shadow=11.4 ;; esac
        printf '%s\nKEEP="%s"\n' "$settings" "$keep" > "$case_dir/.env"
        case "$form" in shared_*) ;; *) echo 'EXTRA=neighbor' >> "$case_dir/.env" ;; esac
        [ -z "$shadow" ] || printf 'SHADOW_MARIADB_VERSION=%s\n' "$shadow" >> "$case_dir/.env"
        chmod 600 "$case_dir/.env"
        cat > "$case_dir/compose.yml" <<'EOF'
services:
  db:
    image: mariadb:${MARIADB_VERSION:-12.3}
    environment:
      EXTRA: ${EXTRA:-}
      KEEP: ${KEEP:-}
      SHADOW: ${SHADOW_MARIADB_VERSION:-}
EOF
        (
            cd "$case_dir" || exit 1
            env -i PATH="$MARIADB_TEST_PATH" TMPDIR="${TMPDIR:-$TEST_DIR}" MARIADB_TEST_ROOT="$TEST_DIR" DB_CHOICE="$choice" \
                bash "$TEST_DIR/selector-driver.sh"
        ) > "$case_dir/output" 2>&1 || fail "$form/$choice selection failed: $(cat "$case_dir/output")"
        grep -Fq "Selected MariaDB $expected" "$case_dir/output" || fail 'selection did not report its saved series'
        env -i PATH="$MARIADB_TEST_PATH" bash -c 'source "$1/.env"; printf "%s\0%s\0%s\0%s" "${MARIADB_VERSION-}" "${EXTRA-}" "$KEEP" "${SHADOW_MARIADB_VERSION-}"' \
            bash "$case_dir" > "$case_dir/saved" || fail 'fresh load failed'
        (
            cd "$case_dir" || exit 1
            env -i PATH="$MARIADB_TEST_PATH" DOCKER_HOST="unix://$case_dir/absent.sock" DOCKER_CONFIG="$case_dir/docker-config" \
                docker compose -p kvs-version-selection -f compose.yml config --format json
        ) > "$case_dir/model.json" 2> "$case_dir/compose.err" || fail "Compose rejected $form/$choice: $(cat "$case_dir/compose.err")"
        if ! python3 - "$case_dir" "$expected" "$keep" "$shadow" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1]);expected,keep,shadow=sys.argv[2:]
saved=(p/'saved').read_text().split('\0')
assert saved==[expected,'neighbor',keep,shadow],(p.name,saved)
model=json.loads((p/'model.json').read_text())['services']['db']
assert model['image']=='mariadb:'+expected,model
assert model['environment']==dict(EXTRA='neighbor',KEEP=keep,SHADOW=shadow),model
assert (p/'.env').stat().st_mode & 0o777==0o600
assert not list(p.glob('.env.tmp.*'))
PY
        then
            fail "$form/$choice did not preserve the selected series and its neighbors"
        fi
    done
done
echo 'PASS: all offered MariaDB choices survive fresh Bash and Compose loads without changing other values'

case_dir="$TEST_DIR/refused-selection"
mkdir -p "$case_dir"
printf 'MARIADB_VERSION=11.8\nEXTRA=neighbor\n' > "$case_dir/.env"
cp "$case_dir/.env" "$case_dir/before.env"
(
    cd "$case_dir" || exit 1
    env -i PATH="$MARIADB_TEST_PATH" MARIADB_TEST_ROOT="$TEST_DIR" DB_CHOICE=1 FAIL_WRITE=yes bash "$TEST_DIR/selector-driver.sh"
) > "$case_dir/output" 2>&1
status=$?
[ "$status" = 23 ] || fail "a refused MariaDB setting returned $status instead of 23"
cmp -s "$case_dir/.env" "$case_dir/before.env" || fail 'a refused selection changed .env'
if grep -Eq 'Selected MariaDB|SELECTION_FINISHED' "$case_dir/output"; then
    fail 'a failed MariaDB write reported success or continued'
fi
echo 'PASS: a failed MariaDB setting stops selection before announcing success'


# D8: the menu is built from MARIADB_LTS_VERSIONS, not from endoflife.date,
# so DB_CHOICE applies whether the lookup answers or not. The lookup only
# adds the support status. A DB_CHOICE outside the list stops the selection
# instead of being dropped silently; an answer typed at the prompt is asked
# again.
# run_selection <name> <input> [VAR=value...]: the selection with that
# standard input, on a .env holding MARIADB_VERSION=$D8_SAVED (default 12.3).
run_selection() {
    local name=$1 input=$2
    shift 2
    case_dir="$TEST_DIR/d8-$name"
    mkdir -p "$case_dir"
    printf 'MARIADB_VERSION=%s\nEXTRA=neighbor\n' "${D8_SAVED:-12.3}" > "$case_dir/.env"
    cp "$case_dir/.env" "$case_dir/before.env"
    (
        cd "$case_dir" || exit 1
        printf '%s' "$input" |
            env -i PATH="$MARIADB_TEST_PATH" MARIADB_TEST_ROOT="$TEST_DIR" "$@" bash "$TEST_DIR/selector-driver.sh"
    ) > "$case_dir/output" 2>&1
    status=$?
}
saved_series() {
    env -i PATH="$MARIADB_TEST_PATH" bash -c 'source "$1/.env"; printf "%s" "${MARIADB_VERSION-}"' bash "$case_dir"
}
assert_selected() {
    local expected=$1 label=$2
    [ "$status" = 0 ] || fail "$label: the selection failed ($status): $(cat "$case_dir/output")"
    grep -Fq "Selected MariaDB $expected" "$case_dir/output" ||
        fail "$label: MariaDB $expected was not selected: $(cat "$case_dir/output")"
    [ "$(saved_series)" = "$expected" ] || fail "$label: .env holds MARIADB_VERSION=$(saved_series), expected $expected"
    grep -Fq SELECTION_FINISHED "$case_dir/output" || fail "$label: the selection did not return"
}
assert_refused() {
    local label=$1
    [ "$status" != 0 ] || fail "$label: an invalid choice was accepted: $(cat "$case_dir/output")"
    cmp -s "$case_dir/.env" "$case_dir/before.env" || fail "$label: a refused choice changed .env"
    grep -q 'SELECTION_FINISHED\|Selected MariaDB' "$case_dir/output" && fail "$label: a refused choice went on"
    grep -q 'integer expression expected' "$case_dir/output" && fail "$label: the choice reached a numeric test"
    return 0
}

for choice in 1 2 3; do
    case "$choice" in 1) expected=12.3 ;; 2) expected=11.8 ;; 3) expected=11.4 ;; esac
    run_selection "api-down-$choice" '' CURL_FAIL=yes DB_CHOICE="$choice"
    assert_selected "$expected" "DB_CHOICE=$choice with endoflife.date down"
done
run_selection api-down-leading-zero '' CURL_FAIL=yes DB_CHOICE=03
assert_selected 11.4 'DB_CHOICE=03 with endoflife.date down'
echo 'PASS: DB_CHOICE selects its series when endoflife.date does not answer'

run_selection interactive-api-down $'3\n' CURL_FAIL=yes
assert_selected 11.4 'an interactive answer with endoflife.date down'
grep -Fq 'Select MariaDB version [1-3]' "$case_dir/output" ||
    fail "the series list must still be offered when endoflife.date does not answer: $(cat "$case_dir/output")"
grep -Fq '1) MariaDB 12.3' "$case_dir/output" || fail "the offered list must name each series: $(cat "$case_dir/output")"
run_selection interactive-default $'\n' CURL_FAIL=yes
assert_selected 12.3 'Enter at the prompt with endoflife.date down'
run_selection interactive-reask $'9\nx\n2\n' CURL_FAIL=yes
assert_selected 11.8 'an interactive answer after two invalid ones'
[ "$(grep -c 'is not a choice from 1 to 3' "$case_dir/output")" = 2 ] ||
    fail "each invalid answer must be refused and asked again: $(cat "$case_dir/output")"
run_selection interactive-huge $'18446744073709551617\n2\n' CURL_FAIL=yes
assert_selected 11.8 'an interactive answer after a number bash arithmetic wraps'
grep -Fq '18446744073709551617 is not a choice from 1 to 3' "$case_dir/output" ||
    fail "a number bash arithmetic wraps to 1 must be refused and asked again: $(cat "$case_dir/output")"
run_selection interactive-eof '' CURL_FAIL=yes
assert_refused 'no answer at the prompt (end of input)'
grep -Fq 'no answer left on standard input' "$case_dir/output" ||
    fail "the end of input at the prompt must stop with the prompt_read error: $(cat "$case_dir/output")"
echo 'PASS: an interactive run is offered the series list without endoflife.date and asked again on an invalid answer'

for api in up down; do
    for bad in 0 4 x 1x ' 2' -1 1000 18446744073709551617; do
        if [ "$api" = down ]; then
            run_selection "bad-$api" '' CURL_FAIL=yes DB_CHOICE="$bad"
        else
            run_selection "bad-$api" '' DB_CHOICE="$bad"
        fi
        assert_refused "DB_CHOICE='$bad' with endoflife.date $api"
        grep -Fq "DB_CHOICE=$bad is not a choice from 1 to 3" "$case_dir/output" ||
            fail "DB_CHOICE='$bad' must be named in the error: $(cat "$case_dir/output")"
    done
done
echo 'PASS: a DB_CHOICE outside the offered series stops the selection, with or without endoflife.date'


# The setup runs choose_mariadb_version, which keeps a series saved in .env
# other than the default (KEEP_VERSION=Y, the headless default) and lets
# kvsctl keep the series of a stack it manages; neither reaches the
# selection. A DB_CHOICE that names no series stops either way, before
# MARIADB_VERSION changes, instead of being accepted without a word.
for saved in 11.8 12.3; do
    for bad in 9 0 x 18446744073709551617; do
        D8_SAVED=$saved run_selection "choose-$saved" '' SELECTION_ENTRY=choose_mariadb_version KEEP_VERSION=Y DB_CHOICE="$bad"
        assert_refused "DB_CHOICE='$bad' with MariaDB $saved saved"
        grep -Fq "DB_CHOICE=$bad is not a choice from 1 to 3" "$case_dir/output" ||
            fail "DB_CHOICE='$bad' with MariaDB $saved saved must be named in the error: $(cat "$case_dir/output")"
        grep -Fq 'Keeping MariaDB' "$case_dir/output" &&
            fail "DB_CHOICE='$bad' must stop before the saved series is kept: $(cat "$case_dir/output")"
    done
done
D8_SAVED=11.8 run_selection choose-keep '' SELECTION_ENTRY=choose_mariadb_version KEEP_VERSION=Y DB_CHOICE=3
if [ "$status" != 0 ] || ! grep -Fq 'Keeping MariaDB 11.8' "$case_dir/output" || ! grep -Fq SELECTION_FINISHED "$case_dir/output"; then
    fail "a valid DB_CHOICE with KEEP_VERSION=Y must keep the saved series: $(cat "$case_dir/output")"
fi
cmp -s "$case_dir/.env" "$case_dir/before.env" || fail 'keeping the saved series changed .env'
run_selection choose-kvsctl-bad '' SELECTION_ENTRY=choose_mariadb_version KVSCTL_MANAGED=yes DB_CHOICE=9
assert_refused 'DB_CHOICE=9 on a stack kvsctl manages'
grep -Fq KVSCTL_KEPT_SERIES "$case_dir/output" && fail "DB_CHOICE=9 must stop before kvsctl keeps its series: $(cat "$case_dir/output")"
run_selection choose-kvsctl '' SELECTION_ENTRY=choose_mariadb_version KVSCTL_MANAGED=yes DB_CHOICE=1
if [ "$status" != 0 ] || ! grep -Fq KVSCTL_KEPT_SERIES "$case_dir/output"; then
    fail "a valid DB_CHOICE on a stack kvsctl manages must leave the series to kvsctl: $(cat "$case_dir/output")"
fi
echo 'PASS: a DB_CHOICE outside the offered series stops the setup when .env keeps another series or kvsctl manages it'
