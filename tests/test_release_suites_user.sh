#!/bin/bash
# The tests workflow, which every release waits for, runs the shell suites
# through .github/scripts/as-uid-1000.sh: the scripts they exercise give
# files to 1000:1000, which the runner user, uid 1001, may not. The script
# runs here as root in the Debian image docker/images.lock pins, as on a
# runner that has no user of uid 1000 and on one that has, from a checkout
# that only its uid 1001 owner may enter. The command must get uid 1000,
# gid 1000 and the group of the Docker socket, subordinate ids, a copy of
# the checkout it owns, umask 022 and a clean environment, and its exit
# status must come back. Run as uid 1000 in group 1000 already, the script
# runs the command where it stands.
#
# Without Docker or the image the suite says SKIP, except under CI, where
# that is a failure.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/.github/scripts/as-uid-1000.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$SCRIPT" ] || fail "${SCRIPT#"$ROOT_DIR"/} is missing"

IMAGE=$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get debian -)
if ! docker image inspect "$IMAGE" >/dev/null 2>&1 && ! docker pull -q "$IMAGE" >/dev/null 2>&1; then
    [ "${CI:-}" != true ] || fail "the Debian image $IMAGE is neither on this machine nor pullable"
    echo "SKIP: as-uid-1000.sh was not run, $IMAGE is neither on this machine nor pullable"
    exit 0
fi

docker run --rm -i --pull never --network none \
    --mount type=bind,source="$SCRIPT",target=/as-uid-1000.sh,readonly "$IMAGE" bash -s <<'SCENARIOS' ||
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

# What the command sees, as words between spaces.
cat >/probe <<'PROBE'
#!/bin/bash
words=(
    "uid=$(id -u)" "gid=$(id -g)" "groups=$(id -G | tr ' ' ,)" "user=$(id -un)" "group=$(id -gn)"
    "pwd=$PWD" "dir=$(stat -c %u:%g:%a .)" "run=$(stat -c %u:%g:%a tests/run.sh)"
    "head=$(tr ' ' _ <.git/HEAD)" "umask=$(umask)" "home=${HOME-}" "login=${USER-}:${LOGNAME-}"
    "ci=${CI-unset}" "lang=${LANG-unset}" "actions=${GITHUB_ACTIONS-unset}" "path=$PATH"
)
echo " ${words[*]} "
PROBE
chmod 0755 /probe

# expect <output> <word>...: every word is a word of the output.
expect() {
    local output=$1 word
    shift
    for word in "$@"; do
        [[ "$output" == *" $word "* ]] || fail "'$word' is not in:$output"
    done
}

# A Docker socket of its own group, a runner user of uid 1001 and a checkout
# in its home, which no one else may enter.
groupadd --gid 4242 docker
perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => "/var/run/docker.sock", Listen => 1) or die "$!\n"'
chgrp docker /var/run/docker.sock
useradd --uid 1001 --create-home runner
runner_home=$(getent passwd runner | cut -d: -f6)
checkout=$runner_home/work/kvs-install
mkdir -p "$checkout/.git" "$checkout/tests"
echo 'ref: refs/heads/main' >"$checkout/.git/HEAD"
printf '#!/bin/sh\nexit 0\n' >"$checkout/tests/run.sh"
chmod 0750 "$checkout/tests/run.sh" "$runner_home"
chown -R runner:runner "$runner_home"
cd "$checkout"
umask 0077
path=$PATH

# No user of uid 1000: the script makes one, with the subordinate ids
# useradd gives it.
out=$(GITHUB_ACTIONS=true CI=true LANG=C.UTF-8 /as-uid-1000.sh /probe 2>/dev/null) ||
    fail "the command failed for a new user of uid 1000"
expect "$out" uid=1000 gid=1000 groups=1000,4242 user=kvs group=kvs dir=1000:1000:755 \
    run=1000:1000:750 head=ref:_refs/heads/main umask=0022 "home=$(getent passwd kvs | cut -d: -f6)" \
    login=kvs:kvs ci=true lang=C.UTF-8 actions=unset "path=$path"
[[ "$out" == *" pwd=/tmp/as-uid-1000."* ]] || fail "the command must run in a copy of the checkout:$out"
grep -q '^kvs:' /etc/subuid && grep -q '^kvs:' /etc/subgid ||
    fail "the new user has no subordinate ids"
echo "PASS: a new user of uid 1000 runs the command in a copy of the checkout it owns"

status=0
/as-uid-1000.sh sh -c 'exit 7' 2>/dev/null || status=$?
[ "$status" -eq 7 ] || fail "the exit status 7 of the command came back as $status"
echo "PASS: the exit status of the command comes back"

# The user of uid 1000 the runner has, without a home, without subordinate
# ids, and in a group of another gid: the script keeps that user, creates
# group 1000 and gives it the range after the last one given.
rm -rf "$(getent passwd kvs | cut -d: -f6)"
userdel kvs
if getent group kvs >/dev/null; then groupdel kvs; fi
groupadd --gid 1500 admin
useradd --uid 1000 --gid 1500 --home-dir /srv/admin admin
for file in /etc/subuid /etc/subgid; do
    echo 'runner:100000:65536' >"$file"
done
out=$(/as-uid-1000.sh /probe 2>/dev/null) || fail "the command failed for the runner's user of uid 1000"
expect "$out" uid=1000 gid=1000 groups=1000,4242 user=admin group=kvs home=/srv/admin \
    login=admin:admin ci=unset
[ "$(stat -c %u:%g /srv/admin)" = 1000:1000 ] || fail "the home of the user was not made"
for file in /etc/subuid /etc/subgid; do
    grep -qx 'admin:165536:65536' "$file" ||
        fail "admin was not given the range after runner's in $file: $(cat "$file")"
done
echo "PASS: the runner's user of uid 1000 gets group 1000, a home and subordinate ids of its own"

# As uid 1000 in group 1000 already, the command runs where it stands, with
# the environment it was given and umask 022.
install -d -o 1000 -g 1000 /srv/own
cp -R "$checkout/." /srv/own
chown -R 1000:1000 /srv/own
out=$(cd /srv/own && GITHUB_ACTIONS=true setpriv --reuid=1000 --regid=1000 --clear-groups \
    /as-uid-1000.sh /probe 2>/dev/null) || fail "the command failed for uid 1000"
expect "$out" uid=1000 pwd=/srv/own umask=0022 actions=true

# Not in group 1000, uid 1000 is not enough: the script needs root to switch,
# and fails here without sudo instead of running the command as it is.
if (cd /srv/own && setpriv --reuid=1000 --regid=1500 --clear-groups \
    /as-uid-1000.sh touch /tmp/ran) 2>/dev/null; then
    fail "uid 1000 outside group 1000 ran the command as it is"
fi
[ ! -e /tmp/ran ] || fail "uid 1000 outside group 1000 ran the command"
echo "PASS: uid 1000 in group 1000 runs the command as it is, and only that user"
SCENARIOS
    fail "as-uid-1000.sh did not give the suites the user they need"
