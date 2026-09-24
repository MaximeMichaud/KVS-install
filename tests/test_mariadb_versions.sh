#!/bin/bash
# shellcheck disable=SC2016  # The grep patterns are literal lines of the scripts.
# The MariaDB series the Docker setup and the standalone installer offer, the
# defaults of the Compose files, .env.example, the multi-site manager and the
# README must name the same LTS series with the same default, newest first.
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

readme=$(tr -d '\r' < "$ROOT_DIR/README.md")
grep -Fq "MariaDB version (1=12.3, 2=11.8, 3=11.4)" <<< "$readme" || fail "README DB_CHOICE row is out of date"
grep -Fq "database_ver=${EXPECTED_DEFAULT} " <<< "$readme" || fail "README standalone example is out of date"
grep -Fq "MariaDB 11.4 LTS, 11.8 LTS or 12.3 LTS (Default)" <<< "$readme" || fail "README feature list is out of date"
grep -Eq '10\.6|10\.11' <<< "$readme" && fail "README still mentions a MariaDB series that is no longer offered"

echo "PASS: MariaDB series aligned (${EXPECTED_SERIES}, default ${EXPECTED_DEFAULT})"
