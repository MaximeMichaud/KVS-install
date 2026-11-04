#!/usr/bin/env bash
# Rebuild Debian's FFmpeg libraries as well as its programs. Disabling a
# decoder in a wrapper would leave ffprobe, additional inputs and direct
# libavcodec callers exposed. Keep Debian's other features and ABI.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_PROFILES=pkg.ffmpeg.noextra
jobs=$(nproc)
if ((jobs > 8)); then jobs=8; fi
export DEB_BUILD_OPTIONS="parallel=$jobs nocheck noautodbgsym"

# Use the authenticated source repositories of this image's Debian suite,
# including its security pocket. apt verifies the source archive hashes
# against the signed repository metadata, just as it does binary packages.
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
apt-get update
apt-get install -y --no-install-recommends build-essential dpkg-dev ca-certificates
apt-get build-dep -y --no-install-recommends --arch-only -P "$DEB_BUILD_PROFILES" ffmpeg

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
apt-get source --only-source ffmpeg
sources=(ffmpeg-*/debian/rules)
[[ ${#sources[@]} == 1 && -f ${sources[0]} ]]
cd "${sources[0]%/debian/rules}"
version=$(dpkg-parsechangelog -S Version)
dpkg --compare-versions "$version" ge '7:7.1.5-0+deb13u1'

# The standard flavor already builds shared and static libraries. Do not
# build Debian's second static flavor or the optional GPLv3 extra packages.
cat >> debian/rules <<'RULES'

FLAVORS = standard
CONFIG += --disable-decoder=magicyuv --disable-decoder=tdsc
RULES

stamp=$(dpkg-parsechangelog -S Date)
{
    printf 'ffmpeg (%s+kvs1) trixie; urgency=high\n\n' "$version"
    printf '  * Disable MagicYUV and TDSC decoding for CVE-2026-8461 and CVE-2026-65703.\n\n'
    printf ' -- KVS-install <noreply@invalid>  %s\n\n' "$stamp"
    cat debian/changelog
} > debian/changelog.kvs
mv debian/changelog.kvs debian/changelog

# Ship the complete corresponding source of the modified GPL binaries.
# Archive it before configuring, so the tarball contains no build outputs.
mkdir -p /source
tar -C "$work" -cJf /source/ffmpeg-source.tar.xz "${PWD##*/}"
cp ../*.dsc /source/debian-source.dsc
printf '%s\n' "$version+kvs1" > /source/version
cat > /source/README <<'SOURCE'
This archive contains the complete source used for the installed FFmpeg
packages, including Debian's patches and the KVS decoder restrictions.
Debian's original source descriptor is provided for provenance.

To rebuild on the same Debian suite and architecture, enable deb-src,
install build-essential and dpkg-dev, then run:
  apt-get build-dep --arch-only -P pkg.ffmpeg.noextra ffmpeg
  tar -xf ffmpeg-source.tar.xz
  cd ffmpeg-*
  DEB_BUILD_PROFILES=pkg.ffmpeg.noextra dpkg-buildpackage -B -us -uc

The source tree contains the applicable license texts. Installed package
copyright files are also available under /usr/share/doc/.
SOURCE
dpkg-buildpackage -B -us -uc -j"$jobs"

grep -qx '#define CONFIG_MAGICYUV_DECODER 0' debian/standard/config_components.h
grep -qx '#define CONFIG_TDSC_DECODER 0' debian/standard/config_components.h
mkdir -p /packages
for deb in ../*.deb; do
    package=$(dpkg-deb -f "$deb" Package)
    if [[ $package == ffmpeg || $package =~ ^lib(avcodec|avdevice|avfilter|avformat|avutil|postproc|swresample|swscale)[0-9]+$ ]]; then
        cp "$deb" /packages/
    fi
done
packages=(/packages/*.deb)
[[ ${#packages[@]} == 9 ]]
