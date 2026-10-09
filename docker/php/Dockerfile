# PHP-FPM image for KVS.
#
# The base is pinned by digest: a tag moves, a digest does not, so this build
# and the release CI resolve the same bytes. The default is the series
# docker/images.lock calls the default (8.1). Building another series means
# passing both arguments, the version for the ionCube loader and the base of
# that series:
#
#   docker build --build-arg PHP_VERSION=8.3 \
#       --build-arg PHP_BASE="$(docker/bin/resolve-bases.sh --get php-fpm 8.3)" \
#       docker/php
#
# The two are cross-checked below, so a mismatch fails the build instead of
# producing an image whose loader refuses every encoded file.
#
# Compose passes PHP_BASE empty when .env names no base (an .env written
# before the lock has no PHP_FPM_BASE): the build then starts from the
# php:<PHP_VERSION>-fpm tag, as it did before the lock. That fallback is
# computed here into PHP_FROM, which is not meant to be passed, because a
# default nested in another one in the compose file stops Docker Compose
# older than 2.18 from reading the file at all.
ARG PHP_VERSION=8.1
ARG PHP_BASE=php:8.1-fpm@sha256:a3118db1911fdd3b3ac66605122ddc859286688ced86fc860fec6d19cc2d6c55
ARG PHP_FROM=${PHP_BASE:-php:${PHP_VERSION}-fpm}
FROM ${PHP_FROM}

# The PHP series the base runs.
ARG PHP_VERSION

# The architecture being built, amd64 or arm64. The ionCube loader and
# yt-dlp are native code, published once per architecture, so each is pinned
# by one sha256 per architecture. TARGETARCH is empty only under the legacy
# builder, which builds for the machine it runs on, and dpkg names amd64 and
# arm64 the way Docker does.
ARG TARGETARCH

# ionCube loader. ionCube publishes no checksum file next to the downloads,
# so each sha256 was computed from the versioned tarball: the x86-64 one on
# 2026-09-24, when the rolling ioncube_loaders_lin_x86-64.tar.gz served the
# same bytes, and the aarch64 one on 2026-10-06.
ARG IONCUBE_VERSION=15.5.1
ARG IONCUBE_SHA256_AMD64=739962bd012e77ee82bf01f77a9641f050e4be057f0a5d1a95fe59ce11fd62ba
ARG IONCUBE_SHA256_ARM64=b091974aa80a76bd798d71fd5209797d93749b0be13eaff978a3dbe0106b9e1f

# yt-dlp, the build each release makes for Linux on this architecture as a
# directory: yt-dlp_linux.zip, or yt-dlp_linux_aarch64.zip. It carries its
# own Python and the optional libraries yt-dlp uses (curl_cffi for browser
# impersonation, websockets, requests, brotli, certifi, mutagen and
# pycryptodomex), where the zipapp would run on the python3 these images
# only get as a dependency of the -dev packages, with urllib alone. Unlike
# the single-file yt-dlp_linux, it does not unpack itself into /tmp at every
# run. Each sha256 is the one the release publishes in SHA2-256SUMS:
# https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/SHA2-256SUMS
# The cron image installs the same release, and keeps a newer one in the
# yt-dlp volume both containers mount (cron/yt-dlp-update.sh).
ARG YT_DLP_VERSION=2026.08.19
ARG YT_DLP_SHA256_AMD64=32e72032766bef9199d99d15beb69fd52e46df8f8b06f0d8745db59e04d339e9
ARG YT_DLP_SHA256_ARM64=4e27ad43f3a34bacffd078694eb3edbb4e3b378e7da44edab2be02e98555516e

# PECL extensions, at the current stable release of each, built from the
# same tarballs as in the cron image. pecl.php.net publishes no checksum
# next to its downloads, so each sha256 is the one of the release tarball as
# published when the version was pinned, computed on 2026-10-06. The source
# files in both tarballs were also compared with the release tag of each
# project on GitHub: they match, apart from the version number the PECL
# packaging writes into imagick.
ARG PECL_MEMCACHED_VERSION=3.4.0
ARG PECL_MEMCACHED_SHA256=c163434eb0da97c8f45c7ad41d979d381f8b81c49402b1b90b063987fb37972e
ARG PECL_IMAGICK_VERSION=3.8.1
ARG PECL_IMAGICK_SHA256=3a3587c0a524c17d0dad9673a160b90cd776e836838474e173b549ed864352ee

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# DL3008 stays muted on purpose. Pinning a Debian package version pins it to
# one snapshot of the suite, and Debian removes the old binaries as soon as a
# security update lands, so a pinned apt line stops building a few days later.
# The base image digest above is what makes this layer reproducible: it fixes
# the suite and the apt sources the packages come from.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    libwebp-dev \
    libzip-dev \
    libmemcached-dev \
    libmagickwand-dev \
    imagemagick \
    imagemagick-7-common \
    libheif1 \
    libheif-plugin-aomenc \
    libheif-plugin-aomdec \
    libavif-dev \
    libaom-dev \
    ffmpeg \
    aria2 \
    procps \
    mariadb-client \
    socat \
    unzip \
    curl \
    wget \
    ca-certificates \
    fonts-dejavu-core \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/ffmpeg /usr/local/bin/ffmpeg \
    && ln -s /usr/bin/convert /usr/local/bin/convert \
    && ln -s /usr/bin/wget /usr/local/bin/wget \
    && ln -sf /usr/bin/mariadb-dump /usr/bin/mysqldump

# Optional: For MaxMind GeoIP (not needed if using Cloudflare)
# Add to apt-get above: libmaxminddb0 libmaxminddb-dev
# Add to pecl install: maxminddb

# Install PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        gd \
        mysqli \
        pdo_mysql \
        zip \
        bcmath \
        opcache

# Build the PECL extensions from the tarballs checked above, the way the core
# extensions are built. pecl install would take a checked tarball too, but it
# writes its build tree with fresh timestamps, which left imagick's .stub.php
# files newer than the headers generated from them, so make install rebuilt
# a header with PHP's gen_stub.php, which downloads PHP-Parser from GitHub
# with no checksum. tar keeps the timestamps of the release, and touching the
# shipped headers makes sure no stub is ever newer than its header: the build
# compiles what the release ships and downloads nothing else.
# Add maxminddb the same way if GeoIP is needed.
RUN set -eux; \
    curl -fsSL -o /tmp/memcached.tgz \
        "https://pecl.php.net/get/memcached-${PECL_MEMCACHED_VERSION}.tgz"; \
    echo "${PECL_MEMCACHED_SHA256}  /tmp/memcached.tgz" | sha256sum -c -; \
    curl -fsSL -o /tmp/imagick.tgz \
        "https://pecl.php.net/get/imagick-${PECL_IMAGICK_VERSION}.tgz"; \
    echo "${PECL_IMAGICK_SHA256}  /tmp/imagick.tgz" | sha256sum -c -; \
    docker-php-source extract; \
    for extension in memcached imagick; do \
        mkdir "/usr/src/php/ext/${extension}"; \
        tar -xzf "/tmp/${extension}.tgz" -C "/usr/src/php/ext/${extension}" --strip-components 1; \
        find "/usr/src/php/ext/${extension}" -name '*_arginfo.h' -exec touch {} +; \
    done; \
    docker-php-ext-install -j"$(nproc)" memcached imagick; \
    docker-php-source delete; \
    rm -f /tmp/memcached.tgz /tmp/imagick.tgz

# ionCube Loader. It is installed in every image: a build does not know
# whether the site it will serve is encoded, and the loader is one .so plus a
# one line ini, so the entrypoint turns it off when the container starts,
# unless IONCUBE is unset or one of yes, true, 1 and on.
# Clause 2.1 of the loader licence allows free redistribution provided the
# licence travels with it, which is why LICENSE.txt stays in the image.
# The last line loads the loader and asks PHP whether it is in, which fails
# unless the tarball is the one of the architecture being built and holds
# the series of the base. It is not "php -m | grep -q": grep -q exits at its
# first match, and PHP exits 255 when a write finds the pipe closed
# (sapi/cli/php_cli.c), which failed the build at random on a busy CPU.
RUN set -eux; \
    series="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"; \
    if [ "$series" != "${PHP_VERSION}" ]; then \
        echo "PHP_BASE runs PHP ${series} but PHP_VERSION says ${PHP_VERSION}" >&2; \
        exit 1; \
    fi; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
        amd64) loaders=x86-64; sha256="${IONCUBE_SHA256_AMD64}" ;; \
        arm64) loaders=aarch64; sha256="${IONCUBE_SHA256_ARM64}" ;; \
        *) echo "no ionCube loader is pinned for ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/ioncube.tar.gz \
        "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${loaders}_${IONCUBE_VERSION}.tar.gz"; \
    echo "${sha256}  /tmp/ioncube.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/ioncube.tar.gz -C /tmp; \
    extension_dir="$(php -r 'echo ini_get("extension_dir");')"; \
    cp "/tmp/ioncube/ioncube_loader_lin_${series}.so" "${extension_dir}/"; \
    install -D -m 0644 /tmp/ioncube/LICENSE.txt /usr/local/share/ioncube/LICENSE.txt; \
    echo "zend_extension=ioncube_loader_lin_${series}.so" > /usr/local/etc/php/conf.d/00-ioncube.ini; \
    rm -rf /tmp/ioncube /tmp/ioncube.tar.gz; \
    php -r 'extension_loaded("ionCube Loader") || exit(1);'

# yt-dlp: the release above in /usr/local/lib/yt-dlp/<version>, its command
# renamed yt-dlp whatever the architecture, "current" naming it, updates/
# leading to the newer releases of the yt-dlp volume and asset naming the
# build yt-dlp-update fetches. The yt-dlp command (yt-dlp.sh) runs the newer
# of the two, and the last line checks that it runs the release above.
RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
        amd64) asset=yt-dlp_linux.zip; sha256="${YT_DLP_SHA256_AMD64}" ;; \
        arm64) asset=yt-dlp_linux_aarch64.zip; sha256="${YT_DLP_SHA256_ARM64}" ;; \
        *) echo "no yt-dlp build is pinned for ${arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/yt-dlp.zip \
        "https://github.com/yt-dlp/yt-dlp/releases/download/${YT_DLP_VERSION}/${asset}"; \
    echo "${sha256}  /tmp/yt-dlp.zip" | sha256sum -c -; \
    mkdir -p "/usr/local/lib/yt-dlp/${YT_DLP_VERSION}"; \
    unzip -q /tmp/yt-dlp.zip -d "/usr/local/lib/yt-dlp/${YT_DLP_VERSION}"; \
    mv "/usr/local/lib/yt-dlp/${YT_DLP_VERSION}/${asset%.zip}" "/usr/local/lib/yt-dlp/${YT_DLP_VERSION}/yt-dlp"; \
    ln -s "${YT_DLP_VERSION}" /usr/local/lib/yt-dlp/current; \
    install -d -m 0755 /var/lib/yt-dlp; \
    ln -s /var/lib/yt-dlp /usr/local/lib/yt-dlp/updates; \
    echo "${asset}" > /usr/local/lib/yt-dlp/asset; \
    rm -f /tmp/yt-dlp.zip
COPY yt-dlp.sh /usr/local/bin/yt-dlp
RUN chmod 0755 /usr/local/bin/yt-dlp \
    && ln -s yt-dlp /usr/local/bin/youtube-dl \
    && [ "$(yt-dlp --version)" = "${YT_DLP_VERSION}" ]

# Configure PHP-FPM
RUN sed -i \
    -e 's/pm.max_children = 5/pm.max_children = 20/' \
    -e 's/pm.start_servers = 2/pm.start_servers = 5/' \
    -e 's/pm.min_spare_servers = 1/pm.min_spare_servers = 3/' \
    -e 's/pm.max_spare_servers = 3/pm.max_spare_servers = 10/' \
    /usr/local/etc/php-fpm.d/www.conf

# Symlink PHP to /usr/bin (KVS scripts expect it there), and give www-data
# the UID and GID 1000 that own the KVS files on the host.
RUN ln -sf /usr/local/bin/php /usr/bin/php \
    && usermod -u 1000 www-data && groupmod -g 1000 www-data

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /var/www/kvs

EXPOSE 9000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
