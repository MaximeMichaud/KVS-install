#!/bin/sh
# Runs KVS's cron.php once, for the KVS task of the crontab
# (/etc/cron.d/kvs-cron), and records how the run ended for the health
# check (kvs-cron-health, cron-health.sh).
#
# cron.php exits 0 on most of its failures: with MariaDB down or its
# password refused it prints "[FATAL]: can't connect to database", and
# while another host holds its cron registration "ERROR Duplicate cron
# operation", and does nothing either way. A run therefore fails when it
# exits non-zero or prints one of those lines or a PHP fatal error; any
# other run completes, "Already started" and "Already locked" (another run
# is in progress) included.
#
# The output of the run goes to /var/log/cron.log when it ends, with a
# final newline (KVS's [FATAL] line has none). A completed run touches
# last-success; a failed one replaces last-failure with its exit status and
# the line that says why.
state=/var/lib/kvs-cron
log=/var/log/cron.log
failure_pattern='\[FATAL\]|ERROR +Duplicate cron operation|(PHP )?Fatal error:'

# A run killed on the way, by docker stop for instance, leaves its
# temporary files behind: nothing reads them, and a later run removes them
# after a day.
find "$state" -maxdepth 1 -name '.run.*' -mmin +1440 -delete 2>/dev/null

if ! output=$(mktemp "$state/.run.XXXXXX"); then
    # Nothing can be recorded: KVS runs as before, and the health check
    # finds no recent run.
    echo "kvs-cron-run: cannot write to $state" >> "$log"
    cd /var/www/kvs/admin/include && exec /usr/local/bin/php cron.php >> "$log" 2>&1
    exit 1
fi
trap 'rm -f "$output" "$output.failure"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

status=0
if cd /var/www/kvs/admin/include 2>/dev/null; then
    /usr/local/bin/php cron.php > "$output" 2>&1 || status=$?
else
    echo "kvs-cron-run: cannot enter /var/www/kvs/admin/include" > "$output"
    status=1
fi

cat "$output" >> "$log"
if [ -n "$(tail -c 1 "$output")" ]; then
    echo >> "$log"
fi

reason=$(grep -E -m 1 "$failure_pattern" "$output")
if [ "$status" -eq 0 ] && [ -z "$reason" ]; then
    touch "$state/last-success"
    exit
fi
# A non-zero exit without one of those lines: its last line says why.
[ -n "$reason" ] || reason=$(grep -v '^[[:space:]]*$' "$output" | tail -n 1)
reason=$(printf '%s' "${reason:-no output}" | tr -d '\r' | cut -c 1-500)
printf '%s %s\n' "$status" "$reason" > "$output.failure" &&
    mv -f "$output.failure" "$state/last-failure"
[ "$status" -ne 0 ] || status=1
exit "$status"
