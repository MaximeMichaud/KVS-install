#!/bin/bash
# Exercise the container commands against an isolated certificate directory.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export DOMAIN=fixture.test NGINX_CONTAINER=fixture
live=$work/ssl/$DOMAIN
mkdir -p "$live" "$work/bin" "$work/cache"
export PATH="$work/bin:$PATH" live
include_www_for_domain() { return 0; }
docker() (
    if [ "$1" = compose ]; then
        [ "${*:1:7}" = 'compose run --rm --no-deps -T --entrypoint sh' ] || exit 1
        shift 7
    else
        [ "$1" = exec ]; shift
    fi
    while [ "$1" = -e ]; do export "${2?}"; shift 2; done
    if [ "$1" = nginx ]; then
        [ "$2" = -c ]; shift 2
    else
        [ "$1 $2 $3" = 'fixture sh -c' ]; shift 3
    fi
    local script=$1
    shift
    sh -c "${script//\/etc\/nginx\/ssl/$work\/ssl}" "$@"
)
eval "$(sed -n '/^nginx_certificate_check_script() {/,/^}/p; /^nginx_certificate_matches_provider() {/,/^}/p; /^prepare_self_signed_certificate() {/,/^}/p' "$root/docker/reconfigure.sh")"
openssl req -x509 -nodes -days 2 -newkey rsa:2048 -subj "/CN=$DOMAIN" \
    -addext "subjectAltName=DNS:$DOMAIN,DNS:www.$DOMAIN" -addext 'basicConstraints=critical,CA:TRUE' \
    -keyout "$work/cache/key.pem" -out "$work/cache/cert.pem" >/dev/null 2>&1
ln "$work/cache/key.pem" "$live/key.pem"
ln -s "$work/cache/cert.pem" "$live/cert.pem"
! nginx_certificate_matches_provider selfsigned || { echo 'FAIL: accepted signing certificate'; exit 1; }
cat > "$work/bin/mv" <<'STUB'
#!/bin/sh
if [ "${FAIL_RENAME:-}" = yes ] && [ "$3" = "$live/cert.pem" ]; then exit 1; fi
exec /bin/mv "$@"
STUB
cat > "$work/bin/openssl" <<'STUB'
#!/bin/sh
if [ "$1" = req ]; then
    case "${GENERATION:-}" in
        fail) exit 1 ;;
        mismatch) /usr/bin/openssl "$@" || exit; shift; while [ "$1" != -keyout ]; do shift; done
            /usr/bin/openssl genrsa -out "$2" 2048; exit ;;
    esac
fi
exec /usr/bin/openssl "$@"
STUB
chmod +x "$work/bin/"*
for fault in fail mismatch rename; do
    if GENERATION=$fault FAIL_RENAME=$([ "$fault" != rename ] || echo yes) prepare_self_signed_certificate; then
        echo "FAIL: accepted $fault"; exit 1
    fi
    for file in key.pem cert.pem; do cmp "$work/cache/$file" "$live/$file"; done
done
for _ in 1 2; do
    cp --remove-destination "$work/cache/cert.pem" "$live/cert.pem"
    cp --remove-destination "$work/cache/key.pem" "$live/key.pem"
    before=$(mktemp -d "$work/before.XXXXXX")
    cp "$live/"*.pem "$before/"
    prepare_self_signed_certificate > "$work/output"
    backup=$(sed -n 's/^Previous TLS files saved in //p' "$work/output")
    [ "$(stat -c %a "$backup")" = 700 ]
    [ "$(stat -c %a "$backup/key.pem")" = 600 ]
    for file in key.pem cert.pem; do cmp "$before/$file" "$backup/$file"; done
    nginx_certificate_matches_provider selfsigned
done
dirs=("$live"/replaced.*)
[ "${#dirs[@]}" = 3 ] # One failed publication and two successful ones.
prepare_self_signed_certificate > "$work/output"
[ ! -s "$work/output" ] # The correct leaf stays in place.
chmod g+w "$live"
if prepare_self_signed_certificate; then echo 'FAIL: writable certificate directory'; exit 1; fi
chmod g-w "$live"
mv "$live" "$work/elsewhere"
ln -s "$work/elsewhere" "$live"
if prepare_self_signed_certificate 2> "$work/error"; then echo 'FAIL: followed linked parent'; exit 1; fi
grep -Fq "linked TLS directory: $live" "$work/error"
rm "$live"
mkdir "$live"
ln -s missing "$live/key.pem"
ln -s gone "$live/cert.pem"
prepare_self_signed_certificate > "$work/output" 2> "$work/error"
grep -Fq "dangling TLS link: $live/cert.pem" "$work/error"
backup=$(sed -n 's/^Previous TLS files saved in //p' "$work/output")
[ "$(readlink "$backup/cert.pem")" = gone ]
[ "$(readlink "$backup/key.pem")" = missing ]
nginx_certificate_matches_provider selfsigned
echo 'PASS: staged certificates, preserved backups and rename rollback'
