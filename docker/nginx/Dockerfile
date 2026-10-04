FROM nginx:mainline

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /custom-entrypoint.sh
COPY rotate-site-logs.sh /usr/local/bin/rotate-site-logs
RUN chmod +x /custom-entrypoint.sh /usr/local/bin/rotate-site-logs

ENTRYPOINT ["/custom-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
