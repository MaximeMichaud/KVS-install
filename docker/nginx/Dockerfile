# nginx image for KVS.
#
# The base is pinned by digest: a tag moves, a digest does not, so this build
# and the release CI resolve the same bytes. Refresh it with
# docker/bin/resolve-bases.sh, which rewrites docker/images.lock.
ARG NGINX_BASE=nginx:mainline@sha256:8632b3314d74c61f0e27f59055bab13f7793b988c94c090154d867bc29e0f39b
FROM ${NGINX_BASE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# DL3008 stays muted on purpose. Pinning a Debian package version pins it to
# one snapshot of the suite, and Debian removes the old binaries as soon as a
# security update lands, so a pinned apt line stops building a few days later.
# The base image digest above is what makes this layer reproducible.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /custom-entrypoint.sh
COPY cloudflare-realip-check.sh /docker-entrypoint.d/40-kvs-cloudflare.sh
COPY rotate-site-logs.sh /usr/local/bin/rotate-site-logs
RUN chmod +x /custom-entrypoint.sh /usr/local/bin/rotate-site-logs \
    /docker-entrypoint.d/40-kvs-cloudflare.sh

ENTRYPOINT ["/custom-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
