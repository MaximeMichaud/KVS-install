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

COPY init-kvs.sh /init-kvs.sh
RUN chmod +x /init-kvs.sh

ENTRYPOINT ["/init-kvs.sh"]
