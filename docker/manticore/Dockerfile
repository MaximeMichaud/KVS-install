FROM manticoresearch/manticore:latest

# Install mariadb-client for indexer to access database
RUN apt-get update && apt-get install -y \
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

# Install the hourly indexer as a valid /etc/cron.d system crontab.
COPY manticore-indexer.cron /etc/cron.d/manticore-indexer
RUN chown root:root /etc/cron.d/manticore-indexer \
    && chmod 0644 /etc/cron.d/manticore-indexer \
    && install -o manticore -g manticore -m 0640 /dev/null /var/log/manticore/indexer-cron.log

ENTRYPOINT ["/usr/local/bin/kvs-manticore-entrypoint.sh"]
CMD ["searchd", "--nodetach"]
