#!/bin/bash
# Compare the exact prepared SQL and replay each fixture in its own database.
# Pass --baseline <checkout> to compare replay status with another importer.
# shellcheck disable=SC2016  # Backticks quote identifiers in SQL fixtures.
set -euo pipefail

replay() {
    local file=$1 schema=$2
    {
        printf 'DROP DATABASE IF EXISTS `oldsite`; DROP DATABASE IF EXISTS `old``site`;\n'
        printf 'DROP DATABASE IF EXISTS imported; CREATE DATABASE %s; USE %s;\n' "$schema" "$schema"
        cat "$file"
        printf '\nSELECT * FROM v;\n'
    } | mariadb --comments -uroot -NB
}

check_replay() {
    local dir name schema base_status candidate_status expected failed=0
    for dir in /views/*/; do
        name=$(basename "$dir")
        schema='`oldsite`'
        if [ "$name" = crlf ]; then schema='`old``site`'; fi
        base_status=unmeasured
        if [ -e "$dir/base" ]; then
            if replay "$dir/base" imported > /tmp/base.rows 2>/tmp/base.error; then
                base_status=OK
            else
                base_status=$(awk '/^ERROR /{print $2; exit}' /tmp/base.error)
                [ -n "$base_status" ] || { cat /tmp/base.error >&2; return 1; }
            fi
        fi
        if replay "$dir/prepared" imported > /tmp/imported.rows 2>/tmp/imported.error; then
            candidate_status=OK
        else
            candidate_status=$(awk '/^ERROR /{print $2; exit}' /tmp/imported.error)
        fi
        printf '%s: base %s, prepared %s\n' "$name" "$base_status" "$candidate_status"
        case "$name" in
            empty_header|no_header) expected=1146 ;;
            possible_row) expected=1064 ;;
            *) expected=OK ;;
        esac
        if [ "$base_status" = OK ]; then expected=OK; fi
        if [ "$candidate_status" != "$expected" ]; then
            cat /tmp/imported.error >&2
            failed=1
        elif [ "$candidate_status" = OK ]; then
            replay "$dir/input" "$schema" > /tmp/source.rows
            diff -u /tmp/source.rows /tmp/imported.rows || failed=1
            if [ "$name" = inherited ]; then
                printf '1\n' | diff -u - /tmp/imported.rows || failed=1
                printf 'inherited row: %s\n' "$(cat /tmp/imported.rows)"
            elif [ "$name" = after_disagreement ]; then
                printf '%s\t1\n' 'before `oldsite`.`u`' | diff -u - /tmp/imported.rows || failed=1
                printf 'after_disagreement row: %s\n' "$(cat /tmp/imported.rows)"
            fi
        fi
    done
    return "$failed"
}

if [ "${1:-}" = --client ]; then
    check_replay
    exit
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
tmp=$(mktemp -d)
container=
cleanup() {
    if [ -n "$container" ]; then docker rm -fv "$container" >/dev/null; fi
    rm -rf "$tmp"
}
trap cleanup EXIT
mkdir "$tmp/views"

# Split the fixture once so the byte comparison and live replay exercise
# exactly the same input. Each marked prefix is an expected removal.
padding=$(printf '%65536s' '')
while IFS= read -r line; do
    case "$line" in
        '-- case '*)
            read -r name mode <<< "${line#-- case }"
            dir="$tmp/views/$name"
            mkdir "$dir"
            schema=oldsite ident='`oldsite`'
            if [ "$name" = crlf ]; then schema='old`site' ident='`old``site`'; fi
            {
                case "$name" in
                    crlf) printf '%s\r\n' "-- Host: localhost    Database: $schema" ;;
                    empty_header) echo '-- Host: localhost    Database: ' ;;
                    no_header) echo '-- MariaDB dump' ;;
                    *) echo "-- Host: localhost    Database: $schema" ;;
                esac
                if [ "$mode" != inherited ]; then printf "SET SQL_MODE='%s';\n" "$mode"; fi
                cat <<'SQL'
CREATE TABLE ktvs_options (variable varchar(255) PRIMARY KEY, value text);
CREATE TABLE t (id int, c int, created date, value text);
INSERT INTO t VALUES (7, 1, '2024-01-01', 'a''b');
CREATE TABLE u (c int);
INSERT INTO u VALUES (1);
CREATE TABLE oldsite (id int);
INSERT INTO oldsite VALUES (3);
CREATE TABLE `x``oldsite` (y int);
INSERT INTO `x``oldsite` VALUES (5);
CREATE FUNCTION f(i int) RETURNS int DETERMINISTIC RETURN i+1;
-- begin view fixture
SQL
            } > "$dir/input"
            : > "$dir/expected"
            : > "$dir/warnings"
            ;;
        '-- keep '*)
            read -r view reference <<< "${line#-- keep }"
            printf 'WARNING: View %s may use the old database name as a table or alias. Kept %s.\n' \
                "$view" "$reference" >> "$dir/warnings"
            ;;
        '-- possible_data '*)
            printf 'WARNING: View `%s` may be inside a data string under a different SQL mode. Its definition stays unchanged.\n' \
                "${line#-- possible_data }" >> "$dir/warnings"
            ;;
        '-- kept_tail '*)
            printf 'WARNING: View `%s` has ambiguous quoting under different SQL modes. Text after the first quoting disagreement was kept as written.\n' \
                "${line#-- kept_tail }" >> "$dir/warnings"
            ;;
        '-- disagreement '*)
            printf 'WARNING: View `%s` has ambiguous quoting under different SQL modes. Text after the first quoting disagreement was rewritten the old way. A string literal there may have lost the old database name.\n' \
                "${line#-- disagreement }" >> "$dir/warnings"
            ;;
        *)
            [ -n "${dir:-}" ] || continue
            line=${line//@padding@/$padding}
            input=${line//@db./$ident.}
            input=${input//@word./$schema.}
            printf '%s\n' "${input//@ansi./\"$schema\".}" >> "$dir/input"
            expected=${line//@db./}
            expected=${expected//@word./}
            printf '%s\n' "${expected//@ansi./}" >> "$dir/expected"
            ;;
    esac
done < "$root/tests/fixtures/import-views.sql"

for dir in "$tmp/views"/*/; do
    echo '-- end view fixture' >> "$dir/input"
    import_prepare_dump "$dir/input" ktvs_ 7.0.2 /site /site "$dir/prepared" token >/dev/null 2>"$dir/stderr" ||
        { cat "$dir/stderr" >&2; exit 1; }
    sed -n '/^-- begin view fixture$/,/^-- end view fixture$/{ /^-- \(begin\|end\) view fixture$/!p; }' "$dir/prepared" > "$dir/actual"
    diff -u "$dir/expected" "$dir/actual"
    diff -u "$dir/warnings" "$dir/stderr"
    if [ "${1:-}" = --baseline ]; then
        (
            # shellcheck source=/dev/null
            source "$2/docker/lib/import.sh"
            import_prepare_dump "$dir/input" ktvs_ 7.0.2 /site /site "$dir/base" token >/dev/null
        )
    fi
done
echo 'PASS: exact view SQL and warnings for every fixture'
[ "${1:-}" != --prepare-only ] || exit 0

image=mariadb:11.4.13
if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "SKIP: view replay requires the local $image image"
    exit 0
fi
container=$(docker run -d --network none --pull never --tmpfs /var/lib/mysql \
    -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "$image")
docker cp "$tmp/views" "$container:/views"
for ((i=0; i<120; i++)); do
    docker exec "$container" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break
    sleep 1
done
docker exec -i "$container" bash -s -- --client < "${BASH_SOURCE[0]}"
echo "PASS: view replays and returned bytes on $image"
