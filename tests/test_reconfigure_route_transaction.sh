#!/bin/bash
# reconfigure.sh backs up, replaces and, on a failure, restores the primary
# route and reservation as one transaction under the site manager's locks.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
# shellcheck disable=SC2329  # Run on exit.
cleanup() {
    if [[ -e $work/child ]]; then kill "$(cat "$work/child")" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
export TMPDIR=$work
mkdir "$work/docker"
(cd "$root/docker" && cp --parents reconfigure.sh multi-site/site-manager.sh "$work/docker")

cat > "$work/driver.sh" <<'DRIVER'
#!/bin/bash
set -euo pipefail
cd "$work/docker"
manager=$PWD/multi-site/site-manager.sh
route=multi-site/caddy/sites/media.example.caddy
reservation=multi-site/sites/.primary.env
locks=multi-site/.locks
export manager locks
RED='' GREEN='' YELLOW='' CYAN='' NC=''
DOMAIN=media.example SITE_PREFIX=primary SSL_PROVIDER=letsencrypt USE_WWW=true
CADDY_ROLLBACK_ARMED=false CADDY_ROLLBACK_DIR='' MULTI_TRANSACTION_COMMITTED=false
for f in lock_caddy_route_state unlock_caddy_route_state restore_caddy_route_state \
    restore_locked_caddy_route_state configure_multi_route; do
    eval "$(sed -n "/^$f() {/,/^}/p" reconfigure.sh)"
done
# What a second operator would run while Caddy checks the new route: a route
# change for the same domain, and a look at the route lock.
# shellcheck disable=SC2329  # Called by the functions under test.
docker() {
    case "$*" in
        'ps --format {{.Names}}')
            hang_at ps
            # Caddy's state is read under the route lock, which a caddy-start
            # replacing the container holds.
            if flock -n "$locks/.routes" true; then touch "$work/ps-unlocked"; fi
            case ${CADDY:-up} in
                up) echo kvs-caddy ;;
                unknown) return 1 ;;
            esac ;;
        'exec kvs-caddy caddy validate '*)
            if [[ -e $work/validated ]]; then
                touch "$work/revalidated"
                hang_at restore-validate
                # The rollback's own validation: the locks are still held.
                if bash "$manager" proxy-config media.example internal false false > "$work/edit-rollback" 2>&1; then
                    touch "$work/edited"
                fi
                return 0
            fi
            touch "$work/validated"
            hang_at validate
            if bash "$manager" proxy-config media.example internal false false > "$work/edit" 2>&1; then
                touch "$work/edited"
            fi
            if flock -n "$locks/.routes" true; then touch "$work/routes-unlocked"; fi
            [[ ${VALIDATE:-ok} == ok ]] ;;
        'exec kvs-caddy caddy reload '*)
            if [[ -e $work/revalidated ]]; then hang_at restore-reload; else hang_at reload; fi ;;
        *) return 91 ;;
    esac
}
# A docker call that outlives a killed run: it has the descriptors its call
# was given, and stays behind for the suite to end.
hang_at() {
    [[ ${HANG_AT:-} == "$1" ]] || return 0
    sleep 60 > /dev/null 2>&1 &
    echo "$!" > "$work/child"
    touch "$work/hung"
    wait "$!"
}
# Another child of the run keeps the lock descriptors it inherited past the
# end of the transaction: the explicit unlock must free the locks anyway.
grep() {
    if [[ ${HANG_AT:-} == '' && ! -e $work/child && -e /dev/fd/8 && -e /dev/fd/9 ]]; then
        sleep 60 > /dev/null 2>&1 &
        echo "$!" > "$work/child"
    fi
    command grep "$@"
}
export -f docker
locks_free() { flock -n "$locks/media.example" true && flock -n "$locks/.routes" true; }

case "$1" in
    rejected)
        bash "$manager" primary-config media.example primary internal false > /dev/null
        cp "$route" "$work/original"
        cp "$reservation" "$work/original-reservation"
        if VALIDATE=refuse configure_multi_route > "$work/out" 2>&1; then echo "A refused route was committed"; exit 1; fi
        grep -Fq 'Caddy rejected the updated primary route' "$work/out"
        [[ ! -e $work/edited ]] || { echo "Another command replaced the route inside the transaction"; exit 1; }
        grep -Fq 'Could not lock' "$work/edit"
        [[ ! -e $work/routes-unlocked ]] || { echo "The route lock was free inside the transaction"; exit 1; }
        grep -Fxq 'www.media.example {' "$route"
        restore_caddy_route_state > "$work/out" 2>&1
        [[ ! -e $work/edited ]] || { echo "Another command replaced the route during the rollback"; exit 1; }
        grep -Fq 'Could not lock' "$work/edit-rollback"
        cmp "$route" "$work/original"
        cmp "$reservation" "$work/original-reservation"
        [[ $CADDY_ROLLBACK_ARMED == false ]]
        locks_free || { echo "The rollback kept the locks"; exit 1; } ;;
    fresh)
        if VALIDATE=refuse configure_multi_route > "$work/out" 2>&1; then exit 1; fi
        [[ -s $route && -s $reservation ]]
        restore_caddy_route_state > "$work/out" 2>&1
        [[ ! -e $route && ! -e $reservation ]] || { echo "The rollback kept a route it created"; exit 1; }
        locks_free ;;
    busy)
        # Another command holds the domain: nothing is backed up, replaced
        # or, later, restored over what that command writes.
        bash "$manager" primary-config media.example primary internal false > /dev/null
        mkfifo "$work/hold"
        (
            exec 4<"$locks/media.example" 6<>"$work/hold"
            flock -n 4
            touch "$work/ready"
            read -r -t 30 -u 6
        ) &
        holder=$!
        for ((i = 0; i < 200; i++)); do
            [[ ! -e $work/ready ]] || break
            sleep .05
        done
        [[ -e $work/ready ]]
        # The variable alone, without the caller's locks, shares nothing.
        if KVS_SITE_LOCKS_INHERITED=1 bash "$manager" proxy-config media.example internal false false > "$work/edit" 2>&1; then
            echo "KVS_SITE_LOCKS_INHERITED bypassed the domain lock"; exit 1
        fi
        grep -Fq 'Could not lock' "$work/edit"
        # Nor does a descriptor 9 that is open on something else.
        if KVS_SITE_LOCKS_INHERITED=1 bash "$manager" proxy-config media.example internal false false \
            > "$work/edit" 2>&1 8<"$work" 9<"$work"; then
            echo "A foreign descriptor 9 stood in for the domain lock"; exit 1
        fi
        grep -Fq 'Could not lock' "$work/edit"
        status=0
        configure_multi_route > "$work/out" 2>&1 || status=$?
        printf 'other command\n' > "$route"
        restore_caddy_route_state >> "$work/out" 2>&1 || status=90
        echo done > "$work/hold"
        wait "$holder"
        [[ $status == 1 ]] || { cat "$work/out"; echo "The transaction started on a locked domain"; exit 1; }
        grep -Fq 'Another site-manager.sh command is working on media.example' "$work/out"
        [[ $(grep -c ERROR "$work/out") == 1 ]] || { cat "$work/out"; echo "A busy domain was reported twice"; exit 1; }
        [[ ! -e $work/ps-unlocked ]]
        [[ ! -e $work/validated && $CADDY_ROLLBACK_ARMED == false ]]
        [[ $(cat "$route") == 'other command' ]] || { echo "The rollback overwrote the other command's route"; exit 1; }
        # The refusal released the route lock it never needed.
        flock -n "$locks/.routes" true ;;
    no-backup-*)
        # A transaction that cannot take its backup changes nothing and
        # keeps no lock for the rest of the run.
        bash "$manager" primary-config media.example primary internal false > /dev/null
        before=$(sha256sum "$route" "$reservation")
        mktemp() { [[ $FAIL_AT != mktemp ]] && command mktemp "$@"; }
        cp() { [[ ${*: -1} != */"$FAIL_AT" ]] && command cp "$@"; }
        FAIL_AT=${1#no-backup-}
        if configure_multi_route > "$work/out" 2>&1; then echo "Continued without a backup"; exit 1; fi
        [[ $CADDY_ROLLBACK_ARMED == false && -z $CADDY_ROLLBACK_DIR && ! -e $work/validated ]]
        [[ $before == "$(sha256sum "$route" "$reservation")" ]]
        locks_free || { echo "A failed backup kept the locks"; exit 1; } ;;
    foreign-routes)
        # A descriptor 8 open on something else is not the route lock: the
        # command waits for the real one.
        mkdir -p "$locks/.routes"
        mkfifo "$work/hold"
        (
            exec 4<"$locks/.routes" 6<>"$work/hold"
            flock -n 4
            touch "$work/ready"
            read -r -t 30 -u 6
        ) &
        holder=$!
        for ((i = 0; i < 200; i++)); do
            [[ ! -e $work/ready ]] || break
            sleep .05
        done
        [[ -e $work/ready ]]
        status=0
        KVS_SITE_LOCKS_INHERITED=1 timeout 3 bash "$manager" proxy-config media.example internal false false \
            > "$work/edit" 2>&1 8<"$work" 9<"$work" || status=$?
        echo done > "$work/hold"
        wait "$holder"
        [[ $status == 124 && ! -e $route ]] || { echo "A foreign descriptor 8 stood in for the route lock (status $status)"; exit 1; } ;;
    caddy-stopped|caddy-unknown)
        # Without a running Caddy nothing is backed up or replaced, and the
        # locks taken to look are released.
        bash "$manager" primary-config media.example primary internal false > /dev/null
        before=$(sha256sum "$route" "$reservation")
        if CADDY=${1#caddy-} configure_multi_route > "$work/out" 2>&1; then echo "Continued without Caddy"; exit 1; fi
        [[ ! -e $work/ps-unlocked ]] || { echo "Caddy's state was read without the route lock"; exit 1; }
        [[ $CADDY_ROLLBACK_ARMED == false && -z $CADDY_ROLLBACK_DIR && ! -e $work/validated ]]
        [[ $before == "$(sha256sum "$route" "$reservation")" ]]
        locks_free || { echo "A stopped Caddy kept the locks"; exit 1; } ;;
    killed-*)
        # The suite kills this run inside the named docker call.
        bash "$manager" primary-config media.example primary internal false > /dev/null
        HANG_AT=${1#killed-}
        case $HANG_AT in
            restore-*)
                if VALIDATE=refuse configure_multi_route > "$work/out" 2>&1; then exit 1; fi
                restore_caddy_route_state >> "$work/out" 2>&1 ;;
            *) configure_multi_route > "$work/out" 2>&1 ;;
        esac ;;
    waits)
        # Another route operation holds the route lock for a moment: the
        # transaction says that it waits, then runs.
        bash "$manager" primary-config media.example primary internal false > /dev/null
        (
            exec 4<"$locks/.routes"
            flock -n 4
            touch "$work/ready"
            sleep 1
        ) &
        holder=$!
        for ((i = 0; i < 200; i++)); do
            [[ ! -e $work/ready ]] || break
            sleep .05
        done
        [[ -e $work/ready ]]
        configure_multi_route > "$work/out" 2>&1 || { cat "$work/out"; exit 1; }
        wait "$holder"
        [[ $(grep -c 'Waiting for another route operation to finish' "$work/out") == 1 ]] ||
            { cat "$work/out"; echo "The wait for the route lock was silent"; exit 1; }
        [[ $MULTI_TRANSACTION_COMMITTED == true ]]
        locks_free ;;
    committed)
        bash "$manager" primary-config media.example primary internal false > /dev/null
        configure_multi_route > "$work/out" 2>&1 || { cat "$work/out"; echo "The transaction could not share its locks with primary-config"; exit 1; }
        [[ $MULTI_TRANSACTION_COMMITTED == true && $CADDY_ROLLBACK_ARMED == false && -z $CADDY_ROLLBACK_DIR ]]
        grep -Fxq 'www.media.example {' "$route"
        if grep -Fq 'tls internal' "$route"; then exit 1; fi
        [[ ! -e $work/edited && ! -e $work/routes-unlocked ]]
        locks_free || { echo "The commit kept the locks"; exit 1; }
        [[ -e $work/child ]] || { echo "No child held the lock descriptors"; exit 1; }
        if grep -q 'Waiting for another route operation' "$work/out"; then echo "Announced a wait that did not happen"; exit 1; fi
        bash "$manager" proxy-config media.example internal false false > /dev/null ;;
esac
DRIVER
export work
for scenario in rejected fresh busy foreign-routes caddy-stopped caddy-unknown \
    no-backup-mktemp no-backup-route no-backup-reservation waits committed \
    killed-ps killed-validate killed-reload killed-restore-validate killed-restore-reload; do
    if [[ -e $work/child ]]; then kill "$(cat "$work/child")" 2>/dev/null || true; fi
    rm -rf "$work/child" "$work/ps-unlocked" "$work/edit-rollback" \
        "$work/docker/multi-site/caddy" "$work/docker/multi-site/sites" "$work/docker/multi-site/.locks" \
        "$work/validated" "$work/revalidated" "$work/hung" "$work/edited" "$work/routes-unlocked" \
        "$work/ready" "$work/hold"
    if [[ $scenario == killed-* ]]; then
        # SIGKILL leaves the run no chance to unlock: a docker call still
        # running must not have been given the lock descriptors.
        bash "$work/driver.sh" "$scenario" &
        run=$!
        for ((i = 0; i < 600; i++)); do
            [[ ! -e $work/hung ]] || break
            sleep .05
        done
        [[ -e $work/hung ]] || { kill "$run" 2>/dev/null || true; echo "FAIL: $scenario never reached its docker call"; exit 1; }
        kill -KILL "$run"
        wait "$run" 2>/dev/null || true
        kill -0 "$(cat "$work/child")" || { echo "FAIL: $scenario: the docker call did not outlive the run"; exit 1; }
        locks="$work/docker/multi-site/.locks"
        if ! flock -n "$locks/media.example" true || ! flock -n "$locks/.routes" true; then
            echo "FAIL: $scenario: a docker call that outlived the killed run kept the locks"; exit 1
        fi
        continue
    fi
    timeout 60 bash "$work/driver.sh" "$scenario" || { echo "FAIL: $scenario (status $?)"; exit 1; }
done
echo "PASS: the primary route transaction of reconfigure.sh holds the site locks from backup to commit or rollback"
