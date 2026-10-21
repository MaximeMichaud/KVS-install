# One-shot init image: it unpacks the KVS archive, imports the database and
# configures the site, then exits.
#
# The base is pinned by digest: a tag moves, a digest does not, so this build
# and the release CI resolve the same bytes. Refresh it with
# docker/bin/resolve-bases.sh, which rewrites docker/images.lock.
ARG DEBIAN_BASE=debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
FROM ${DEBIAN_BASE}

# DL3008 stays muted on purpose. Pinning a Debian package version pins it to
# one snapshot of the suite, and Debian removes the old binaries as soon as a
# security update lands, so a pinned apt line stops building a few days later.
# The base image digest above is what makes this layer reproducible.
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
