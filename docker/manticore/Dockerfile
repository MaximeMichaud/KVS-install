FROM manticoresearch/manticore:latest

# Install mariadb-client for indexer to access database
RUN apt-get update && apt-get install -y \
    mariadb-client \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Copy config template and entrypoint
COPY manticore.conf.template /etc/manticoresearch/
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Setup cron for hourly indexing
RUN echo "0 * * * * indexer --rotate --all >> /var/log/manticore/indexer-cron.log 2>&1" > /etc/cron.d/manticore-indexer && \
    chmod 0644 /etc/cron.d/manticore-indexer

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["searchd", "--nodetach"]
