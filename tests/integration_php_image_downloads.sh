#!/bin/bash
# Runs the download steps of docker/php/Dockerfile and docker/cron/Dockerfile,
# the ionCube loader and yt-dlp, as the build runs them, for each
# architecture the images build on, on whatever machine runs this test: in a
# container of the pinned base of each image, with the build arguments the
# Dockerfile declares and TARGETARCH set to amd64, then arm64. No emulation
# is needed: a download step only fetches, checks and unpacks.
#
#   amd64   both steps pass, the loader loads, and the yt-dlp command runs
#           the pinned release (on an x86-64 machine)
#   arm64   both downloads match their sha256, the loader and yt-dlp are
#           aarch64 executables (ELF machine 0xb7), and the last line of the
#           ionCube step, which loads the loader, fails on an x86-64 PHP: the
#           check tests the architecture being built
#
# It needs Docker and the network (ionCube, GitHub and the Debian mirror).
# PHP_FPM_TEST_IMAGE and PHP_CLI_TEST_IMAGE name other images to run, the
# locked bases through a registry mirror for example.
# shellcheck disable=SC2016  # The inspection scripts expand in the container.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
readonly NAME_PREFIX="kvsctltest-downloads-$$"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v docker > /dev/null 2>&1 || fail "docker is required"

# Prints every instruction of a Dockerfile that contains the text, joined
# the way tests/test_php_images_hardening.sh joins them.
instruction_with() {
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

arg_default() {
    sed -n "s/^ARG $2=//p" "$1"
}

# Runs, in a container of the base, the step of the Dockerfile that contains
# the text, as the build would for the architecture, then the inspection
# script, which sees the step's status in STEP_STATUS.
run_step() {
    local dockerfile="$1"
    local image="$2"
    local text="$3"
    local arch="$4"
    local inspect="$5"
    local step
    local argument
    local -a environment=()

    step=$(instruction_with "$dockerfile" "$text")
    [ "$(grep -c . <<< "$step")" = 1 ] || fail "$dockerfile has no single step with '$text'"
    # Every build argument with a default, as the build passes them.
    while IFS= read -r argument; do
        environment+=(-e "$argument")
    done < <(sed -n 's/^ARG \([A-Z][A-Z0-9_]*=.*\)$/\1/p' "$dockerfile")
    docker run --rm --name "${NAME_PREFIX}-${RANDOM}" \
        "${environment[@]}" -e "TARGETARCH=${arch}" -e "STEP=${step#RUN }" \
        -v "$ROOT_DIR/docker:/repo-docker:ro" \
        "$image" bash -c '
            set -u
            # The yt-dlp step unpacks with unzip, which the images install
            # before it; the bases do not have it.
            if [[ "$STEP" == *unzip* ]]; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq > /dev/null && apt-get install -y -qq --no-install-recommends unzip > /dev/null ||
                    exit 90
            fi
            STEP_STATUS=0
            bash -o pipefail -c "$STEP" 2>&1 || STEP_STATUS=$?
            echo "step status: $STEP_STATUS"
            '"$inspect"
}

# Prints the output of a step, each line labelled with the step.
show() {
    local label="$1"
    local output="$2"
    local line

    while IFS= read -r line; do
        printf '  %s: %s\n' "$label" "$line"
    done <<< "$output"
}

# The two bytes of the ELF machine of a file, as od prints them.
readonly ELF_MACHINE='machine() { od -An -t x1 -j 18 -N 2 "$1" | tr -d " "; }'

check_image() {
    local dockerfile="$1"
    local image="$2"
    local output

    echo "--- ${dockerfile#"$ROOT_DIR"/} in $image"

    output=$(run_step "$dockerfile" "$image" downloads.ioncube.com amd64 "$ELF_MACHINE"'
        dir=$(php -n -r "echo ini_get(\"extension_dir\");")
        echo "loader machine: $(machine "$dir/ioncube_loader_lin_${PHP_VERSION}.so")"
        echo "modules: $(php -m | grep "ionCube Loader")"') || fail "the ionCube step did not run: $output"
    show "amd64 ionCube" "$output"
    grep -Fxq 'step status: 0' <<< "$output" || fail "the ionCube step fails for amd64"
    grep -Fxq 'loader machine: 3e00' <<< "$output" || fail "the amd64 ionCube loader is not an x86-64 file"
    grep -Fxq 'modules: ionCube Loader' <<< "$output" || fail "the amd64 ionCube loader does not load"

    output=$(run_step "$dockerfile" "$image" downloads.ioncube.com arm64 "$ELF_MACHINE"'
        dir=$(php -n -r "echo ini_get(\"extension_dir\");")
        echo "loader machine: $(machine "$dir/ioncube_loader_lin_${PHP_VERSION}.so")"') ||
        fail "the ionCube step did not run: $output"
    show "arm64 ionCube" "$output"
    grep -Fq '/tmp/ioncube.tar.gz: OK' <<< "$output" || fail "the arm64 ionCube tarball does not match its sha256"
    grep -Fxq 'loader machine: b700' <<< "$output" || fail "the arm64 ionCube loader is not an aarch64 file"
    # On this machine's PHP, the aarch64 loader cannot load: the last line of
    # the step is what fails, after the download and its check passed.
    grep -Fxq 'step status: 1' <<< "$output" || fail "the arm64 ionCube step must fail at its load check on another architecture"

    output=$(run_step "$dockerfile" "$image" 'yt-dlp/releases/download' amd64 "$ELF_MACHINE"'
        echo "yt-dlp machine: $(machine /usr/local/lib/yt-dlp/current/yt-dlp)"
        echo "asset: $(cat /usr/local/lib/yt-dlp/asset)"
        install -m 0755 /repo-docker/php/yt-dlp.sh /usr/local/bin/yt-dlp
        echo "yt-dlp says: $(yt-dlp --version)"') || fail "the yt-dlp step did not run: $output"
    show "amd64 yt-dlp" "$output"
    grep -Fxq 'step status: 0' <<< "$output" || fail "the yt-dlp step fails for amd64"
    grep -Fxq 'yt-dlp machine: 3e00' <<< "$output" || fail "the amd64 yt-dlp is not an x86-64 file"
    grep -Fxq 'asset: yt-dlp_linux.zip' <<< "$output" || fail "the amd64 image does not name yt-dlp_linux.zip"
    if [ "$(uname -m)" = x86_64 ]; then
        grep -Fxq "yt-dlp says: $(arg_default "$dockerfile" YT_DLP_VERSION)" <<< "$output" ||
            fail "the yt-dlp command does not run the pinned release"
    fi

    output=$(run_step "$dockerfile" "$image" 'yt-dlp/releases/download' arm64 "$ELF_MACHINE"'
        echo "yt-dlp machine: $(machine /usr/local/lib/yt-dlp/current/yt-dlp)"
        echo "asset: $(cat /usr/local/lib/yt-dlp/asset)"
        [ -d /usr/local/lib/yt-dlp/current/_internal ] && echo "libraries: unpacked"') ||
        fail "the yt-dlp step did not run: $output"
    show "arm64 yt-dlp" "$output"
    grep -Fq '/tmp/yt-dlp.zip: OK' <<< "$output" || fail "the arm64 yt-dlp does not match its sha256"
    grep -Fxq 'step status: 0' <<< "$output" || fail "the yt-dlp step fails for arm64"
    grep -Fxq 'yt-dlp machine: b700' <<< "$output" || fail "the arm64 yt-dlp is not an aarch64 file"
    grep -Fxq 'asset: yt-dlp_linux_aarch64.zip' <<< "$output" || fail "the arm64 image does not name yt-dlp_linux_aarch64.zip"
    grep -Fxq 'libraries: unpacked' <<< "$output" || fail "the arm64 yt-dlp lost its libraries"
}

check_image "$ROOT_DIR/docker/php/Dockerfile" \
    "${PHP_FPM_TEST_IMAGE:-$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get php-fpm 8.1)}"
check_image "$ROOT_DIR/docker/cron/Dockerfile" \
    "${PHP_CLI_TEST_IMAGE:-$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get php-cli 8.1)}"
echo "PASS: the ionCube and yt-dlp downloads of both images, for amd64 and arm64"
