#!/bin/bash
# Model first contact locally. Record authentication only after the fake
# SSH client has applied the host-key policy from its actual arguments.
# shellcheck disable=SC2034
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
source "$root/docker/lib/import.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/bin"
export LOG="$tmp/log" KEY_STATE=known
export IMPORT_SSH_CONTROL_DIR="$tmp/ctl"
cat > "$tmp/bin/sshpass" <<'STUB'
#!/bin/sh
[ "$1" = -e ] && [ -n "$SSHPASS" ] || exit 2
shift
exec "$@"
STUB
cat > "$tmp/bin/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LOG.args"
# A permissive user configuration makes a missing explicit policy visible.
policy=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) case "$2" in StrictHostKeyChecking=*) policy=${2#*=} ;; esac; shift 2 ;;
        -p|-i) shift 2 ;;
        *) break ;;
    esac
done
case "$KEY_STATE:$policy" in
    unreported:yes) exit 6 ;;
    unknown:yes)
        echo 'No ED25519 host key is known for this host and you have requested strict checking.' >&2
        echo 'Host key verification failed.' >&2
        exit 255 ;;
    changed:yes|changed:accept-new) echo 'REMOTE HOST IDENTIFICATION HAS CHANGED!' >&2; exit 255 ;;
esac
echo authenticated >> "$LOG"
STUB
chmod +x "$tmp/bin/"*
PATH="$tmp/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
setup="$root/docker/setup.sh"
sed -n '/^KVS_DOMAIN_OVERRIDE=/,/^# Check if .env exists/p' "$setup" > "$tmp/capture"
sed -n '/^# Load environment$/,/^check_mariadb_stop_grace_period /{ /^check_mariadb_stop_grace_period /d; p; }' "$setup" > "$tmp/load"
sed -n '/^    # The questionnaire can select/,/^    trap import_ssh_close/{ /^    trap import_ssh_close/d; p; }' "$setup" > "$tmp/connect"
check_setting() (
    local option=$1 on=$2 explicit=$3 host=$4 port=$5 saved_host=$6 expected=$7
    local saved_value=${8:-$on} interactive_port=${9:-}
    local batch=yes accept_new=no
    cd "$tmp"
    printf 'IMPORT_REMOTE_HOST=%s\nIMPORT_REMOTE_PORT=2222\n%s=%s\n' "$saved_host" "$option" "$saved_value" > .env
    unset "$option"
    if [ "$explicit" != unset ]; then printf -v "$option" '%s' "$explicit"; fi
    IMPORT_REMOTE_HOST=$host IMPORT_REMOTE_PORT=$port
    IMPORT_REMOTE_USER=deploy IMPORT_REMOTE_PASSWORD=fixture IMPORT_SSH_KEY=''
    # shellcheck source=/dev/null
    source "$tmp/capture"
    # shellcheck source=/dev/null
    source "$tmp/load"
    [ -z "$interactive_port" ] || IMPORT_REMOTE_PORT=$interactive_port
    # shellcheck source=/dev/null
    source "$tmp/connect"
    [ "$IMPORT_SSH_TARGET" = "deploy@$host" ] && [ "$IMPORT_SSH_PORT" = "${interactive_port:-$port}" ] || fail 'wrong SSH endpoint'
    [[ " ${IMPORT_SSH_OPTS[*]} " == *" $expected "* ]] || fail "$option for $host:$port ($explicit): ${IMPORT_SSH_OPTS[*]}"
)
check_setting IMPORT_SSH_ACCEPT_NEW y n old.test 2222 old.test StrictHostKeyChecking=yes
check_setting IMPORT_SSH_ACCEPT_NEW y unset old.test 2222 old.test StrictHostKeyChecking=accept-new
check_setting IMPORT_SSH_ACCEPT_NEW y unset other.test 2222 old.test StrictHostKeyChecking=yes
check_setting IMPORT_SSH_ACCEPT_NEW y unset old.test 22 old.test StrictHostKeyChecking=yes
check_setting IMPORT_SSH_ACCEPT_NEW y unset old.test 2222 '' StrictHostKeyChecking=yes
check_setting IMPORT_SSH_ACCEPT_NEW y y other.test 22 old.test StrictHostKeyChecking=accept-new n
check_setting IMPORT_SSH_ACCEPT_NEW y unset old.test 2222 old.test StrictHostKeyChecking=yes y 22

import_ssh_setup old.test 2222 deploy '' yes no fixture
if KEY_STATE=unknown import_remote_privileges 2> "$tmp/error"; then fail 'unknown key accepted'; fi
grep -Fq 'known_hosts for deploy@old.test (port 2222)' "$tmp/error" || fail 'missing host and port'
grep -Fq 'IMPORT_SSH_ACCEPT_NEW=y' "$tmp/error" || fail 'missing first-contact instructions'
if KEY_STATE=unreported import_remote_privileges 2> "$tmp/error"; then fail 'sshpass unknown-key status was ignored'; fi
grep -Fq 'IMPORT_SSH_ACCEPT_NEW=y' "$tmp/error" || fail 'missing instructions after sshpass status 6'
if KEY_STATE=changed import_remote_privileges 2> "$tmp/error"; then fail 'changed key accepted'; fi
if grep -q 'IMPORT_SSH_ACCEPT_NEW' "$tmp/error"; then fail 'a changed key triggered first-contact advice'; fi
for accept in no yes; do
    import_ssh_setup old.test 2222 deploy '' yes "$accept" fixture
    for KEY_STATE in known unknown changed; do
        : > "$LOG"
        if import_ssh true; then
            [ -s "$LOG" ] || fail 'missing authentication'
            case "$KEY_STATE:$accept" in unknown:no|changed:*) fail "authenticated with $KEY_STATE key and accept=$accept" ;; esac
        else
            case "$KEY_STATE:$accept" in known:*|unknown:yes) fail "refused $KEY_STATE key and accept=$accept" ;; esac
            [ ! -s "$LOG" ] || fail 'sent authentication before rejecting the key'
        fi
    done
done
echo 'PASS: password authentication honors the host key policy'
