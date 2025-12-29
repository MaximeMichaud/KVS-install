ARG PHP_VERSION=8.1
FROM php:${PHP_VERSION}-fpm

ARG IONCUBE=YES
ARG PHP_VERSION

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

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
    libavif-dev \
    libaom-dev \
    ffmpeg \
    unzip \
    curl \
    wget \
    ca-certificates \
    fonts-dejavu-core \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/ffmpeg /usr/local/bin/ffmpeg \
    && ln -s /usr/bin/convert /usr/local/bin/convert \
    && ln -s /usr/bin/wget /usr/local/bin/wget

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
RUN pecl install memcached imagick \
    && docker-php-ext-enable memcached imagick

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
