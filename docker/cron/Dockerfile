ARG PHP_VERSION=8.1
FROM php:${PHP_VERSION}-cli

ARG IONCUBE=YES
ARG PHP_VERSION

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

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
    && pecl install memcached imagick \
    && docker-php-ext-enable memcached imagick \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/ffmpeg /usr/local/bin/ffmpeg \
    && ln -s /usr/bin/convert /usr/local/bin/convert \
    && ln -s /usr/bin/wget /usr/local/bin/wget \
    && ln -sf /usr/bin/mariadb-dump /usr/bin/mysqldump

# Install IonCube Loader if enabled
RUN if [ "$IONCUBE" = "YES" ]; then \
        curl -fsSL https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz -o /tmp/ioncube.tar.gz \
        && tar -xzf /tmp/ioncube.tar.gz -C /tmp \
        && PHP_EXT_DIR=$(php -i | grep "^extension_dir" | sed 's/.*=> //') \
        && cp "/tmp/ioncube/ioncube_loader_lin_${PHP_VERSION}.so" "${PHP_EXT_DIR}/" \
        && echo "zend_extension=ioncube_loader_lin_${PHP_VERSION}.so" > /usr/local/etc/php/conf.d/00-ioncube.ini \
        && rm -rf /tmp/ioncube*; \
    fi

# Install yt-dlp
RUN curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp \
    && chmod a+rx /usr/local/bin/yt-dlp \
    && ln -s /usr/local/bin/yt-dlp /usr/local/bin/youtube-dl

# Symlink PHP to /usr/bin (KVS scripts expect it there)
RUN ln -sf /usr/local/bin/php /usr/bin/php

# Match the KVS bind-mount ownership used by the PHP-FPM container.
RUN groupmod --gid 1000 www-data \
    && usermod --uid 1000 --gid 1000 www-data

# Install system crontabs. Files in /etc/cron.d include an explicit user field,
# so the KVS task can run unprivileged while the binary updater remains root.
COPY crontab /etc/cron.d/kvs-cron
COPY yt-dlp-update.cron /etc/cron.d/yt-dlp-update
RUN chown root:root /etc/cron.d/kvs-cron /etc/cron.d/yt-dlp-update \
    && chmod 0644 /etc/cron.d/kvs-cron /etc/cron.d/yt-dlp-update \
    && install -o www-data -g www-data -m 0660 /dev/null /var/log/cron.log \
    && install -o root -g root -m 0600 /dev/null /var/log/yt-dlp-update.log

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["cron", "-f"]
