# Manticore Search image for KVS: the upstream searchd plus the hourly
# indexer and the KVS initialization wrapper.
#
# The base is pinned by digest and by release tag, instead of the `latest`
# this used to follow: a tag moves, a digest does not, so this build and the
# release CI resolve the same bytes. Refresh it with
# docker/bin/resolve-bases.sh, which rewrites docker/images.lock.
ARG MANTICORE_BASE=manticoresearch/manticore:29.9.0@sha256:461b419739a2bbbffb4be0b32db26c41d7b435bf7fd1fce95b414ca5ccbb3775
FROM ${MANTICORE_BASE}

# Install mariadb-client for indexer to access database.
# DL3008 stays muted on purpose. Pinning a Debian package version pins it to
# one snapshot of the suite, and Debian removes the old binaries as soon as a
# security update lands, so a pinned apt line stops building a few days later.
# The base image digest above is what makes this layer reproducible.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    mariadb-client \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Preserve the upstream privilege-dropping entrypoint before installing the
# KVS root-initialization wrapper.
RUN mv /usr/local/bin/docker-entrypoint.sh /usr/local/bin/manticore-entrypoint.sh

# Copy config template and the KVS initialization wrapper.
COPY manticore.conf.template /etc/manticoresearch/
COPY docker-entrypoint.sh /usr/local/bin/kvs-manticore-entrypoint.sh
RUN chmod 0755 /usr/local/bin/kvs-manticore-entrypoint.sh \
    /usr/local/bin/manticore-entrypoint.sh

# Install the hourly indexer as a valid /etc/cron.d system crontab, with its
# log and the file the output of the last hour is judged from.
COPY manticore-indexer.cron /etc/cron.d/manticore-indexer
RUN chown root:root /etc/cron.d/manticore-indexer \
    && chmod 0644 /etc/cron.d/manticore-indexer \
    && install -o manticore -g manticore -m 0640 /dev/null /var/log/manticore/indexer-cron.log \
    && install -o manticore -g manticore -m 0640 /dev/null /var/log/manticore/indexer-hourly.log

ENTRYPOINT ["/usr/local/bin/kvs-manticore-entrypoint.sh"]
CMD ["searchd", "--nodetach"]
