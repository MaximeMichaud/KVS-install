#!/bin/bash
# The PHP-FPM and cron images: what their builds download is pinned and
# checked before use, for each architecture they build on, both entrypoints
# read IONCUBE and YT_DLP_AUTO_UPDATE the same way and update yt-dlp only
# through the yt-dlp volume, opcache JIT follows the ionCube loader, and
# setup.sh takes back the JIT block it used to append to the tracked php.ini.
# shellcheck disable=SC2016  # Patterns hold the literal ${...} of the Dockerfiles.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-php-images.XXXXXX)
TESTS_RUN=0

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "ok $TESTS_RUN - $1"
}

PHP_DOCKERFILE="$ROOT_DIR/docker/php/Dockerfile"
CRON_DOCKERFILE="$ROOT_DIR/docker/cron/Dockerfile"
PHP_ENTRYPOINT="$ROOT_DIR/docker/php/docker-entrypoint.sh"
CRON_ENTRYPOINT="$ROOT_DIR/docker/cron/docker-entrypoint.sh"

# The block setup.sh appended to php/php.ini when IONCUBE was NO, written by
# the same heredoc so the bytes are the ones installs have on disk.
append_old_jit_block() {
    cat >> "$1" << 'EOF'

; JIT Configuration (PHP 8.0+ without IonCube)
; Note: JIT is incompatible with IonCube Loader
opcache.jit_buffer_size = 256M
opcache.jit = 1255
EOF
}

# Prints the default value of a build argument.
arg_default() {
    local file="$1"
    local name="$2"

    sed -n "s/^ARG ${name}=//p" "$file"
}

# Prints every instruction of a Dockerfile that contains the text, one per
# line: continuation lines are joined with a single space, without their
# indentation, and the spacing inside a line is kept.
dockerfile_instructions_with() {
    local file="$1"
    local text="$2"

    awk -v text="$text" '
        !continued && /^[[:space:]]*#/ { next }
        {
            line = $0
            if (continued) sub(/^[[:space:]]+/, "", line)
            continued = sub(/[[:space:]]*\\$/, "", line)
            instruction = instruction (instruction == "" ? "" : " ") line
            if (!continued) {
                if (index(instruction, text)) print instruction
                instruction = ""
            }
        }
    ' "$file"
}

# Prints a shell function of a file, from its opening line to the first line
# that is a lone closing brace.
extract_function() {
    local file="$1"
    local name="$2"

    awk -v signature="${name}() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$file"
}

assert_sha256() {
    local value="$1"
    local what="$2"

    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || fail "$what is not a sha256: '$value'"
}

# Prints the one instruction of a Dockerfile that contains the text, and
# fails unless there is exactly one.
one_instruction_with() {
    local file="$1"
    local text="$2"
    local found

    found=$(dockerfile_instructions_with "$file" "$text")
    [ -n "$found" ] && [ "$(grep -c . <<< "$found")" = 1 ] ||
        fail "$file must have exactly one instruction with '$text'"
    printf '%s\n' "$found"
}

# The ionCube loader and yt-dlp are native code: each architecture an image
# builds for has its own download, pinned by its own sha256, and the build
# picks the one of the architecture it builds (TARGETARCH, or dpkg for the
# legacy builder, which builds for the machine it runs on).
test_both_images_pin_a_download_per_architecture() {
    local dockerfile
    local workflow="$ROOT_DIR/.github/workflows/docker.yml"
    local service
    local base
    local series

    for dockerfile in "$PHP_DOCKERFILE" "$CRON_DOCKERFILE"; do
        grep -Fxq 'ARG TARGETARCH' "$dockerfile" || fail "$dockerfile does not read the architecture it builds"
        [ "$(grep -Fc 'arch="${TARGETARCH:-$(dpkg --print-architecture)}";' "$dockerfile")" = 2 ] ||
            fail "$dockerfile must pick both the ionCube loader and yt-dlp by the architecture it builds"
    done

    # The CI builds every series of both images for arm64 as well, on an
    # arm64 runner: the build runs the loader and yt-dlp it installs.
    for service in php cron; do
        base=php-fpm
        [ "$service" = php ] || base=php-cli
        for series in 8.1 8.2 8.3 8.4; do
            grep -Eq "^ +- \{ service: ${service}, context: docker/${service}, base: ${base}, php: \"${series//./\\.}\", arch: arm64, runner: ubuntu-[0-9.]+-arm \}$" "$workflow" ||
                fail "the CI does not build the $service image of PHP $series for arm64 on an arm64 runner"
        done
    done
    grep -Fq "runs-on: \${{ matrix.runner || 'ubuntu-latest' }}" "$workflow" ||
        fail "the image builds must run on the runner their entry names"
    grep -Fq "platforms: linux/\${{ matrix.arch || 'amd64' }}" "$workflow" ||
        fail "the image builds must build the platform of their entry"
    pass "both images pick their native downloads by the architecture they build, and the CI builds amd64 and arm64"
}

test_ioncube_loader_is_pinned_and_checked() {
    local dockerfile
    local run
    local name
    local before_extract
    local -a runs=()

    for name in IONCUBE_VERSION IONCUBE_SHA256_AMD64 IONCUBE_SHA256_ARM64; do
        [ -n "$(arg_default "$PHP_DOCKERFILE" "$name")" ] ||
            fail "the PHP-FPM image has no default for $name"
        [ "$(arg_default "$PHP_DOCKERFILE" "$name")" = "$(arg_default "$CRON_DOCKERFILE" "$name")" ] ||
            fail "the PHP-FPM and cron images pin a different $name"
    done
    [[ "$(arg_default "$PHP_DOCKERFILE" IONCUBE_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        fail "IONCUBE_VERSION must name a release, so the download is the versioned tarball"
    assert_sha256 "$(arg_default "$PHP_DOCKERFILE" IONCUBE_SHA256_AMD64)" "IONCUBE_SHA256_AMD64"
    assert_sha256 "$(arg_default "$PHP_DOCKERFILE" IONCUBE_SHA256_ARM64)" "IONCUBE_SHA256_ARM64"
    [ "$(arg_default "$PHP_DOCKERFILE" IONCUBE_SHA256_AMD64)" != "$(arg_default "$PHP_DOCKERFILE" IONCUBE_SHA256_ARM64)" ] ||
        fail "the x86-64 and aarch64 loaders are different tarballs, with different sha256"

    for dockerfile in "$PHP_DOCKERFILE" "$CRON_DOCKERFILE"; do
        run=$(one_instruction_with "$dockerfile" 'downloads.ioncube.com')
        runs+=("$run")
        [[ "$run" == *'amd64) loaders=x86-64; sha256="${IONCUBE_SHA256_AMD64}" ;;'* ]] ||
            fail "$dockerfile does not take the x86-64 loaders, checked by IONCUBE_SHA256_AMD64, on amd64"
        [[ "$run" == *'arm64) loaders=aarch64; sha256="${IONCUBE_SHA256_ARM64}" ;;'* ]] ||
            fail "$dockerfile does not take the aarch64 loaders, checked by IONCUBE_SHA256_ARM64, on arm64"
        [[ "$run" == *'*) echo "no ionCube loader is pinned for ${arch}" >&2; exit 1 ;;'* ]] ||
            fail "$dockerfile must refuse an architecture it pins no loader for"
        [[ "$run" == *'curl -fsSL -o /tmp/ioncube.tar.gz "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${loaders}_${IONCUBE_VERSION}.tar.gz";'* ]] ||
            fail "$dockerfile does not download the versioned ionCube tarball of its architecture"
        # The download is checked before anything reads it.
        before_extract=${run%%tar -xzf*}
        [[ "$before_extract" == *'echo "${sha256}  /tmp/ioncube.tar.gz" | sha256sum -c -;'* ]] ||
            fail "$dockerfile does not check the ionCube tarball before extracting it"
        # The build ends by loading the loader, in the architecture it builds,
        # with no pipe: PHP exits 255 when a reader closes its stdout early.
        [[ "$run" == *"; php -r 'extension_loaded(\"ionCube Loader\") || exit(1);'" ]] ||
            fail "$dockerfile must end the ionCube step by loading the loader"
        [[ "$run" != *"php -m |"* ]] ||
            fail "$dockerfile must not pipe php -m into a reader that may exit first"
    done
    [ "${runs[0]}" = "${runs[1]}" ] || fail "the PHP-FPM and cron images must install the loader the same way"
    pass "the ionCube loader is the versioned tarball of the architecture, checked by its sha256, then loaded"
}

test_both_images_install_the_same_yt_dlp() {
    local dockerfile
    local run
    local name
    local before_unzip
    local -a runs=()

    for name in YT_DLP_VERSION YT_DLP_SHA256_AMD64 YT_DLP_SHA256_ARM64; do
        [ -n "$(arg_default "$PHP_DOCKERFILE" "$name")" ] ||
            fail "the PHP-FPM image has no default for $name"
        [ "$(arg_default "$PHP_DOCKERFILE" "$name")" = "$(arg_default "$CRON_DOCKERFILE" "$name")" ] ||
            fail "the PHP-FPM and cron images pin a different $name"
    done
    assert_sha256 "$(arg_default "$PHP_DOCKERFILE" YT_DLP_SHA256_AMD64)" "YT_DLP_SHA256_AMD64"
    assert_sha256 "$(arg_default "$PHP_DOCKERFILE" YT_DLP_SHA256_ARM64)" "YT_DLP_SHA256_ARM64"

    for dockerfile in "$PHP_DOCKERFILE" "$CRON_DOCKERFILE"; do
        # The python3 of these images comes with the -dev packages; yt-dlp
        # does not depend on it.
        if grep -Eiq 'no python3|python3 is not|without python3' "$dockerfile"; then
            fail "$dockerfile still says the images have no python3"
        fi
        run=$(one_instruction_with "$dockerfile" 'yt-dlp/releases/download')
        runs+=("$run")
        # The directory builds: their own Python and optional libraries, and
        # no unpacking into /tmp at every run as the single-file build does.
        [[ "$run" == *'amd64) asset=yt-dlp_linux.zip; sha256="${YT_DLP_SHA256_AMD64}" ;;'* ]] ||
            fail "$dockerfile does not install yt-dlp_linux.zip, checked by YT_DLP_SHA256_AMD64, on amd64"
        [[ "$run" == *'arm64) asset=yt-dlp_linux_aarch64.zip; sha256="${YT_DLP_SHA256_ARM64}" ;;'* ]] ||
            fail "$dockerfile does not install yt-dlp_linux_aarch64.zip, checked by YT_DLP_SHA256_ARM64, on arm64"
        [[ "$run" == *'*) echo "no yt-dlp build is pinned for ${arch}" >&2; exit 1 ;;'* ]] ||
            fail "$dockerfile must refuse an architecture it pins no yt-dlp for"
        [[ "$run" == *'"https://github.com/yt-dlp/yt-dlp/releases/download/${YT_DLP_VERSION}/${asset}"'* ]] ||
            fail "$dockerfile does not download the pinned yt-dlp release asset"
        before_unzip=${run%%unzip*}
        [[ "$before_unzip" == *'echo "${sha256}  /tmp/yt-dlp.zip" | sha256sum -c -;'* ]] ||
            fail "$dockerfile does not check the sha256 of yt-dlp before unpacking it"
        for name in 'ln -s "${YT_DLP_VERSION}" /usr/local/lib/yt-dlp/current;' \
            'ln -s /var/lib/yt-dlp /usr/local/lib/yt-dlp/updates;' \
            'echo "${asset}" > /usr/local/lib/yt-dlp/asset;'; do
            [[ "$run" == *"$name"* ]] || fail "$dockerfile does not lay yt-dlp out for its command: '$name' is missing"
        done
        grep -Fxq 'COPY yt-dlp.sh /usr/local/bin/yt-dlp' "$dockerfile" ||
            fail "$dockerfile does not install the yt-dlp command"
        run=$(one_instruction_with "$dockerfile" 'ln -s yt-dlp /usr/local/bin/youtube-dl')
        [[ "$run" == *'[ "$(yt-dlp --version)" = "${YT_DLP_VERSION}" ]' ]] ||
            fail "$dockerfile must check that its yt-dlp command runs the pinned release"
    done
    [ "${runs[0]}" = "${runs[1]}" ] || fail "the PHP-FPM and cron images must install yt-dlp the same way"
    cmp -s "$ROOT_DIR/docker/php/yt-dlp.sh" "$ROOT_DIR/docker/cron/yt-dlp.sh" ||
        fail "the PHP-FPM and cron images must carry the same yt-dlp command"
    # yt-dlp-update unpacks the release it fetches.
    sed -n '/apt-get install/,/rm -rf \/var\/lib\/apt\/lists/p' "$CRON_DOCKERFILE" | grep -Eq '^[[:space:]]+unzip \\$' ||
        fail "the cron image must install unzip, which yt-dlp-update needs"
    pass "both images install the same checked yt-dlp release, the directory build of their architecture"
}

test_pecl_extensions_are_built_from_checked_tarballs() {
    local dockerfile
    local run
    local extension
    local upper
    local name
    local check
    local before_build

    for extension in memcached imagick; do
        upper=${extension^^}
        for name in "PECL_${upper}_VERSION" "PECL_${upper}_SHA256"; do
            [ -n "$(arg_default "$PHP_DOCKERFILE" "$name")" ] ||
                fail "the PHP-FPM image has no default for $name"
            [ "$(arg_default "$PHP_DOCKERFILE" "$name")" = "$(arg_default "$CRON_DOCKERFILE" "$name")" ] ||
                fail "the PHP-FPM and cron images pin a different $name"
        done
        assert_sha256 "$(arg_default "$PHP_DOCKERFILE" "PECL_${upper}_SHA256")" "PECL_${upper}_SHA256"
    done

    for dockerfile in "$PHP_DOCKERFILE" "$CRON_DOCKERFILE"; do
        # pecl install given a name fetches whatever the channel serves, and
        # given a tarball it rebuilt an imagick header with a PHP-Parser it
        # downloaded unchecked.
        [ -z "$(dockerfile_instructions_with "$dockerfile" 'pecl ')" ] ||
            fail "$dockerfile still runs pecl"
        run=$(dockerfile_instructions_with "$dockerfile" 'docker-php-ext-install -j"$(nproc)" memcached imagick')
        [ "$(grep -c . <<< "$run")" = 1 ] || fail "$dockerfile must build the PECL extensions in one step"
        # Both tarballs are downloaded and checked before anything extracts them.
        before_build=${run%%tar -xzf*}
        for extension in memcached imagick; do
            upper=${extension^^}
            [[ "$before_build" == *"curl -fsSL -o /tmp/${extension}.tgz \"https://pecl.php.net/get/${extension}-\${PECL_${upper}_VERSION}.tgz\""* ]] ||
                fail "$dockerfile does not download the $extension release tarball"
            check="echo \"\${PECL_${upper}_SHA256}  /tmp/${extension}.tgz\" | sha256sum -c -"
            [[ "$before_build" == *"$check"* ]] ||
                fail "$dockerfile does not check the $extension tarball before extracting it"
        done
        [[ "$run" == *'tar -xzf "/tmp/${extension}.tgz" -C "/usr/src/php/ext/${extension}" --strip-components 1;'* ]] ||
            fail "$dockerfile does not extract the checked tarballs with their timestamps"
        [[ "${run%%docker-php-ext-install*}" == *"-name '*_arginfo.h' -exec touch {} +"* ]] ||
            fail "$dockerfile could let make rebuild a shipped arginfo header, which downloads PHP-Parser"
        [[ "$run" == *'docker-php-source delete;'* ]] ||
            fail "$dockerfile leaves the PHP sources in the image"
    done
    pass "the PECL extensions are built offline from tarballs whose sha256 is checked first"
}

# Writes the mount table of a sandbox, in the format of /proc/self/mountinfo,
# where the fifth field is the mount point: the root and /proc of a
# container, and either the yt-dlp volume mounted on $sandbox/volume
# (with-volume), as the Compose files mount it, or nothing mounted there
# (without-volume), as in a container whose compose file is older than the
# volume. The latter still names that directory, as the source of a bind
# mount elsewhere: only the mount point may count.
write_mountinfo() {
    local sandbox="$1"
    local volume="$2"

    {
        echo '1601 1500 0:85 / / rw,relatime master:1 - overlay overlay rw'
        echo '1602 1601 0:88 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw'
        if [ "$volume" = with-volume ]; then
            echo "1622 1601 259:2 /var/lib/docker/volumes/kvs_yt-dlp/_data ${sandbox}/volume rw,relatime master:1 - ext4 /dev/nvme0n1p2 rw"
        else
            echo "1622 1601 259:2 ${sandbox}/volume /var/www/kvs rw,relatime master:1 - ext4 /dev/nvme0n1p2 rw"
        fi
    } > "$sandbox/mountinfo"
}

# Copies an entrypoint to $sandbox/docker-entrypoint.sh, with its paths moved
# into the sandbox, whose conf.d starts with the loader enabled and whose
# yt-dlp links to the volume, mounted, as the image and the Compose files
# build them.
make_entrypoint_sandbox() {
    local entrypoint="$1"
    local sandbox="$2"

    rm -rf "$sandbox"
    mkdir -p "$sandbox/conf.d" "$sandbox/cron.d" "$sandbox/bin" "$sandbox/lib/yt-dlp" "$sandbox/volume"
    echo 'zend_extension=ioncube_loader_lin_8.1.so' > "$sandbox/conf.d/00-ioncube.ini"
    : > "$sandbox/cron.d/yt-dlp-update"
    ln -s "$sandbox/volume" "$sandbox/lib/yt-dlp/updates"
    write_mountinfo "$sandbox" with-volume
    sed -e "s|/usr/local/etc/php/conf.d|${sandbox}/conf.d|g" \
        -e "s|/etc/cron.d|${sandbox}/cron.d|g" \
        -e "s|/usr/local/lib/yt-dlp|${sandbox}/lib/yt-dlp|g" \
        -e "s|/var/lib/yt-dlp|${sandbox}/volume|g" \
        -e "s|/usr/local/bin/yt-dlp-update|${sandbox}/bin/yt-dlp-update|g" \
        -e "s|/var/log/yt-dlp-update.log|${sandbox}/yt-dlp-update.log|g" \
        -e "s|/proc/self/mountinfo|${sandbox}/mountinfo|g" \
        "$entrypoint" > "$sandbox/docker-entrypoint.sh"
    # The PHP-FPM entrypoint asks php which major version it runs.
    cat > "$sandbox/bin/php" << 'EOF'
#!/bin/sh
[ "${TEST_PHP_MAJOR:-8}" -ge 8 ]
EOF
    chmod +x "$sandbox/bin/php"
}

# Runs a sandboxed entrypoint with "true" as the command, given the sandbox
# and the IONCUBE value, or "unset" to leave IONCUBE out of the environment.
# Leaves the output in $sandbox/stdout and $sandbox/stderr.
run_entrypoint() {
    local sandbox="$1"
    local ioncube="$2"
    local -a environment=(
        "PATH=${sandbox}/bin:/usr/bin:/bin"
        "KVS_MEMCACHE_LOOPBACK=false"
        "TEST_PHP_MAJOR=${TEST_PHP_MAJOR:-8}"
    )

    if [ "$ioncube" != unset ]; then
        environment+=("IONCUBE=${ioncube}")
    fi
    env -i "${environment[@]}" bash "$sandbox/docker-entrypoint.sh" true \
        > "$sandbox/stdout" 2> "$sandbox/stderr" ||
        fail "the entrypoint failed with IONCUBE=${ioncube}: $(cat "$sandbox/stderr")"
}

assert_loader_enabled() {
    local sandbox="$1"
    local what="$2"

    [ -f "$sandbox/conf.d/00-ioncube.ini" ] && [ ! -e "$sandbox/conf.d/00-ioncube.ini.disabled" ] ||
        fail "$what must keep the ionCube loader enabled"
}

assert_loader_disabled() {
    local sandbox="$1"
    local what="$2"

    [ ! -e "$sandbox/conf.d/00-ioncube.ini" ] && [ -f "$sandbox/conf.d/00-ioncube.ini.disabled" ] ||
        fail "$what must disable the ionCube loader"
    grep -Fq 'IonCube loader disabled' "$sandbox/stdout" ||
        fail "$what disabled the loader without saying so"
}

test_ioncube_words_are_strict_and_predictable() {
    local entrypoint
    local sandbox
    local value

    for entrypoint in "$PHP_ENTRYPOINT" "$CRON_ENTRYPOINT"; do
        sandbox="$TEST_DIR/ioncube-$(basename "$(dirname "$entrypoint")")"

        for value in unset '' yes YES True 1 on ON; do
            make_entrypoint_sandbox "$entrypoint" "$sandbox"
            run_entrypoint "$sandbox" "$value"
            assert_loader_enabled "$sandbox" "IONCUBE=${value} in $entrypoint"
            [ ! -s "$sandbox/stderr" ] ||
                fail "IONCUBE=${value} in $entrypoint printed: $(cat "$sandbox/stderr")"
        done

        for value in no NO False 0 off OFF Disabled; do
            make_entrypoint_sandbox "$entrypoint" "$sandbox"
            run_entrypoint "$sandbox" "$value"
            assert_loader_disabled "$sandbox" "IONCUBE=${value} in $entrypoint"
            [ ! -s "$sandbox/stderr" ] ||
                fail "IONCUBE=${value} is a known word, yet $entrypoint printed: $(cat "$sandbox/stderr")"
        done

        # An unknown word leaves the loader off, and says so on stderr.
        for value in maybe enabled y 'yes '; do
            make_entrypoint_sandbox "$entrypoint" "$sandbox"
            run_entrypoint "$sandbox" "$value"
            assert_loader_disabled "$sandbox" "IONCUBE='${value}' in $entrypoint"
            grep -Fq "WARNING: IONCUBE='${value}' is not one of" "$sandbox/stderr" ||
                fail "IONCUBE='${value}' in $entrypoint gave no warning on stderr"
            if grep -Fq WARNING "$sandbox/stdout"; then
                fail "$entrypoint printed its warning on stdout"
            fi
        done

        # A restart with another value moves the same files back and forth.
        make_entrypoint_sandbox "$entrypoint" "$sandbox"
        run_entrypoint "$sandbox" NO
        run_entrypoint "$sandbox" NO
        assert_loader_disabled "$sandbox" "a second start with IONCUBE=NO in $entrypoint"
        run_entrypoint "$sandbox" YES
        assert_loader_enabled "$sandbox" "IONCUBE=YES after NO in $entrypoint"
    done

    diff <(extract_function "$PHP_ENTRYPOINT" apply_ioncube_setting) \
        <(extract_function "$CRON_ENTRYPOINT" apply_ioncube_setting) ||
        fail "the PHP-FPM and cron entrypoints must read IONCUBE with the same function"
    [ -n "$(extract_function "$PHP_ENTRYPOINT" apply_ioncube_setting)" ] ||
        fail "apply_ioncube_setting was not found in the PHP-FPM entrypoint"
    pass "IONCUBE keeps the loader for yes, true, 1, on or nothing, and warns about unknown words"
}

# Runs a sandboxed entrypoint with the YT_DLP_AUTO_UPDATE value, or "unset"
# to leave it out of the environment, and the command that follows. Leaves
# the output in $sandbox/stdout and $sandbox/stderr.
run_entrypoint_yt_dlp() {
    local sandbox="$1"
    local value="$2"
    shift 2
    local -a environment=(
        "PATH=${sandbox}/bin:/usr/bin:/bin"
        "KVS_MEMCACHE_LOOPBACK=false"
    )

    if [ "$value" != unset ]; then
        environment+=("YT_DLP_AUTO_UPDATE=${value}")
    fi
    env -i "${environment[@]}" bash "$sandbox/docker-entrypoint.sh" "$@" \
        > "$sandbox/stdout" 2> "$sandbox/stderr" ||
        fail "the entrypoint failed with YT_DLP_AUTO_UPDATE=${value}: $(cat "$sandbox/stderr")"
}

# The commands the cron entrypoint may start: cron itself, and the update.
# The update stands for a slow one: it waits up to ten seconds for cron to
# start, and cron writes whether the update had finished by then, which only
# an update run in the foreground, holding cron back, would have.
add_cron_stubs() {
    local sandbox="$1"

    cat > "$sandbox/bin/cron" << EOF
#!/bin/sh
if [ -e "$sandbox/update-ran" ]; then
    echo 'after the update' > "$sandbox/cron-started"
else
    echo 'before the update' > "$sandbox/cron-started"
fi
EOF
    cat > "$sandbox/bin/yt-dlp-update" << EOF
#!/bin/sh
: > "$sandbox/update-started"
tries=0
while [ ! -e "$sandbox/cron-started" ] && [ "\$tries" -lt 100 ]; do
    sleep 0.1
    tries=\$((tries + 1))
done
echo "update ran"
: > "$sandbox/update-ran"
EOF
    chmod +x "$sandbox/bin/cron" "$sandbox/bin/yt-dlp-update"
}

# Waits up to ten seconds for a file a background job writes.
wait_for_file() {
    local file="$1"
    local tries=0

    while [ ! -e "$file" ] && [ "$tries" -lt 100 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    [ -e "$file" ]
}

# YT_DLP_AUTO_UPDATE decides which yt-dlp both containers run: the newer one
# the cron container keeps in the volume, through the updates link, or the
# one of the image. It reaches cron jobs only through the crontab, and only
# documented words turn updates on.
test_yt_dlp_auto_update_is_read_strictly_by_both_entrypoints() {
    local entrypoint
    local sandbox
    local value
    local -a quiet=()

    for entrypoint in "$PHP_ENTRYPOINT" "$CRON_ENTRYPOINT"; do
        sandbox="$TEST_DIR/yt-dlp-$(basename "$(dirname "$entrypoint")")"

        for value in unset '' yes YES True 1 on ON; do
            make_entrypoint_sandbox "$entrypoint" "$sandbox"
            run_entrypoint_yt_dlp "$sandbox" "$value" true
            [ "$(readlink "$sandbox/lib/yt-dlp/updates")" = "$sandbox/volume" ] ||
                fail "YT_DLP_AUTO_UPDATE='${value}' in $entrypoint must keep yt-dlp on the volume"
            [ -e "$sandbox/cron.d/yt-dlp-update" ] ||
                fail "YT_DLP_AUTO_UPDATE='${value}' in $entrypoint removed the weekly update"
            [ ! -s "$sandbox/stderr" ] ||
                fail "YT_DLP_AUTO_UPDATE='${value}' in $entrypoint printed: $(cat "$sandbox/stderr")"
        done

        for value in no NO False 0 off OFF Disabled maybe n never 'yes '; do
            make_entrypoint_sandbox "$entrypoint" "$sandbox"
            run_entrypoint_yt_dlp "$sandbox" "$value" true
            [ ! -e "$sandbox/lib/yt-dlp/updates" ] && [ ! -L "$sandbox/lib/yt-dlp/updates" ] ||
                fail "YT_DLP_AUTO_UPDATE='${value}' in $entrypoint must keep yt-dlp on the release of the image"
            grep -Fq "yt-dlp updates disabled (YT_DLP_AUTO_UPDATE=${value})" "$sandbox/stdout" ||
                fail "YT_DLP_AUTO_UPDATE='${value}' in $entrypoint turned the updates off without saying so"
            if [ "$entrypoint" = "$CRON_ENTRYPOINT" ] && [ -e "$sandbox/cron.d/yt-dlp-update" ]; then
                fail "YT_DLP_AUTO_UPDATE='${value}' left the weekly update in place"
            fi
            case "${value,,}" in
                no | false | 0 | off | disabled)
                    [ ! -s "$sandbox/stderr" ] ||
                        fail "YT_DLP_AUTO_UPDATE='${value}' is a known word, yet $entrypoint printed: $(cat "$sandbox/stderr")"
                    ;;
                *)
                    grep -Fq "WARNING: YT_DLP_AUTO_UPDATE='${value}' is not one of" "$sandbox/stderr" ||
                        fail "YT_DLP_AUTO_UPDATE='${value}' in $entrypoint gave no warning on stderr"
                    ;;
            esac
        done

        # A restart with another value moves the link back.
        make_entrypoint_sandbox "$entrypoint" "$sandbox"
        run_entrypoint_yt_dlp "$sandbox" no true
        run_entrypoint_yt_dlp "$sandbox" yes true
        [ "$(readlink "$sandbox/lib/yt-dlp/updates")" = "$sandbox/volume" ] ||
            fail "YT_DLP_AUTO_UPDATE=yes after no in $entrypoint must link the volume again"
    done

    diff <(extract_function "$PHP_ENTRYPOINT" apply_yt_dlp_auto_update) \
        <(extract_function "$CRON_ENTRYPOINT" apply_yt_dlp_auto_update) ||
        fail "the PHP-FPM and cron entrypoints must read YT_DLP_AUTO_UPDATE with the same function"
    [ -n "$(extract_function "$PHP_ENTRYPOINT" apply_yt_dlp_auto_update)" ] ||
        fail "apply_yt_dlp_auto_update was not found in the PHP-FPM entrypoint"

    # A cron container with updates on looks for a newer release as it
    # starts, in the background, so cron starts at once, and logs to the
    # updater's log; one with updates off, or a one-off command in the image,
    # does not.
    sandbox="$TEST_DIR/yt-dlp-start"
    make_entrypoint_sandbox "$CRON_ENTRYPOINT" "$sandbox"
    add_cron_stubs "$sandbox"
    run_entrypoint_yt_dlp "$sandbox" unset cron -f
    [ "$(cat "$sandbox/cron-started" 2> /dev/null)" = 'before the update' ] ||
        fail "the update at start must run in the background, yet cron started $(cat "$sandbox/cron-started" 2> /dev/null || echo never)"
    wait_for_file "$sandbox/update-ran" || fail "a cron container must look for a newer yt-dlp when it starts"
    grep -Fq 'looking for a newer release' "$sandbox/stdout" || fail "the start of the update must be logged"
    grep -Fq 'update ran' "$sandbox/yt-dlp-update.log" || fail "the update at start must write to its log"
    for value in no php; do
        sandbox="$TEST_DIR/yt-dlp-start-$value"
        quiet+=("$sandbox")
        make_entrypoint_sandbox "$CRON_ENTRYPOINT" "$sandbox"
        add_cron_stubs "$sandbox"
        if [ "$value" = no ]; then
            run_entrypoint_yt_dlp "$sandbox" no cron -f
        else
            run_entrypoint_yt_dlp "$sandbox" yes php -v
        fi
    done
    sleep 1
    for sandbox in "${quiet[@]}"; do
        [ ! -e "$sandbox/update-started" ] || fail "${sandbox##*/}: no update may start"
    done
    pass "YT_DLP_AUTO_UPDATE turns the yt-dlp updates on only for yes, true, 1, on or nothing, in both containers"
}

# The updates live in the yt-dlp volume. Without it, as in a stack whose
# compose file is older than the volume (an additional multi-site site keeps
# the copy of the template it was given), cron would keep each update in its
# own layer: out of reach of PHP-FPM, gone with the next recreate and fetched
# again at every start. Both entrypoints keep the release of the image
# instead and say why, and cron neither schedules nor starts an update.
test_yt_dlp_updates_need_the_volume() {
    local entrypoint
    local sandbox
    local value

    for entrypoint in "$PHP_ENTRYPOINT" "$CRON_ENTRYPOINT"; do
        sandbox="$TEST_DIR/yt-dlp-no-volume-$(basename "$(dirname "$entrypoint")")"

        for value in unset yes ON; do
            make_entrypoint_sandbox "$entrypoint" "$sandbox"
            write_mountinfo "$sandbox" without-volume
            run_entrypoint_yt_dlp "$sandbox" "$value" true
            [ ! -e "$sandbox/lib/yt-dlp/updates" ] && [ ! -L "$sandbox/lib/yt-dlp/updates" ] ||
                fail "without the yt-dlp volume, YT_DLP_AUTO_UPDATE='${value}' in $entrypoint must keep yt-dlp on the release of the image"
            grep -Fq "WARNING: no volume is mounted on ${sandbox}/volume, so yt-dlp is not updated" "$sandbox/stderr" ||
                fail "$entrypoint must say on stderr that the yt-dlp volume is missing: $(cat "$sandbox/stderr")"
            grep -Fq 'copy multi-site/docker-compose.site.yml.template over it again' "$sandbox/stderr" ||
                fail "$entrypoint must say how an additional multi-site site gets the yt-dlp volume"
            grep -Fxq 'yt-dlp updates disabled (no yt-dlp volume): yt-dlp stays at the release of the image' "$sandbox/stdout" ||
                fail "$entrypoint must log that the updates are off: $(cat "$sandbox/stdout")"
            if [ "$entrypoint" = "$CRON_ENTRYPOINT" ] && [ -e "$sandbox/cron.d/yt-dlp-update" ]; then
                fail "without the yt-dlp volume, YT_DLP_AUTO_UPDATE='${value}' left the weekly update in place"
            fi
        done

        # With the updates off the volume is not needed, and nothing is reported.
        make_entrypoint_sandbox "$entrypoint" "$sandbox"
        write_mountinfo "$sandbox" without-volume
        run_entrypoint_yt_dlp "$sandbox" no true
        [ ! -s "$sandbox/stderr" ] ||
            fail "YT_DLP_AUTO_UPDATE=no needs no yt-dlp volume, yet $entrypoint printed: $(cat "$sandbox/stderr")"
    done

    # Nor does a cron container without the volume look for a newer release
    # when it starts.
    sandbox="$TEST_DIR/yt-dlp-no-volume-start"
    make_entrypoint_sandbox "$CRON_ENTRYPOINT" "$sandbox"
    write_mountinfo "$sandbox" without-volume
    add_cron_stubs "$sandbox"
    run_entrypoint_yt_dlp "$sandbox" unset cron -f
    [ -e "$sandbox/cron-started" ] || fail "the cron entrypoint without the yt-dlp volume did not start cron"
    sleep 1
    [ ! -e "$sandbox/update-started" ] ||
        fail "a cron container without the yt-dlp volume must not look for a newer release when it starts"
    pass "without the yt-dlp volume both containers keep the release of their image, and say why"
}

test_opcache_jit_follows_the_loader() {
    local sandbox="$TEST_DIR/jit-php"
    local jit_ini="$sandbox/conf.d/10-opcache-jit.ini"
    local compose_file
    local mounted

    make_entrypoint_sandbox "$PHP_ENTRYPOINT" "$sandbox"
    run_entrypoint "$sandbox" YES
    [ ! -e "$jit_ini" ] || fail "JIT must stay off while the ionCube loader is enabled"

    run_entrypoint "$sandbox" NO
    [ -f "$jit_ini" ] || fail "JIT must be turned on when the ionCube loader is disabled"
    [ "$(grep -v '^;' "$jit_ini")" = $'opcache.jit_buffer_size = 256M\nopcache.jit = 1255' ] ||
        fail "the JIT ini must hold the two settings setup.sh used to append: $(cat "$jit_ini")"
    grep -Fq 'Opcache JIT enabled' "$sandbox/stdout" || fail "JIT was turned on without saying so"

    run_entrypoint "$sandbox" YES
    [ ! -e "$jit_ini" ] || fail "enabling the loader again must remove the JIT ini"

    run_entrypoint "$sandbox" maybe
    [ -f "$jit_ini" ] || fail "an unknown IONCUBE word disables the loader, so JIT must be on"

    # JIT arrived with PHP 8.0: a 7.4 image gets no JIT ini, and a stale one
    # is removed.
    TEST_PHP_MAJOR=7 run_entrypoint "$sandbox" NO
    [ ! -e "$jit_ini" ] || fail "a PHP 7 image must get no JIT ini"

    # The cron image has no opcache and never mounted php.ini, which held the
    # JIT block, so its entrypoint writes no JIT ini.
    sandbox="$TEST_DIR/jit-cron"
    make_entrypoint_sandbox "$CRON_ENTRYPOINT" "$sandbox"
    run_entrypoint "$sandbox" NO
    [ ! -e "$sandbox/conf.d/10-opcache-jit.ini" ] || fail "the cron entrypoint must not write a JIT ini"

    # The stack mounts php.ini into conf.d. The JIT ini loads before it, so a
    # JIT setting an operator writes in php.ini still wins, and after the
    # loader's ini.
    for compose_file in "$ROOT_DIR/docker/docker-compose.yml" \
        "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template"; do
        mounted=$(sed -n 's|.*php/php\.ini:/usr/local/etc/php/conf\.d/\([^:]*\):ro$|\1|p' "$compose_file")
        [ -n "$mounted" ] || fail "$compose_file no longer mounts php.ini into conf.d"
        [ "$(printf '%s\n' "$mounted" 10-opcache-jit.ini 00-ioncube.ini | LC_ALL=C sort | tr '\n' ' ')" = \
            "00-ioncube.ini 10-opcache-jit.ini ${mounted} " ] ||
            fail "the JIT ini must load after 00-ioncube.ini and before ${mounted}"
    done
    pass "opcache JIT is on exactly when the ionCube loader is off, and php.ini can still override it"
}

# Runs the function setup.sh uses, from a directory laid out like docker/.
run_jit_block_removal() {
    local workdir="$1"

    (
        cd "$workdir"
        # shellcheck disable=SC2034  # The colors are read by the extracted function.
        GREEN='' YELLOW='' NC=''
        # shellcheck source=/dev/null
        source "$TEST_DIR/remove_appended_jit_block.sh"
        remove_appended_jit_block
    ) > "$workdir/out" 2>&1 || fail "removing the JIT block failed: $(cat "$workdir/out")"
}

test_setup_takes_back_the_jit_block_it_appended() {
    local workdir="$TEST_DIR/setup-jit"
    local ini="$workdir/php/php.ini"
    local inode
    local before

    if grep -Eq '>>[[:space:]]*"?php/php\.ini' "$ROOT_DIR/docker/setup.sh"; then
        fail "setup.sh still appends to the tracked php.ini"
    fi
    extract_function "$ROOT_DIR/docker/setup.sh" remove_appended_jit_block \
        > "$TEST_DIR/remove_appended_jit_block.sh"
    [ -s "$TEST_DIR/remove_appended_jit_block.sh" ] ||
        fail "remove_appended_jit_block was not found in setup.sh"
    grep -Fxq 'remove_appended_jit_block' "$ROOT_DIR/docker/setup.sh" ||
        fail "setup.sh never calls remove_appended_jit_block"

    mkdir -p "$workdir/php"
    cp "$ROOT_DIR/docker/php/php.ini" "$ini"
    chmod 644 "$ini"
    append_old_jit_block "$ini"
    inode=$(stat -c %i "$ini")
    run_jit_block_removal "$workdir"
    cmp -s "$ini" "$ROOT_DIR/docker/php/php.ini" ||
        fail "removing the JIT block must give back the tracked php.ini: $(diff "$ROOT_DIR/docker/php/php.ini" "$ini")"
    [ "$(stat -c %i "$ini")" = "$inode" ] ||
        fail "php.ini must be changed in place: the php-fpm container mounts its inode"
    [ "$(stat -c %a "$ini")" = 644 ] || fail "php.ini lost its mode"
    grep -Fq 'the PHP-FPM entrypoint now enables JIT' "$workdir/out" ||
        fail "the setup must say the entrypoint handles JIT now: $(cat "$workdir/out")"

    run_jit_block_removal "$workdir"
    cmp -s "$ini" "$ROOT_DIR/docker/php/php.ini" || fail "a second run changed php.ini"
    [ ! -s "$workdir/out" ] || fail "a second run had nothing to say, yet printed: $(cat "$workdir/out")"

    # Anything but the block exactly as appended, at the end of the file, is
    # the operator's and stays.
    cp "$ROOT_DIR/docker/php/php.ini" "$ini"
    append_old_jit_block "$ini"
    echo 'memory_limit = 1G' >> "$ini"
    before=$(cat "$ini")
    run_jit_block_removal "$workdir"
    [ "$(cat "$ini")" = "$before" ] || fail "a block followed by the operator's settings must stay"

    cp "$ROOT_DIR/docker/php/php.ini" "$ini"
    append_old_jit_block "$ini"
    sed -i 's/^opcache.jit = 1255$/opcache.jit = tracing/' "$ini"
    before=$(cat "$ini")
    run_jit_block_removal "$workdir"
    [ "$(cat "$ini")" = "$before" ] || fail "a JIT block the operator edited must stay"
    [ ! -s "$workdir/out" ] || fail "an edited block was reported as removed"

    rm -f "$ini"
    run_jit_block_removal "$workdir"
    [ ! -e "$ini" ] || fail "a missing php.ini must not be created"
    pass "setup.sh restores php.ini when it ends with the JIT block it appended, and only then"
}

test_both_images_pin_a_download_per_architecture
test_ioncube_loader_is_pinned_and_checked
test_both_images_install_the_same_yt_dlp
test_pecl_extensions_are_built_from_checked_tarballs
test_ioncube_words_are_strict_and_predictable
test_yt_dlp_auto_update_is_read_strictly_by_both_entrypoints
test_yt_dlp_updates_need_the_volume
test_opcache_jit_follows_the_loader
test_setup_takes_back_the_jit_block_it_appended

echo "1..$TESTS_RUN"
