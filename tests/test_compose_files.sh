#!/bin/bash
# shellcheck disable=SC2016,SC2034,SC2329  # Literal code of setup.sh; the variables and stubs are used by the extracted functions.
# The compose files are read by whatever Docker Compose v2 the host has, so
# they keep to what every one of them parses: a default nested in another
# (${A:-x${B:-y}}) stops Compose older than 2.18 from reading the whole
# file. The PHP base therefore reaches the Dockerfiles as given, empty when
# .env names none, and the Dockerfiles fall back to the php:<series> tag
# themselves. The init container gets the settings its scripts read from
# .env. And setup.sh checks that Compose reads the files before it stops or
# removes anything of a running stack.
# No daemon, network, container or image is used: Compose only renders.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-compose-files.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Settings exported by the caller would hide what the files say.
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES \
    PHP_VERSION PHP_FPM_BASE PHP_CLI_BASE MANTICORE_PLUGIN_URL MANTICORE_PLUGIN_SHA256
real_docker=$(type -P docker) || fail 'docker is required to render the compose files'

compose_files=(
    "$ROOT_DIR/docker/docker-compose.yml"
    "$ROOT_DIR/docker/docker-compose.multi.yml"
    "$ROOT_DIR/docker/docker-compose.override.yml.example"
    "$ROOT_DIR/docker/multi-site/docker-compose.caddy.yml"
    "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template"
)

# 1. No default nested in another, outside comments ($$ is a literal $).
for file in "${compose_files[@]}"; do
    [ -f "$file" ] || fail "$file is missing"
    nested=$(sed -e 's/\$\$//g' "$file" |
        grep -nE '^[^#]*\$\{[A-Za-z_][A-Za-z0-9_]*:?[-+?=][^}]*\$\{' || true)
    [ -z "$nested" ] ||
        fail "${file#"$ROOT_DIR"/} nests a default in another, which Docker Compose older than 2.18 cannot read: $nested"
done
echo 'PASS: no compose file nests a default in another'

# 2. The PHP-FPM and cron Dockerfiles fall back to the php:<series> tag of
# their image type when PHP_BASE is empty, in a global argument the FROM
# line reads, and pass PHP_VERSION on to the stage.
for spec in php:fpm cron:cli; do
    dir=${spec%%:*}
    variant=${spec#*:}
    dockerfile="$ROOT_DIR/docker/$dir/Dockerfile"
    header=$(awk '/^FROM / { print; exit } /^ARG / { print }' "$dockerfile")
    grep -Fxq 'ARG PHP_VERSION=8.1' <<< "$header" ||
        fail "$dir/Dockerfile must declare PHP_VERSION before FROM: $header"
    grep -Eq "^ARG PHP_BASE=php:8\\.1-${variant}@sha256:[0-9a-f]{64}\$" <<< "$header" ||
        fail "$dir/Dockerfile must default PHP_BASE to the pinned 8.1 base: $header"
    grep -Fxq "ARG PHP_FROM=\${PHP_BASE:-php:\${PHP_VERSION}-${variant}}" <<< "$header" ||
        fail "$dir/Dockerfile must fall back to php:<PHP_VERSION>-${variant} for an empty PHP_BASE: $header"
    # An ARG default reads only the arguments declared above it: with
    # PHP_BASE below PHP_FROM, the base Compose passes is never used, and
    # with PHP_VERSION below it, an empty PHP_BASE builds FROM
    # php:-${variant}.
    from_line=$(grep -n '^ARG PHP_FROM=' <<< "$header" | cut -d: -f1)
    for arg in PHP_VERSION PHP_BASE; do
        line=$(grep -n "^ARG ${arg}=" <<< "$header" | cut -d: -f1)
        [ "$line" -lt "$from_line" ] ||
            fail "$dir/Dockerfile must declare $arg before PHP_FROM, whose default reads it: $header"
    done
    [ "$(tail -n 1 <<< "$header")" = 'FROM ${PHP_FROM}' ] ||
        fail "$dir/Dockerfile must build FROM \${PHP_FROM}: $header"
    awk '/^FROM / { stage = 1; next } stage && /^ARG PHP_VERSION$/ { found = 1; exit } END { exit !found }' "$dockerfile" ||
        fail "$dir/Dockerfile must bring PHP_VERSION into its stage"
done
echo 'PASS: the PHP-FPM and cron Dockerfiles build an empty PHP_BASE from the php tag of the series'

# render <output> <env file> <compose arguments...>: the model with every
# profile the files declare.
render() {
    local output="$1" env_file="$2" profile
    local -a profiles=()
    shift 2

    while IFS= read -r profile; do
        profiles+=(--profile "$profile")
    done < <("$real_docker" compose --env-file "$env_file" "$@" config --profiles)
    "$real_docker" compose --env-file "$env_file" "$@" "${profiles[@]}" config --format json > "$output" ||
        fail "Compose could not render $*"
}

# An .env as setup.sh left it before the lock: no base, no Manticore plugin
# setting.
cat > "$TEST_DIR/plain.env" <<'EOF'
DOMAIN=example.com
SITE_PREFIX=kvs-example
COMPOSE_PROJECT_NAME=kvs-example
MARIADB_ROOT_PASSWORD=test-root
MARIADB_PASSWORD=test-user
PHP_VERSION=8.3
EOF
fpm="php:8.3-fpm@sha256:$(printf '%064d' 0 | tr 0 a)"
cli="php:8.3-cli@sha256:$(printf '%064d' 0 | tr 0 b)"
cp "$TEST_DIR/plain.env" "$TEST_DIR/set.env"
cat >> "$TEST_DIR/set.env" <<EOF
PHP_FPM_BASE=$fpm
PHP_CLI_BASE=$cli
MANTICORE_PLUGIN_URL=https://plugins.example.org/manticore.zip
MANTICORE_PLUGIN_SHA256=$(printf '%064d' 0 | tr 0 c)
EOF

# 3. The PHP base and the Manticore plugin settings of .env, or nothing.
for layout in single multi site; do
    case "$layout" in
        single) files=(-f "$ROOT_DIR/docker/docker-compose.yml") ;;
        multi) files=(-f "$ROOT_DIR/docker/docker-compose.yml" -f "$ROOT_DIR/docker/docker-compose.multi.yml") ;;
        site) files=(-f "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template") ;;
    esac
    render "$TEST_DIR/plain.json" "$TEST_DIR/plain.env" "${files[@]}"
    render "$TEST_DIR/set.json" "$TEST_DIR/set.env" "${files[@]}"

    jq -e '.services["php-fpm"].build.args == {"PHP_VERSION": "8.3", "PHP_BASE": ""} and
        .services.cron.build.args == {"PHP_VERSION": "8.3", "PHP_BASE": ""}' "$TEST_DIR/plain.json" > /dev/null ||
        fail "$layout: without a base in .env, PHP_BASE must reach the build empty: $(jq -c '[.services["php-fpm"].build.args, .services.cron.build.args]' "$TEST_DIR/plain.json")"
    jq -e --arg fpm "$fpm" --arg cli "$cli" '.services["php-fpm"].build.args.PHP_BASE == $fpm and
        .services.cron.build.args.PHP_BASE == $cli' "$TEST_DIR/set.json" > /dev/null ||
        fail "$layout: the bases of .env must reach the build: $(jq -c '[.services["php-fpm"].build.args, .services.cron.build.args]' "$TEST_DIR/set.json")"

    jq -e '.services["kvs-init"].environment.MANTICORE_PLUGIN_URL == "" and
        .services["kvs-init"].environment.MANTICORE_PLUGIN_SHA256 == ""' "$TEST_DIR/plain.json" > /dev/null ||
        fail "$layout: kvs-init must get empty Manticore plugin settings by default: $(jq -c '.services["kvs-init"].environment' "$TEST_DIR/plain.json")"
    jq -e --arg sha "$(printf '%064d' 0 | tr 0 c)" '.services["kvs-init"].environment.MANTICORE_PLUGIN_URL == "https://plugins.example.org/manticore.zip" and
        .services["kvs-init"].environment.MANTICORE_PLUGIN_SHA256 == $sha' "$TEST_DIR/set.json" > /dev/null ||
        fail "$layout: kvs-init must get the Manticore plugin settings of .env: $(jq -c '.services["kvs-init"].environment' "$TEST_DIR/set.json")"
    if [ "$layout" = site ]; then
        # A site runs no Manticore, so the comment on these settings must
        # say they are unused there rather than promise a search it lacks.
        jq -e '(.services | has("manticore") | not) and
            (.services["kvs-init"].environment | has("ENABLE_MANTICORE") | not)' "$TEST_DIR/plain.json" > /dev/null ||
            fail 'a site made from the template can run Manticore now: update the comment above its MANTICORE_PLUGIN_URL'
        comment=$(awk '
            /^[[:space:]]*#/ { block = block $0 "\n"; next }
            /^[[:space:]]*- MANTICORE_PLUGIN_URL=/ { printf "%s", block; exit }
            { block = "" }
        ' "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template")
        if ! grep -Eq '^[[:space:]]*# Unused on a site' <<< "$comment" || ! grep -Fq 'ENABLE_MANTICORE' <<< "$comment"; then
            fail "the template must say that a site does not use the Manticore plugin settings, and why: $comment"
        fi
    fi
done
for key in MANTICORE_PLUGIN_URL MANTICORE_PLUGIN_SHA256; do
    grep -Fxq "${key}=" "$ROOT_DIR/docker/.env.example" || fail ".env.example must document ${key}"
    grep -Fq "$key" "$ROOT_DIR/docker/init/docker-entrypoint.d/80-manticore.sh" ||
        fail "80-manticore.sh no longer reads ${key}: drop it from the compose files"
done
echo 'PASS: the PHP bases and the Manticore plugin settings of .env reach the build and kvs-init'

# 4. setup.sh checks that Compose reads the files, and says what it found.
awk '
    $0 == "require_compose_config() {" { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/functions.sh"
declare -F require_compose_config > /dev/null || fail 'setup.sh must define require_compose_config'
RED='' NC=''

# The real Compose on the real files, then on a file it cannot read.
cp "$TEST_DIR/plain.env" "$TEST_DIR/work.env"
compose_args=(-f "$ROOT_DIR/docker/docker-compose.yml")
docker() {
    [ "$1" = compose ] || return 97
    shift
    "$real_docker" compose --env-file "$TEST_DIR/work.env" "${compose_args[@]}" "$@"
}
require_compose_config > "$TEST_DIR/out" 2>&1 || fail "the compose files must pass the check: $(cat "$TEST_DIR/out")"
[ ! -s "$TEST_DIR/out" ] || fail "a check that passes must print nothing: $(cat "$TEST_DIR/out")"
printf 'services:\n  php-fpm:\n    image: ${BROKEN\n' > "$TEST_DIR/broken.yml"
compose_args+=(-f "$TEST_DIR/broken.yml")
if require_compose_config > "$TEST_DIR/out" 2>&1; then
    fail "a compose file Compose cannot read must stop the setup"
fi
grep -Eq '^ERROR: Docker Compose [0-9]+\.[0-9]+\.[0-9]+ cannot read the compose files of this installation:$' "$TEST_DIR/out" ||
    fail "the refusal must name the Compose version: $(cat "$TEST_DIR/out")"
grep -Eq '^  .*(interpolation|BROKEN)' "$TEST_DIR/out" || fail "the refusal must show what Compose said: $(cat "$TEST_DIR/out")"
grep -Fq 'Nothing was stopped: the running containers keep serving.' "$TEST_DIR/out" ||
    fail "the refusal must say that nothing was stopped: $(cat "$TEST_DIR/out")"

# Compose 2.17 on a file with a nested default, as the refusal shows it.
docker() {
    case "$*" in
        'compose config --quiet')
            echo "invalid interpolation format for services.php-fpm.build.args.PHP_BASE: \"php:\${PHP_VERSION:-8.1\". You may need to escape any \$ with another \$." >&2
            return 15
            ;;
        'compose version') echo 'Docker Compose version v2.17.3' ;;
        *) return 97 ;;
    esac
}
if require_compose_config > "$TEST_DIR/out" 2>&1; then fail "Compose 2.17.3 failing the check must stop the setup"; fi
grep -Fxq 'ERROR: Docker Compose 2.17.3 cannot read the compose files of this installation:' "$TEST_DIR/out" ||
    fail "the refusal must name Compose 2.17.3: $(cat "$TEST_DIR/out")"
grep -Fq '  invalid interpolation format for services.php-fpm.build.args.PHP_BASE' "$TEST_DIR/out" ||
    fail "the refusal must show the error: $(cat "$TEST_DIR/out")"
# A check that runs once this run may have removed a container says what
# is true there instead of "Nothing was stopped".
if require_compose_config 'What this point of the run left as it was.' > "$TEST_DIR/out" 2>&1; then
    fail "Compose failing a later check must stop the setup"
fi
grep -Fxq 'What this point of the run left as it was.' "$TEST_DIR/out" ||
    fail "a later check must say what the caller passes: $(cat "$TEST_DIR/out")"
if grep -Fq 'Nothing was stopped' "$TEST_DIR/out"; then
    fail "a later check must not claim that nothing was stopped: $(cat "$TEST_DIR/out")"
fi
unset -f docker
echo 'PASS: setup.sh stops on compose files Compose cannot read and says why'

# 5. The checks that come before configure_mode read the files it records
# for the mode of the last run, not the COMPOSE_FILE that run left in .env:
# an override deleted by hand since then drops out, as configure_mode drops
# it, and a file that is there is read, broken or not. Each check runs as
# setup.sh has it, with the real Compose on the real files.
awk '
    $0 == "compose_files_for() {" { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/files.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/files.sh"
first_check=$(grep -m 1 -E '^([^[:space:]#].*)?require_compose_config( |$)' "$ROOT_DIR/docker/setup.sh") ||
    fail 'setup.sh has no check of the compose files before configure_mode'
earlier_check=$(grep -m 1 -E '^[[:space:]]+([^[:space:]#].*)?require_compose_config( |$)' "$ROOT_DIR/docker/setup.sh") ||
    fail 'setup.sh has no check before it removes the containers of an earlier stack'
project="$TEST_DIR/project"
mkdir -p "$project"
cp "$ROOT_DIR/docker/docker-compose.yml" "$ROOT_DIR/docker/docker-compose.multi.yml" "$project/"

# run_check <check> <MODE> [COMPOSE_FILE]: the check in the project, with
# an .env as the last run left it.
run_check() {
    {
        cat "$TEST_DIR/plain.env"
        printf 'MODE=%s\n' "$2"
        [ -z "${3:-}" ] || printf 'COMPOSE_FILE=%s\n' "$3"
    } > "$project/.env"
    (cd "$project" && MODE=$2 && eval "$1") > "$TEST_DIR/out" 2>&1
}
# broken <file>: a compose file Compose cannot read.
broken() {
    printf 'services:\n  php-fpm:\n    image: ${BROKEN\n' > "$project/$1"
}

run_check "$first_check" multi docker-compose.yml:docker-compose.override.yml:docker-compose.multi.yml ||
    fail "an override deleted by hand on a multi site must not stop the setup, configure_mode drops it: $(cat "$TEST_DIR/out")"
for check in "$first_check" "$earlier_check"; do
    run_check "$check" single docker-compose.yml:docker-compose.release.yml ||
        fail "release pins deleted by hand must not stop the setup, configure_mode drops them: $check: $(cat "$TEST_DIR/out")"
done

broken docker-compose.override.yml
if run_check "$first_check" multi docker-compose.yml:docker-compose.multi.yml; then
    fail 'a broken docker-compose.override.yml must stop the setup'
fi
grep -Eq '^  .*(interpolation|BROKEN)' "$TEST_DIR/out" || fail "the refusal must show what Compose said: $(cat "$TEST_DIR/out")"
rm "$project/docker-compose.override.yml"
broken docker-compose.release.yml
for check in "$first_check" "$earlier_check"; do
    if run_check "$check" single docker-compose.yml:docker-compose.release.yml; then
        fail "broken release pins that COMPOSE_FILE names must stop the setup: $check"
    fi
    run_check "$check" single ||
        fail "release pins that COMPOSE_FILE does not name are not used, so not read: $check: $(cat "$TEST_DIR/out")"
done
rm "$project/docker-compose.release.yml"
broken docker-compose.multi.yml
if run_check "$first_check" multi docker-compose.yml:docker-compose.multi.yml; then
    fail 'a multi site must read docker-compose.multi.yml'
fi
run_check "$first_check" single || fail "a single site does not use docker-compose.multi.yml: $(cat "$TEST_DIR/out")"
echo 'PASS: the first checks read the compose files configure_mode records'

# 6. Wiring: a first check once the PHP bases are set and before the cache,
# TLS and search choices, which remove the containers they retire; a second
# one once the mode and the profiles are settled, before the volume
# question, the stop of the running containers and any build, saying what
# those choices may have removed. The containers of an earlier stack
# removed for an import under a new domain are checked for first too.
setup="$ROOT_DIR/docker/setup.sh"
line_of() {
    local found

    found=$(grep -nxF -- "$1" "$setup" | cut -d: -f1)
    [ -n "$found" ] || fail "setup.sh has no line '$1'"
    [ "$(printf '%s\n' "$found" | wc -l)" -eq 1 ] || fail "setup.sh has more than one line '$1'"
    printf '%s\n' "$found"
}
first_line_with() {
    local found

    found=$(grep -nF -m 1 -- "$1" "$setup" | cut -d: -f1)
    [ -n "$found" ] || fail "setup.sh has no line holding '$1'"
    printf '%s\n' "$found"
}
comes_before() {
    [ "$1" -lt "$2" ] || fail "$3 (line $1 is not before line $2)"
}

first=$(line_of 'COMPOSE_FILE=$(compose_files_for "$MODE") require_compose_config || exit 1')
comes_before "$(line_of 'set_php_bases')" "$first" "the first check must come after the PHP bases are set"
for retiring in 'select_cache' 'configure_mode || exit $?' 'setup_select_manticore'; do
    comes_before "$first" "$(line_of "$retiring")" "the first check must come before $retiring, which can remove a container"
done

late=$(grep -n '^require_compose_config "' "$setup" | cut -d: -f1)
[ "$(printf '%s\n' "$late" | grep -c .)" -eq 1 ] || fail "setup.sh must have one check with a message of its own: '$late'"
late_line=$(sed -n "${late}p" "$setup")
for retired in 'cache server' 'ACME' 'Manticore'; do
    grep -Fq "$retired" <<< "$late_line" || fail "the later check must name what the choices may have removed ($retired): $late_line"
done
if grep -Fq 'Nothing was stopped' <<< "$late_line"; then
    fail "the later check must not claim that nothing was stopped: $late_line"
fi
grep -Eq '\|\| exit 1$' <<< "$late_line" || fail "the later check must stop the setup: $late_line"
for settled in 'configure_mode || exit $?' 'select_cache' 'setup_select_manticore' 'set_php_bases'; do
    comes_before "$(line_of "$settled")" "$late" "the later check must come after $settled"
done
comes_before "$late" "$(line_of 'import_require_empty_volume')" "the check must come before the volume of an import is checked"
comes_before "$late" "$(line_of '    ask_existing_volume')" "the check must come before the volume question, which can delete it"
comes_before "$late" "$(line_of 'database_configure_resources || exit 1')" "the check must come before the database settings"
comes_before "$late" "$(first_line_with 'echo "Stopping existing containers..."')" "the check must come before the running containers are stopped"
comes_before "$late" "$(first_line_with 'docker compose build')" "the check must come before anything is built"

earlier=$(line_of '        COMPOSE_FILE=$(compose_files_for "$MODE") require_compose_config || exit 1')
comes_before "$(line_of 'require_compose_config() {')" "$earlier" "require_compose_config must be defined before its first use"
comes_before "$(line_of 'compose_files_for() {')" "$earlier" "compose_files_for must be defined before its first use"
comes_before "$earlier" "$(first_line_with 'Removing the containers of')" \
    "the check must come before the containers of an earlier stack are removed"
echo 'PASS: setup.sh checks the compose files before it stops anything'
