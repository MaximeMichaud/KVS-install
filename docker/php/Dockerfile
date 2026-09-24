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
ARG PHP_BASE=php:8.1-fpm@sha256:a3118db1911fdd3b3ac66605122ddc859286688ced86fc860fec6d19cc2d6c55
FROM ${PHP_BASE}

# The PHP series the base runs.
ARG PHP_VERSION=8.1

# ionCube loader. ionCube publishes no checksum file next to the download, so
# this sha256 was computed from the versioned tarball on 2026-09-24; the
# rolling ioncube_loaders_lin_x86-64.tar.gz served the same bytes that day.
ARG IONCUBE_VERSION=15.5.1
ARG IONCUBE_SHA256=739962bd012e77ee82bf01f77a9641f050e4be057f0a5d1a95fe59ce11fd62ba

# yt-dlp. The sha256 is the one the release publishes in SHA2-256SUMS:
# https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/SHA2-256SUMS
# yt-dlp is the Python zipapp and needs a python3 on the host image; the
# self-contained build is yt-dlp_linux, sha256
# 58162f9bfdc27458ea47bfcb311cf47028f17d8154a8bf7d689861d46399230a.
ARG YT_DLP_VERSION=2026.08.19
ARG YT_DLP_ASSET=yt-dlp
ARG YT_DLP_SHA256=1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6

# PECL extensions, at the current stable release of each.
ARG PECL_MEMCACHED_VERSION=3.4.0
ARG PECL_IMAGICK_VERSION=3.8.1

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

# Install PECL extensions
# Add maxminddb if GeoIP needed: pecl install maxminddb && docker-php-ext-enable maxminddb
RUN pecl install "memcached-${PECL_MEMCACHED_VERSION}" "imagick-${PECL_IMAGICK_VERSION}" \
    && docker-php-ext-enable memcached imagick

# ionCube Loader. It is installed in every image: a build does not know
# whether the site it will serve is encoded, and the loader is one .so plus a
# one line ini, so the entrypoint turns it off at runtime when IONCUBE is NO.
# Clause 2.1 of the loader licence allows free redistribution provided the
# licence travels with it, which is why LICENSE.txt stays in the image.
RUN set -eux; \
    series="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"; \
    if [ "$series" != "${PHP_VERSION}" ]; then \
        echo "PHP_BASE runs PHP ${series} but PHP_VERSION says ${PHP_VERSION}" >&2; \
        exit 1; \
    fi; \
    curl -fsSL -o /tmp/ioncube.tar.gz \
        "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64_${IONCUBE_VERSION}.tar.gz"; \
    echo "${IONCUBE_SHA256}  /tmp/ioncube.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/ioncube.tar.gz -C /tmp; \
    extension_dir="$(php -r 'echo ini_get("extension_dir");')"; \
    cp "/tmp/ioncube/ioncube_loader_lin_${series}.so" "${extension_dir}/"; \
    install -D -m 0644 /tmp/ioncube/LICENSE.txt /usr/local/share/ioncube/LICENSE.txt; \
    echo "zend_extension=ioncube_loader_lin_${series}.so" > /usr/local/etc/php/conf.d/00-ioncube.ini; \
    rm -rf /tmp/ioncube /tmp/ioncube.tar.gz; \
    php -m | grep -q 'ionCube Loader'

# Install yt-dlp
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/yt-dlp \
        "https://github.com/yt-dlp/yt-dlp/releases/download/${YT_DLP_VERSION}/${YT_DLP_ASSET}"; \
    echo "${YT_DLP_SHA256}  /usr/local/bin/yt-dlp" | sha256sum -c -; \
    chmod a+rx /usr/local/bin/yt-dlp; \
    ln -s /usr/local/bin/yt-dlp /usr/local/bin/youtube-dl

# Configure PHP-FPM
RUN sed -i \
    -e 's/pm.max_children = 5/pm.max_children = 20/' \
    -e 's/pm.start_servers = 2/pm.start_servers = 5/' \
    -e 's/pm.min_spare_servers = 1/pm.min_spare_servers = 3/' \
    -e 's/pm.max_spare_servers = 3/pm.max_spare_servers = 10/' \
    /usr/local/etc/php-fpm.d/www.conf

# Create log directory
RUN mkdir -p /var/log/php && chown www-data:www-data /var/log/php

# Symlink PHP to /usr/bin (KVS scripts expect it there)
RUN ln -sf /usr/local/bin/php /usr/bin/php

# Set proper permissions
RUN usermod -u 1000 www-data && groupmod -g 1000 www-data

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /var/www/kvs

EXPOSE 9000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
