FROM debian:bookworm-slim

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    unzip \
    curl \
    php-cli \
    default-mysql-client \
    ca-certificates \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Copy modular init structure
COPY lib/ /init/lib/
COPY docker-entrypoint.d/ /init/docker-entrypoint.d/
COPY init-kvs.sh /init-kvs.sh

# Make all scripts executable
RUN chmod +x /init-kvs.sh /init/lib/*.sh /init/docker-entrypoint.d/*.sh

ENTRYPOINT ["/init-kvs.sh"]
