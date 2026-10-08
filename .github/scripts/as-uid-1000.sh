#!/usr/bin/env bash
#
# Run a command as uid 1000, the way the shell suites run in CI.
#
#   as-uid-1000.sh <command> [<argument>...]
#
# The site's files belong to 1000:1000, the uid and gid PHP-FPM and cron
# run as in the containers, and the scripts the suites exercise give them
# that owner: docker/setup.sh and the scripts of docker/init call chown
# 1000:1000, which only root, or uid 1000 in group 1000, may do. The user of
# a GitHub-hosted runner is uid 1001, so the suites would fail there on the
# first such call.
#
# Run as uid 1000 in group 1000, the script only runs the command. Otherwise,
# as root or through sudo, it takes the user of uid 1000, or creates one,
# and a group of gid 1000. It gives that user subordinate ids, which the
# user namespace of the phpMyAdmin suite maps, and a copy of the current
# directory: the checkout of a runner sits in the home of the runner user,
# which another user may not even enter, and git refuses a repository
# another user owns. The command then runs in that copy as uid 1000, with
# gid 1000 and the group of the Docker socket, in a clean environment:
# PATH, LANG and CI of the caller, HOME, USER and LOGNAME of the user.
# Either way the umask is 022, so the modes of the files the suites create
# do not depend on how the user was switched.

set -euo pipefail

die() {
    printf 'as-uid-1000: %s\n' "$*" >&2
    exit 1
}

[ $# -ge 1 ] || die "usage: as-uid-1000.sh <command> [<argument>...]"

uid=1000

if [ "$(id -u)" -eq "$uid" ] && [[ " $(id -G) " == *" $uid "* ]]; then
    umask 022
    exec "$@"
fi

as_root=()
[ "$(id -u)" -eq 0 ] || as_root=(sudo)

if ! getent group "$uid" >/dev/null; then
    "${as_root[@]}" groupadd --gid "$uid" kvs
fi
if ! entry=$(getent passwd "$uid"); then
    "${as_root[@]}" useradd --uid "$uid" --gid "$uid" --create-home kvs
    entry=$(getent passwd "$uid") || die "no user of uid $uid after useradd"
fi
IFS=: read -r user _ _ _ _ home _ <<<"$entry"
[ -d "$home" ] || "${as_root[@]}" install -d -o "$uid" -g "$uid" -m 0750 "$home"

# After the last range given, so that no two users share one.
for file in /etc/subuid /etc/subgid; do
    if ! grep -q "^${user}:" "$file" 2>/dev/null; then
        start=$(awk -F: 'BEGIN { next_id = 100000 }
            $2 + $3 > next_id { next_id = $2 + $3 }
            END { print next_id }' "$file" 2>/dev/null) || start=100000
        printf '%s:%s:65536\n' "$user" "$start" | "${as_root[@]}" tee -a "$file" >/dev/null
    fi
done

groups=$uid
socket=/var/run/docker.sock
if [ -S "$socket" ]; then
    groups+=,$(stat -c %g "$socket")
fi

copy=$("${as_root[@]}" mktemp -d /tmp/as-uid-1000.XXXXXX)
"${as_root[@]}" cp -R --preserve=mode,timestamps ./. "$copy"
"${as_root[@]}" chown -R "$uid:$uid" "$copy"

printf 'as-uid-1000: running %s as %s (uid %s, groups %s) in %s\n' \
    "$1" "$user" "$uid" "$groups" "$copy" >&2
# shellcheck disable=SC2016  # The inner shell expands its own arguments.
exec "${as_root[@]}" env -i PATH="$PATH" HOME="$home" USER="$user" LOGNAME="$user" \
    ${LANG+"LANG=$LANG"} ${CI+"CI=$CI"} \
    setpriv --reuid="$uid" --regid="$uid" --groups="$groups" -- \
    bash -c 'umask 022 && cd "$1" && shift && exec "$@"' as-uid-1000 "$copy" "$@"
