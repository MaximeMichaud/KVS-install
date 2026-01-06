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
    curl \
    wget \
    ca-certificates \
    ffmpeg \
    aria2 \
    imagemagick \
    imagemagick-7-common \
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
    && ln -s /usr/bin/convert /usr/local/bin/convert \
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

# Setup crontab
COPY crontab /etc/cron.d/kvs-cron
RUN chmod 0644 /etc/cron.d/kvs-cron \
    && crontab /etc/cron.d/kvs-cron \
    && touch /var/log/cron.log

CMD ["cron", "-f"]
