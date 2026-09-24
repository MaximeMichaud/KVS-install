# Cron image for KVS: the KVS task and the yt-dlp updater.
#
# The base is pinned by digest, like the PHP-FPM image. Building another
# series means passing both arguments:
#
#   docker build --build-arg PHP_VERSION=8.3 \
#       --build-arg PHP_BASE="$(docker/bin/resolve-bases.sh --get php-cli 8.3)" \
#       docker/cron
ARG PHP_BASE=php:8.1-cli@sha256:76e563191d1ade120313a8736df24154d21da5155c0756f147c0b01bd19d9087
FROM ${PHP_BASE}

# The PHP series the base runs.
ARG PHP_VERSION=8.1

# ionCube loader. ionCube publishes no checksum file next to the download, so
# this sha256 was computed from the versioned tarball on 2026-09-24; the
# rolling ioncube_loaders_lin_x86-64.tar.gz served the same bytes that day.
ARG IONCUBE_VERSION=15.5.1
ARG IONCUBE_SHA256=739962bd012e77ee82bf01f77a9641f050e4be057f0a5d1a95fe59ce11fd62ba

# yt-dlp, the self-contained Linux build: the php base has no python3, so
# the zipapp the project also publishes cannot run here. The sha256 is the
# one the release publishes in SHA2-256SUMS:
# https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/SHA2-256SUMS
ARG YT_DLP_VERSION=2026.08.19
ARG YT_DLP_ASSET=yt-dlp_linux
ARG YT_DLP_SHA256=58162f9bfdc27458ea47bfcb311cf47028f17d8154a8bf7d689861d46399230a

# PECL extensions, at the current stable release of each.
ARG PECL_MEMCACHED_VERSION=3.4.0
ARG PECL_IMAGICK_VERSION=3.8.1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# DL3008 stays muted on purpose. Pinning a Debian package version pins it to
# one snapshot of the suite, and Debian removes the old binaries as soon as a
# security update lands, so a pinned apt line stops building a few days later.
# The base image digest above is what makes this layer reproducible.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    cron \
    mariadb-client \
    libmemcached-dev \
    libz-dev \
    socat \
    curl \
    wget \
    ca-certificates \
    ffmpeg \
    aria2 \
    procps \
    imagemagick \
    imagemagick-7-common \
    fonts-dejavu-core \
    fonts-liberation \
    libmagickwand-dev \
    libheif1 \
    libheif-plugin-aomenc \
    libheif-plugin-aomdec \
    libavif-dev \
    libaom-dev \
    && docker-php-ext-install mysqli pdo_mysql \
    && pecl install "memcached-${PECL_MEMCACHED_VERSION}" "imagick-${PECL_IMAGICK_VERSION}" \
    && docker-php-ext-enable memcached imagick \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/ffmpeg /usr/local/bin/ffmpeg \
    && ln -s /usr/bin/convert /usr/local/bin/convert \
    && ln -s /usr/bin/wget /usr/local/bin/wget \
    && ln -sf /usr/bin/mariadb-dump /usr/bin/mysqldump

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

# Symlink PHP to /usr/bin (KVS scripts expect it there)
RUN ln -sf /usr/local/bin/php /usr/bin/php

# Match the KVS bind-mount ownership used by the PHP-FPM container.
RUN groupmod --gid 1000 www-data \
    && usermod --uid 1000 --gid 1000 www-data

# Install system crontabs. Files in /etc/cron.d include an explicit user field,
# so the KVS task can run unprivileged while the binary updater remains root.
COPY crontab /etc/cron.d/kvs-cron
COPY yt-dlp-update.cron /etc/cron.d/yt-dlp-update
COPY yt-dlp-update.sh /usr/local/bin/yt-dlp-update
RUN chown root:root /etc/cron.d/kvs-cron /etc/cron.d/yt-dlp-update \
    && chmod 0644 /etc/cron.d/kvs-cron /etc/cron.d/yt-dlp-update \
    && chmod 0755 /usr/local/bin/yt-dlp-update \
    && install -o www-data -g www-data -m 0660 /dev/null /var/log/cron.log \
    && install -o root -g root -m 0600 /dev/null /var/log/yt-dlp-update.log

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["cron", "-f"]
