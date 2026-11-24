#!/bin/bash
# Exercise domain and route locks at the manager's public entry points.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/docker"
(cd "$root/docker" && cp --parents .gitignore images.lock bin/resolve-bases.sh lib/host-validation.sh lib/kvs-php.sh \
    init/lib/kvs-archive.sh multi-site/site-manager.sh multi-site/docker-compose.site.yml.template "$work/docker")
multi="$work/docker/multi-site"
# shellcheck source=tests/fixtures/manager-scripts-lock.sh
source "$root/tests/fixtures/manager-scripts-lock.sh" "$work/docker"
manager="$multi/site-manager.sh"
locks="$multi/.locks"
export ACME_EMAIL=ops@sub.example.com work multi locks KVS_WEBROOT_BASE="$work/www"
mkdir -p "$work/docker/kvs-archive"
python3 "$root/tests/fixtures/kvs-prefix-archive.py" "$work/docker/kvs-archive/KVS_test.zip"
# shellcheck disable=SC2329  # Used by child managers.
chown() { :; }
docker() {
    case "$*" in
        'compose -p multi-site -f docker-compose.caddy.yml up -d')
            if flock -n "$locks/.routes" true; then return 23; fi
            touch "$work/proxy-started" ;;
        'exec kvs-caddy caddy reload '*)
            if flock -n "$locks/.routes" true; then return 23; fi
            touch "$work/reloaded" ;;
        'compose config') command docker "$@" ;;
        'ps '*|'volume '*|'network '*|'exec kvs-caddy wget '*|*' down -v --remove-orphans') return 0 ;;
        *) return 1 ;;
    esac
}
export -f docker chown
if bash "$manager" start absent.example > "$work/out"; then exit 1; fi
[[ -d "$locks/absent.example" && ! -e "$multi/sites/.locks" ]] || { echo "A site lock changed the installation layout"; exit 1; }
git -C "$work" init -q
git -C "$work" check-ignore -q docker/multi-site/.locks/absent.example

for action in primary-config primary-remove; do
    if (exec 5<"$locks/absent.example"; flock -n 5; bash "$manager" "$action" absent.example primary internal false) > "$work/out"; then
        echo "$action ignored the active operation"; exit 1
    fi
    grep -Fq 'Could not lock' "$work/out"
done
[[ ! -e "$multi/sites/.primary.env" && ! -e "$multi/caddy/sites/absent.example.caddy" ]]

# Check the critical section from an independent open file description.
# The initial optimistic add check can run unlocked; its final check cannot.
awk() {
    local arg
    for arg in "$@"; do
        if [[ $arg == "${REMOVE_DURING_READ:-}" ]]; then
            bash "$multi/site-manager.sh" remove old.example <<< $'yes\nn' > "$work/remove-out" || return 1
        fi
        if [[ $arg == "$multi/caddy/sites/seed.example.caddy" ]] &&
            ! flock -n "$locks/.routes" true; then touch "$work/checked"; fi
    done
    command awk "$@"
}
mv() {
    if [[ ${*: -1} == "$multi/caddy/sites/"*.caddy ]]; then
        [[ -f "$work/checked" ]] && ! flock -n "$locks/.routes" true || return 23
        rm "$work/checked"
    fi
    command mv "$@"
}
mkdir -p "$multi/caddy/sites" "$locks/.routes"
printf 'seed.example {\n}\n' > "$multi/caddy/sites/seed.example.caddy"
export -f awk mv
routes="$multi/caddy/sites"
# Braces and header-like text in a response body are literal. Scanning
# resumes at the real header after the closing marker.
cat > "$routes/response.caddy" <<'CADDY'
other.example {
    respond <<TEXT
    }
        www.media.example {
    TEXT
}
    claimed.example {
        respond "ok"
    }
CADDY
bash "$manager" add media.example > "$work/out" || { cat "$work/out"; exit 1; }
bash "$manager" proxy-config media.example internal false false > "$work/out"
bash "$manager" proxy-config media.example internal false true > "$work/out"
grep -Fxq 'www.media.example {' "$routes/media.example.caddy"
if bash "$manager" add claimed.example > "$work/out"; then
    echo "add ignored the real header after a heredoc"; exit 1
fi
grep -Fq 'Host claimed.example is already served' "$work/out"
# The closing marker can carry the response status on its line.
cat > "$routes/status.caddy" <<'CADDY'
status.example {
    respond <<TEXT
    body
    TEXT 200
}
tail.example {
    respond "ok"
}
CADDY
if bash "$manager" add tail.example > "$work/out"; then
    echo "add ignored a header after a heredoc closed with a status"; exit 1
fi
grep -Fq 'Host tail.example is already served' "$work/out"

# Remove a real site after the optimistic scan selected its route and
# before awk opens it. The independent site must publish on its first try.
bash "$manager" add old.example > "$work/out"
if ! REMOVE_DURING_READ="$routes/old.example.caddy" timeout 10 bash "$manager" add new-site.example > "$work/out" 2> "$work/read-errors"; then
    cat "$work/read-errors" "$work/out"; exit 1
fi
[[ ! -s "$work/read-errors" ]] || { cat "$work/read-errors"; exit 1; }
[[ ! -e "$routes/old.example.caddy" && ! -e "$multi/sites/old.example" ]]
[[ -s "$multi/sites/new-site.example/.env" ]]
grep -Fxq 'new-site.example {' "$routes/new-site.example.caddy"
bash "$manager" primary-config primary.example primary internal false > "$work/out"
if bash "$manager" add www.media.example > "$work/out"; then exit 1; fi
grep -Fq 'already served' "$work/out"
[[ ! -e "$multi/sites/www.media.example" && ! -e "$multi/caddy/sites/www.media.example.caddy" ]]
# An operator can indent a site header and put several addresses on it.
# A nested upstream, a comment and a blank line do not claim a site name.
bash "$manager" proxy-config media.example internal false false > "$work/out"
cp "$routes/media.example.caddy" "$work/before"
cat > "$routes/operator.caddy" <<'CADDY'
    # ignored.example {
    www.media.example {
        respond /closed "message #1" {
            close
        }
        reverse_proxy ignored.example {
            header_up Host {host}
        }
    }

    first.example, second.example https://WWW.NEW.EXAMPLE:443 { # other addresses
        respond "ok"
    }
CADDY
cp "$routes/operator.caddy" "$work/operator"
if bash "$manager" proxy-config media.example internal false true > "$work/out"; then
    echo "proxy-config replaced a route with a duplicate operator host"; exit 1
fi
grep -Fq 'Host www.media.example is already served' "$work/out"
cmp "$work/before" "$routes/media.example.caddy"
for domain in new.example first.example second.example; do
    if bash "$manager" add "$domain" > "$work/out"; then
        echo "add accepted a host in the operator route for $domain"; exit 1
    fi
    grep -Fq 'already served' "$work/out"
    [[ ! -e "$routes/$domain.caddy" && ! -e "$multi/sites/$domain" && ! -e "$KVS_WEBROOT_BASE/$domain" ]]
done
cmp "$work/operator" "$routes/operator.caddy"
# A route that is present and cannot be read stops the publication.
rm "$routes/operator.caddy"
mkdir "$routes/operator.caddy"
if bash "$manager" proxy-config media.example public false false > "$work/out" 2>&1; then
    echo "proxy-config published without reading every operator route"; exit 1
fi
grep -Fq "Could not read Caddy route: $routes/operator.caddy" "$work/out"
cmp "$work/before" "$routes/media.example.caddy"
rmdir "$routes/operator.caddy"
cp "$work/operator" "$routes/operator.caddy"
bash "$manager" proxy-config ignored.example internal false false > "$work/out"
ACME_EMAIL=ops@sub.example.com bash "$manager" caddy-start > "$work/out"
[[ -e "$work/proxy-started" && -e "$work/reloaded" ]]
# Deletion also holds the publication lock.
rm() {
    if [[ ${*: -1} == "$multi/caddy/sites/"*.caddy ]]; then
        if flock -n "$locks/.routes" true; then return 23; fi
    fi
    command rm "$@"
}
export -f rm
bash "$manager" primary-remove primary.example primary > "$work/out"
printf 'yes\nn\n' | bash "$manager" remove media.example > "$work/out"
[[ ! -e "$multi/caddy/sites/media.example.caddy" && ! -e "$multi/caddy/sites/primary.example.caddy" ]]
echo "PASS: domain reservations, route publication and Caddy reloads use their locks"
