#!/bin/bash
# The served-name check reads operator routes the way Caddy does: quoted
# names, headers on several lines, snippets and imported files.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/docker"
(cd "$root/docker" && cp --parents .gitignore images.lock bin/resolve-bases.sh lib/kvs-php.sh \
    init/lib/kvs-archive.sh multi-site/site-manager.sh multi-site/docker-compose.site.yml.template "$work/docker")
multi="$work/docker/multi-site"
manager="$multi/site-manager.sh"
routes="$multi/caddy/sites"
route="$routes/media.example.caddy"
export work KVS_WEBROOT_BASE="$work/www" CADDY_TLS_MODE=internal
mkdir -p "$work/docker/kvs-archive"
touch "$work/docker/kvs-archive/KVS_test.zip"
# shellcheck disable=SC2329  # Used by child managers.
chown() { :; }
# shellcheck disable=SC2329  # Used by child managers.
docker() { [[ $1 == ps || $1 == volume ]]; }
export -f docker chown
fail() { echo "FAIL: $*" >&2; [[ ! -s "$work/out" ]] || cat "$work/out" >&2; exit 1; }

# Start each case from an empty proxy and installation.
reset_case() {
    rm -rf "$routes" "$multi/sites" "$KVS_WEBROOT_BASE"
    mkdir -p "$routes/extra"
}
# Each operator layout below declares www.media.example. Adding
# media.example, or giving its route the www alias, must be refused with
# nothing created and the published route kept byte for byte.
refused() {
    local label="$1"
    cp -R "$routes" "$work/operator"
    if bash "$manager" add media.example > "$work/out" 2>&1; then
        fail "$label: add published a second www.media.example"
    fi
    grep -Fq 'Host www.media.example is already served' "$work/out" || fail "$label: add gave another reason"
    [[ ! -e $route && ! -e $multi/sites/media.example && ! -e $KVS_WEBROOT_BASE/media.example ]] ||
        fail "$label: the refused add left files"
    bash "$manager" proxy-config media.example internal false false > "$work/out" 2>&1 ||
        fail "$label: the route without the alias was refused"
    cp "$route" "$work/before"
    if bash "$manager" proxy-config media.example internal false true > "$work/out" 2>&1; then
        fail "$label: proxy-config published a second www.media.example"
    fi
    grep -Fq 'Host www.media.example is already served' "$work/out" || fail "$label: proxy-config gave another reason"
    cmp -s "$work/before" "$route" || fail "$label: the refused proxy-config changed the route"
    rm "$route"
    diff -r "$work/operator" "$routes" > /dev/null || fail "$label: an operator file changed"
    rm -rf "$work/operator"
}
# These layouts do not declare the name: both commands must publish it.
published() {
    local label="$1"
    bash "$manager" add media.example > "$work/out" 2>&1 || fail "$label: add refused a free name"
    grep -Fxq 'www.media.example {' "$route" || fail "$label: add wrote no www alias"
    bash "$manager" proxy-config media.example internal false true > "$work/out" 2>&1 ||
        fail "$label: proxy-config refused a free name"
}

reset_case
printf 'www.media.example,\n\n  second.example {\n respond ok\n}\n' > "$routes/operator.caddy"
refused 'header continued after a comma'

reset_case
printf 'first.example,\n# a comment\n  WWW.Media.Example:443 {\n respond ok\n}\n' > "$routes/operator.caddy"
refused 'name on the last line of a header'

reset_case
printf 'www.media.example\n{\n respond ok\n}\n' > "$routes/operator.caddy"
refused 'brace on the line after the header'

reset_case
printf '"www.media.example" {\n respond ok\n}\n' > "$routes/operator.caddy"
refused 'double-quoted name'

reset_case
# shellcheck disable=SC2016  # Caddy backquotes, not a command.
printf 'first.example, `https://www.media.example` {\n respond ok\n}\n' > "$routes/operator.caddy"
refused 'backquoted name'

reset_case
printf 'www.media.example {\n respond ok\n}\n' > "$routes/extra/operator.conf"
echo 'import extra/operator.conf' > "$routes/operator.caddy"
refused 'imported file'

reset_case
printf 'www.media.example {\n respond ok\n}\n' > "$routes/extra/operator.conf"
echo 'import /etc/caddy/sites/extra/operator.conf' > "$routes/operator.caddy"
refused 'file imported by its path in the container'

reset_case
printf 'first.example {\n respond ok\n}\n' > "$routes/extra/1 first.conf"
printf 'www.media.example {\n respond ok\n}\n' > "$routes/extra/2 it'\''s.conf"
echo 'import extra/*.conf' > "$routes/operator.caddy"
refused 'files imported by a pattern'

reset_case
mkdir "$routes/extra/deep"
printf 'www.media.example {\n respond ok\n}\n' > "$routes/extra/deep/operator.conf"
echo 'import deep/operator.conf' > "$routes/extra/first.conf"
echo 'import extra/first.conf' > "$routes/operator.caddy"
refused 'file imported by an imported file'

reset_case
printf '(operator) {\n www.media.example {\n  respond ok\n }\n}\nimport operator\n' > "$routes/operator.caddy"
refused 'imported snippet'

reset_case
printf '(site) {\n {args[0]}, www.{args[0]} {\n  respond {args[1]}\n }\n}\nimport site other.example one\nimport site media.example two\n' \
    > "$routes/operator.caddy"
# The second import declares media.example too: write no route for it here.
cp -R "$routes" "$work/operator"
if bash "$manager" add media.example > "$work/out" 2>&1; then fail 'snippet arguments: add published a duplicate'; fi
grep -Fq 'Host media.example is already served' "$work/out" || fail 'snippet arguments: add gave another reason'
[[ ! -e $route && ! -e $multi/sites/media.example ]] || fail 'snippet arguments: the refused add left files'
if bash "$manager" add www.other.example > "$work/out" 2>&1; then fail 'snippet arguments: the first import was not read'; fi
grep -Fq 'Host www.other.example is already served' "$work/out" || fail 'snippet arguments: add gave another reason'
diff -r "$work/operator" "$routes" > /dev/null || fail 'snippet arguments: an operator file changed'
rm -rf "$work/operator"

reset_case
printf '(site) {\n www.{args[0]} {\n  respond ok\n }\n}\n' > "$routes/00-snippets.caddy"
printf 'import site media.example\n' > "$routes/operator.caddy"
refused 'snippet defined in another route file'

reset_case
printf 'www.media.example {\r\n respond ok\r\n}\r\n' > "$routes/operator.caddy"
refused 'route with CRLF line endings'

reset_case
printf 'www.media.example \\\n  second.example {\n respond ok\n}\n' > "$routes/operator.caddy"
refused 'header continued after an escaped line break'

reset_case
printf '(site) {\n www.{args.0} {\n  respond ok\n }\n}\nimport site media.example\n' > "$routes/operator.caddy"
refused 'snippet argument in its dotted form'

# A backslash is an escape between double quotes only: the backquoted
# argument ends at its second backquote and the next header is a header.
reset_case
# shellcheck disable=SC2016  # Caddy backquotes, not a command.
printf 'first.example {\n respond `C:\\`\n}\nwww.media.example {\n respond `x`\n}\n' > "$routes/operator.caddy"
refused 'header after a backquoted backslash'

# Caddy separates tokens at any Unicode space, such as a pasted no-break
# space, a form feed or an ideographic space.
reset_case
printf 'first.example,\302\240www.media.example {\n respond ok\n}\n' > "$routes/operator.caddy"
refused 'name after a no-break space'

reset_case
printf '\fwww.media.example\343\200\200{\n respond ok\n}\n' > "$routes/operator.caddy"
refused 'name between a form feed and an ideographic space'

# Caddy reads the route files in the byte order of their names: Zsnip
# before a.example, whatever the locale of the operator says.
reset_case
printf '(shared) {\n www.media.example {\n  respond ok\n }\n}\n' > "$routes/Zsnip.caddy"
printf 'import shared\n' > "$routes/a.example.caddy"
for locale in en_US.UTF-8 C.UTF-8 C; do
    # A subshell keeps the locale of the caller for the later cases. A host
    # without the locale warns here and reads in byte order anyway.
    (
        { export LC_ALL=$locale; } 2> /dev/null
        refused "snippet file read in byte order under $locale"
    )
done

# A route that never closes its block does not hide the next file.
reset_case
printf 'broken.example {\n respond ok\n' > "$routes/broken.caddy"
printf 'www.media.example {\n respond ok\n}\n' > "$routes/operator.caddy"
refused 'route after an unbalanced file'

reset_case
printf '(operator) {\n www.media.example {\n  respond ok\n }\n}\n' > "$routes/operator.caddy"
published 'snippet nobody imports'

reset_case
cat > "$routes/operator.caddy" <<'CADDY'
(common) {
    encode gzip
}
other.example {
    import common
    import extra/absent.conf
    respond "a {
}
www.media.example {
" 200
    respond /b `www.media.example {`
    respond /c <<TEXT
    }
    www.media.example {
    TEXT
    reverse_proxy www.media.example {
        header_up Host {host}
    }
}
import extra/absent.conf
import extra/none-*.conf
import /etc/caddy/elsewhere.conf
# www.media.example {
&(www.media.example) {
    respond ok
}
CADDY
published 'name in arguments, bodies, comments and absent imports only'
bash "$manager" proxy-config other.example internal false false > "$work/out" 2>&1 &&
    fail 'the site header before the quoted bodies was not read'
grep -Fq 'Host other.example is already served' "$work/out" || fail 'other.example: another reason'

# The route being rewritten is skipped, even when another file imports it.
reset_case
bash "$manager" proxy-config media.example internal false true > "$work/out" 2>&1
printf 'import media.example.caddy\nimport operator.caddy\n' > "$routes/operator.caddy"
bash "$manager" proxy-config media.example internal false true > "$work/out" 2>&1 ||
    fail 'a route clashed with its own file through an import'

# An imported file that is present and cannot be read stops the publication.
reset_case
mkdir "$routes/extra/operator.conf"
echo 'import extra/operator.conf' > "$routes/operator.caddy"
if bash "$manager" add media.example > "$work/out" 2>&1; then fail 'add published without reading an import'; fi
grep -Fq "Could not read Caddy route: $routes/extra/operator.conf" "$work/out" || fail 'unreadable import: another reason'
[[ ! -e $route && ! -e $multi/sites/media.example ]] || fail 'unreadable import: the refused add left files'

# A route removed by another command between the listing of the routes and
# the test of its type is skipped: the independent add goes on.
reset_case
printf 'gone.example {\n respond ok\n}\n' > "$routes/gone.example.caddy"
(
    # shellcheck disable=SC2329  # Used by the child manager.
    function [ {
        if [[ $* == *"-f $routes/gone.example.caddy ]" ]]; then command rm -f "$routes/gone.example.caddy"; fi
        builtin [ "$@"
    }
    export -f [
    export routes
    bash "$manager" add media.example > "$work/out" 2>&1
) || fail 'a route removed during the scan stopped an independent add'
[[ ! -e $routes/gone.example.caddy && -s $route ]] || fail 'removed route: the add did not publish'

# A scan that fails as a whole stops it too.
reset_case
printf 'other.example {\n respond ok\n}\n' > "$routes/operator.caddy"
if (
    # shellcheck disable=SC2329  # Used by the child manager.
    awk() {
        local arg
        for arg in "$@"; do [[ $arg != "$routes/operator.caddy" ]] || return 2; done
        command awk "$@"
    }
    export -f awk
    export routes
    bash "$manager" add media.example > "$work/out" 2>&1
); then fail 'add published after a failed scan'; fi
grep -Fq "Could not read the Caddy routes in $routes" "$work/out" || fail 'failed scan: another reason'
[[ ! -e $route && ! -e $multi/sites/media.example ]] || fail 'failed scan: the refused add left files'

echo "PASS: the served-name check reads quoted and multi-line headers, snippets and imported files"
