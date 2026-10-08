#!/bin/bash
# shellcheck disable=SC2016  # The grep patterns are literal lines of the scripts.
# The MariaDB series the Docker setup and the standalone installer offer, the
# defaults of the Compose files, .env.example, the multi-site manager and the
# README must name the same LTS series with the same default, newest first,
# and docker/images.lock must pin an image of each series the setup offers.
# A bump made in one file must not leave another one on the previous default.
set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
