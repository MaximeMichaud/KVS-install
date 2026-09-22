#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v shellcheck >/dev/null 2>&1 || fail "ShellCheck is required"

KVS_CRON="$ROOT_DIR/docker/cron/crontab"
UPDATER_CRON="$ROOT_DIR/docker/cron/yt-dlp-update.cron"
MANTICORE_CRON="$ROOT_DIR/docker/manticore/manticore-indexer.cron"
CRON_DOCKERFILE="$ROOT_DIR/docker/cron/Dockerfile"
MANTICORE_DOCKERFILE="$ROOT_DIR/docker/manticore/Dockerfile"

validate_system_crontab() {
    local file="$1"
    local expected_jobs="$2"

    awk -v expected_jobs="$expected_jobs" '
        function valid_schedule_field(value) {
            return value ~ /^(\*|[0-9]+)([-,\/]([0-9]+|\*))*$/
        }

        /^[[:space:]]*($|#)/ { next }
        /^[A-Za-z_][A-Za-z0-9_]*=/ { next }

        {
            jobs++
            if (NF < 7) {
                printf "missing user or command at line %d\n", NR > "/dev/stderr"
                exit 1
            }
            for (field = 1; field <= 5; field++) {
                if (!valid_schedule_field($field)) {
                    printf "invalid schedule field at line %d\n", NR > "/dev/stderr"
                    exit 1
                }
            }
            if ($6 !~ /^[a-z_][a-z0-9_-]*$/) {
                printf "invalid system-crontab user at line %d\n", NR > "/dev/stderr"
                exit 1
            }
        }

        END {
            if (jobs != expected_jobs) {
                printf "expected %d job(s), found %d\n", expected_jobs, jobs > "/dev/stderr"
                exit 1
            }
        }
    ' "$file" || fail "invalid system crontab: $file"
}

check_command_syntax() {
    local file="$1"
    local counter=0
    local command_file

    while IFS= read -r command; do
        counter=$((counter + 1))
        command_file="$TEST_DIR/command-${counter}.sh"
        printf '#!/bin/sh\n%s\n' "$command" > "$command_file"
        sh -n "$command_file" || fail "invalid shell command in $file"
        shellcheck --shell=sh --severity=warning "$command_file" ||
            fail "ShellCheck rejected a command in $file"
    done < <(
        awk '
            /^[[:space:]]*($|#)/ { next }
            /^[A-Za-z_][A-Za-z0-9_]*=/ { next }
            {
                command = $7
                for (field = 8; field <= NF; field++) {
                    command = command " " $field
                }
                print command
            }
        ' "$file"
    )

    [ "$counter" -gt 0 ] || fail "no cron command found in $file"
}

for cron_file in "$KVS_CRON" "$UPDATER_CRON" "$MANTICORE_CRON"; do
    [ -s "$cron_file" ] || fail "missing cron file: $cron_file"
    [ "$(tail -c 1 "$cron_file" | od -An -t x1 | tr -d '[:space:]')" = 0a ] ||
        fail "cron file has no final newline: $cron_file"
    validate_system_crontab "$cron_file" 1
    check_command_syntax "$cron_file"
done

grep -Eq '^\* \* \* \* \* www-data cd /var/www/kvs/admin/include && /usr/local/bin/php cron\.php ' \
    "$KVS_CRON" || fail "KVS cron is not assigned to www-data"
if grep -Fq 'yt-dlp' "$KVS_CRON"; then
    fail "the privileged updater is mixed into the KVS crontab"
fi

grep -Eq '^0 4 \* \* 0 root .*yt-dlp' "$UPDATER_CRON" ||
    fail "yt-dlp updater is not an explicit root job"
if grep -Fq 'cron.php' "$UPDATER_CRON"; then
    fail "the root updater crontab contains the KVS task"
fi

grep -Fxq '0 * * * * manticore /usr/bin/indexer --rotate --all >> /var/log/manticore/indexer-cron.log 2>&1' \
    "$MANTICORE_CRON" || fail "Manticore index rotation is not assigned to the manticore user"
if grep -Eq '^[^#].*[[:space:]]root[[:space:]].*indexer' "$MANTICORE_CRON"; then
    fail "Manticore index rotation still runs as root"
fi

grep -Eq 'groupmod --gid 1000 www-data' "$CRON_DOCKERFILE" ||
    fail "cron image does not map the KVS group to GID 1000"
grep -Eq 'usermod --uid 1000 --gid 1000 www-data' "$CRON_DOCKERFILE" ||
    fail "cron image does not map the KVS user to UID/GID 1000"
grep -Fq 'COPY crontab /etc/cron.d/kvs-cron' "$CRON_DOCKERFILE" ||
    fail "KVS system crontab is not installed"
grep -Fq 'COPY yt-dlp-update.cron /etc/cron.d/yt-dlp-update' "$CRON_DOCKERFILE" ||
    fail "root updater crontab is not installed separately"
grep -Fq 'install -o www-data -g www-data -m 0660 /dev/null /var/log/cron.log' \
    "$CRON_DOCKERFILE" || fail "KVS cron log is not writable by UID/GID 1000"
if grep -Eq '(^|&&|;)[[:space:]]*crontab[[:space:]]+/etc/cron\.d/' "$CRON_DOCKERFILE"; then
    fail "/etc/cron.d file is incorrectly installed as a user crontab"
fi

grep -Fq 'COPY manticore-indexer.cron /etc/cron.d/manticore-indexer' \
    "$MANTICORE_DOCKERFILE" || fail "Manticore system crontab is not installed"
grep -Fq 'chown root:root /etc/cron.d/manticore-indexer' "$MANTICORE_DOCKERFILE" ||
    fail "Manticore system crontab has no root ownership guarantee"
grep -Fq 'chmod 0644 /etc/cron.d/manticore-indexer' "$MANTICORE_DOCKERFILE" ||
    fail "Manticore system crontab has incompatible permissions"
grep -Fq 'install -o manticore -g manticore -m 0640 /dev/null /var/log/manticore/indexer-cron.log' \
    "$MANTICORE_DOCKERFILE" ||
    fail "Manticore indexer log is not private and writable by the manticore user"
grep -Fq 'mv /usr/local/bin/docker-entrypoint.sh /usr/local/bin/manticore-entrypoint.sh' \
    "$MANTICORE_DOCKERFILE" || fail "Manticore upstream entrypoint is not preserved"
grep -Fq 'COPY docker-entrypoint.sh /usr/local/bin/kvs-manticore-entrypoint.sh' \
    "$MANTICORE_DOCKERFILE" || fail "KVS does not install a distinct Manticore wrapper"
grep -Fq 'ENTRYPOINT ["/usr/local/bin/kvs-manticore-entrypoint.sh"]' \
    "$MANTICORE_DOCKERFILE" || fail "Manticore does not start through the KVS wrapper"
grep -Fq 'exec /usr/local/bin/manticore-entrypoint.sh "$@"' \
    "$ROOT_DIR/docker/manticore/docker-entrypoint.sh" ||
    fail "Manticore wrapper does not delegate to the upstream privilege drop"
if grep -Fxq 'exec "$@"' "$ROOT_DIR/docker/manticore/docker-entrypoint.sh"; then
    fail "Manticore wrapper still launches searchd directly as root"
fi
grep -Fq 'gosu manticore bash -o pipefail -c' \
    "$ROOT_DIR/docker/manticore/docker-entrypoint.sh" ||
    fail "the initial Manticore index build is not assigned to the manticore user"
grep -Fq 'chown manticore:manticore /etc/manticoresearch/manticore.conf' \
    "$ROOT_DIR/docker/manticore/docker-entrypoint.sh" ||
    fail "the generated Manticore configuration is not assigned to the manticore user"
grep -Fq 'chmod 600 /etc/manticoresearch/manticore.conf' \
    "$ROOT_DIR/docker/manticore/docker-entrypoint.sh" ||
    fail "the generated Manticore configuration can expose the database password"

if [ -n "${MANTICORE_RUNTIME_CONTAINER:-}" ]; then
    command -v docker >/dev/null 2>&1 || fail "Docker is required for the runtime UID check"
    [ "$(docker inspect --format '{{.State.Running}}' "$MANTICORE_RUNTIME_CONTAINER")" = true ] ||
        fail "Manticore runtime container is not running"

    docker exec "$MANTICORE_RUNTIME_CONTAINER" sh -ceu '
        manticore_uid=$(id -u manticore)
        manticore_gid=$(id -g manticore)
        [ "$manticore_uid" -ne 0 ]
        [ "$(stat -c %u /proc/1)" = "$manticore_uid" ]
        [ "$(stat -c %g /proc/1)" = "$manticore_gid" ]
        [ "$(stat -c %u /etc/manticoresearch/manticore.conf)" = "$manticore_uid" ]
        [ "$(stat -c %a /etc/manticoresearch/manticore.conf)" = 600 ]
        [ "$(stat -c %u /var/lib/manticore)" = "$manticore_uid" ]
        [ "$(stat -c %u /var/log/manticore/indexer-cron.log)" = "$manticore_uid" ]
        [ "$(stat -c %a /var/log/manticore/indexer-cron.log)" = 640 ]
        ps -eo uid=,comm= | awk -v expected_uid="$manticore_uid" '\''
            $2 == "searchd" {
                searchd++
                if ($1 != expected_uid) bad++
            }
            $2 ~ /^manticore-execu/ {
                buddy++
                if ($1 != expected_uid) bad++
            }
            $2 == "cron" {
                cron++
                if ($1 != 0) bad++
            }
            END {
                exit(searchd == 1 && buddy > 0 && cron == 1 && bad == 0 ? 0 : 1)
            }
        '\''
    ' || fail "Manticore runtime processes have unsafe UIDs"
fi

echo "PASS: Cron hardening"
