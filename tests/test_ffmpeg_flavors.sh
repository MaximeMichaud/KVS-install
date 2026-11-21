#!/usr/bin/env bash
# Exercise the packaging rules with make, without compiling FFmpeg.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for image in php cron; do
    mkdir -p "$work/$image/debian"
    cd "$work/$image"
    # Run the packaging profile and rules edits without fetching or compiling.
    sed -n -e '/^export DEB_BUILD_PROFILES=/p' \
        -e '/^dpkg --compare-versions /,/^stamp=/{ /^dpkg --compare-versions /d; /^stamp=/d; p; }' \
        "$root/docker/$image/build-ffmpeg.sh" > patch-rules.sh
    cat > debian/rules <<'RULES'
FLAVORS = standard static

override_dh_auto_configure: $(patsubst %,configure_%,$(FLAVORS))
override_dh_auto_build-arch: $(patsubst %,build_%,$(FLAVORS))

configure_%:
	@mkdir -p debian/$*
	@printf '%s\n' '$(CONFIG)' > debian/$*/configured
build_%:
	@$(MAKE) -C debian/$* -f /dev/null --eval='tool: ;' tool
	@touch debian/$*/built
RULES
    cp debian/rules original.rules
    bash -eu patch-rules.sh
    [[ ! -e debian/standard ]]
    make -s -f debian/rules override_dh_auto_configure override_dh_auto_build-arch
    [[ -f debian/standard/built ]]
    grep -Fwq -- '--disable-decoder=magicyuv' debian/standard/configured
    grep -Fwq -- '--disable-decoder=tdsc' debian/standard/configured
    if [[ -e debian/static ]]; then
        echo "$image: the static flavor was configured or built" >&2
        exit 1
    fi

    # A different upstream definition must stop the build for review.
    sed 's/^FLAVORS = standard static$/FLAVORS := standard static/' original.rules > debian/rules
    if bash -eu patch-rules.sh 2> error; then
        echo "$image: accepted an unrecognized upstream flavor definition" >&2
        exit 1
    fi
    grep -Fq 'flavor definition' error

    # Under the profile used for packaging, make must reject static even if
    # an upstream rule adds it after the assignment or bypasses FLAVORS.
    for layout in reassigned explicit_build explicit_configure; do
        cp original.rules debian/rules
        case "$layout" in
            reassigned)
                # shellcheck disable=SC2016  # GNU Make expressions.
                sed -i '/^FLAVORS =/a ifneq ($(filter pkg.ffmpeg.noextra,$(DEB_BUILD_PROFILES)),)\nFLAVORS += static\nendif' debian/rules
                ;;
            explicit_build) echo 'override_dh_auto_build-arch: build_static' >> debian/rules ;;
            explicit_configure) echo 'override_dh_auto_configure: configure_static' >> debian/rules ;;
        esac
        if bash -eu patch-rules.sh 2> error; then
            echo "$image: accepted static in the $layout rules" >&2
            exit 1
        fi
        grep -Eq 'Unexpected FFmpeg prerequisite (configure|build)_static' error
    done
    echo "PASS: $image builds only the standard flavor and detects a changed definition"
done
