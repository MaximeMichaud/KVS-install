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
policy=no host_rsa=no user_rsa=no key=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            case "$2" in
                StrictHostKeyChecking=*) policy=${2#*=} ;;
                HostKeyAlgorithms=+ssh-rsa) host_rsa=yes ;;
                PubkeyAcceptedAlgorithms=+ssh-rsa) user_rsa=yes ;;
            esac
            shift 2 ;;
        -i) key=$2; shift 2 ;;
        -p) shift 2 ;;
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
[ "${BANNER:-no}" != yes ] || echo 'Previous client: no matching host key type found. Their offer: ssh-rsa' >&2
[ "${QUOTED_ERROR:-no}" != yes ] || echo 'Unable to negotiate with old.test port 22: no matching host key type found. Their offer: ssh-rsa' >&2
case "${SERVER:-modern}" in
    legacy)
        if [ "$host_rsa" != yes ]; then
            echo 'Unable to negotiate: no matching host key type found. Their offer: ssh-rsa,ssh-dss' >&2
            exit 255
        fi
        if [ -z "${SSHPASS:-}" ] && { [ "$user_rsa" != yes ] || [ "$key" != "$RSA_KEY" ]; }; then
            echo 'Permission denied (publickey).' >&2
            exit 255
        fi
        ;;
    modern) [ "$host_rsa$user_rsa" = nono ] || exit 255 ;;
    denied) echo 'deploy@old.test: Permission denied (publickey).' >&2; exit 255 ;;
    offline) echo 'Connection timed out' >&2; exit 255 ;;
    no-rsa) echo 'Unable to negotiate: no matching host key type found. Their offer: ssh-dss' >&2; exit 255 ;;
esac
echo authenticated >> "$LOG"
case "$*" in *" id -u") echo 0 ;; esac
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
    if [ "$expected" = modern ]; then
        [[ "${IMPORT_SSH_OPTS[*]}" != *ssh-rsa* ]] || fail "unexpected RSA opt-in for $host:$port"
        return
    fi
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

check_setting IMPORT_SSH_LEGACY_ALGORITHMS yes no old.test 2222 old.test modern
check_setting IMPORT_SSH_LEGACY_ALGORITHMS yes unset old.test 2222 old.test HostKeyAlgorithms=+ssh-rsa
check_setting IMPORT_SSH_LEGACY_ALGORITHMS yes unset other.test 2222 old.test modern
check_setting IMPORT_SSH_LEGACY_ALGORITHMS yes unset old.test 22 old.test modern
check_setting IMPORT_SSH_LEGACY_ALGORITHMS yes unset old.test 2222 '' modern
check_setting IMPORT_SSH_LEGACY_ALGORITHMS yes yes other.test 22 old.test HostKeyAlgorithms=+ssh-rsa no
check_setting IMPORT_SSH_LEGACY_ALGORITHMS yes unset old.test 2222 old.test modern yes 22
unset SSHPASS IMPORT_SSH_LEGACY_ALGORITHMS
export SERVER=legacy RSA_KEY="$tmp/rsa key"
touch "$RSA_KEY"
KEY_STATE=known
import_ssh_setup old.test 22 deploy "$RSA_KEY" yes
if import_remote_privileges 2> "$tmp/error"; then fail 'legacy algorithms were enabled by default'; fi
grep -Fq 'no matching host key type' "$tmp/error" || fail 'the original SSH error was lost'
grep -Fq 'IMPORT_SSH_LEGACY_ALGORITHMS=yes' "$tmp/error" || fail 'missing RSA compatibility hint'
for advice in 'weakens the SSH policy' 'Host block' 'only' 'upgrade'; do
    grep -Fq "$advice" "$tmp/error" || fail "missing RSA compatibility advice: $advice"
done
if SERVER=offline import_remote_privileges 2> "$tmp/error"; then fail 'unreachable host connected'; fi
if grep -q 'LEGACY_ALGORITHMS' "$tmp/error"; then fail 'network timeout triggered an RSA hint'; fi
if SERVER=no-rsa import_remote_privileges 2> "$tmp/error"; then fail 'unmatched host key connected'; fi
if grep -q LEGACY_ALGORITHMS "$tmp/error"; then fail 'RSA hint for a server without RSA'; fi
if BANNER=yes SERVER=offline import_remote_privileges 2> "$tmp/error"; then fail 'offline source connected'; fi
if grep -q LEGACY_ALGORITHMS "$tmp/error"; then fail 'quoted banner masked a network failure'; fi
for terminal in denied offline no-rsa; do
    if QUOTED_ERROR=yes SERVER=$terminal import_remote_privileges 2> "$tmp/error"; then fail "$terminal source connected"; fi
    if grep -q LEGACY_ALGORITHMS "$tmp/error"; then fail "quoted RSA diagnostic masked $terminal"; fi
done
grep -Fq 'Their offer: ssh-dss' "$tmp/error" || fail 'the final negotiation diagnostic was lost'
QUOTED_ERROR=yes SERVER=modern import_remote_privileges 2> "$tmp/error" || fail 'modern source with a banner refused'
if grep -q LEGACY_ALGORITHMS "$tmp/error"; then fail 'successful SSH triggered an RSA hint'; fi
SERVER=modern import_remote_privileges || fail 'modern key authentication failed'
IMPORT_SSH_LEGACY_ALGORITHMS=yes import_ssh_setup old.test 22 deploy "$RSA_KEY" yes
import_remote_privileges || fail 'RSA key authentication to the legacy source failed'
[ "$IMPORT_REMOTE_PRIVILEGES" = root ] || fail 'the probe result was lost'
IMPORT_SSH_LEGACY_ALGORITHMS=yes import_ssh_setup old.test 22 deploy '' no no fixture
import_remote_privileges || fail 'password authentication to the legacy source failed'
echo 'PASS: RSA compatibility is opt-in and negotiation failures explain it'
