#!/bin/sh
# The health of the KVS cron container, run by its Docker health check and
# by kvsctl doctor. Healthy while the cron daemon runs and KVS's cron.php,
# which kvs-cron-run (cron-run.sh) runs every minute, last completed a run
# at most KVS_CRON_MAX_AGE seconds ago, 300 by default. A container that
# has not completed one since it started has that long to do it; a record
# older than the container, which a restart keeps, does not count.
#
# KVS refuses to run with "ERROR Duplicate cron operation" for up to 15
# minutes after a recreation without kvs-init when its cron registration
# names another host. The compose files give the container a fixed
# hostname, so its registration stays valid; for a container created
# without it, a Duplicate as the last failure counts as waiting, not
# failing, while the container is younger than KVS_CRON_DUPLICATE_GRACE
# seconds, 960 by default.
#
# Prints a line that says why and, when unhealthy, a second line with the
# last failure kvs-cron-run recorded since the container started. Exits 0
# when healthy, 1 when not.
state=/var/lib/kvs-cron
max_age=${KVS_CRON_MAX_AGE:-300}
case $max_age in
    '' | *[!0-9]*) max_age=300 ;;
esac
grace=${KVS_CRON_DUPLICATE_GRACE:-960}
case $grace in
    '' | *[!0-9]*) grace=960 ;;
esac

if ! pgrep -x cron >/dev/null; then
    echo "the cron daemon is not running"
    exit 1
fi
now=$(date +%s) || exit 1
# PID 1 started with the container: Docker's init, or cron itself.
uptime=$(ps -o etimes= -p 1 | tr -d ' ')
case $uptime in
    '' | *[!0-9]*)
        echo "cannot read how long the container has been running"
        exit 1
        ;;
esac
started=$((now - uptime))

# recorded <file>: when the file was last written, if since the container
# started.
recorded() {
    recorded_time=$(stat -c %Y "$1" 2>/dev/null) || return 0
    [ "$recorded_time" -lt "$started" ] || echo "$recorded_time"
}
last=$(recorded "$state/last-success")
failed=$(recorded "$state/last-failure")
failure=
if [ -n "$failed" ] && { [ -z "$last" ] || [ "$failed" -ge "$last" ]; }; then
    failure=$(head -n 1 "$state/last-failure")
fi

if [ -n "$last" ]; then
    age=$((now - last))
    if [ "$age" -le "$max_age" ]; then
        echo "cron.php last completed a run ${age} s ago"
        exit 0
    fi
    verdict="cron.php last completed a run ${age} s ago, more than ${max_age} s"
elif [ "$uptime" -le "$max_age" ]; then
    echo "cron.php has not completed a run yet, the container started ${uptime} s ago"
    exit 0
else
    verdict="cron.php has not completed a run since the container started ${uptime} s ago"
fi

if [ -z "$failure" ]; then
    echo "${verdict}: see /var/log/cron.log"
    exit 1
fi
case $failure in
    *'Duplicate cron operation'*)
        if [ "$uptime" -le "$grace" ]; then
            echo "cron.php waits for KVS to release the cron registration of the previous container (Duplicate cron operation), the container started ${uptime} s ago"
            exit 0
        fi
        ;;
esac
echo "$verdict"
echo "last failure $((now - failed)) s ago, exit status ${failure%% *}: ${failure#* }"
exit 1
