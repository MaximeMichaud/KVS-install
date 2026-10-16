#!/bin/sh
# Run after the official template-rendering hooks and before Nginx starts.
set -e
[ "${CLOUDFLARE_ENABLED:-false}" = true ] || exit 0
cloudflare_config=/run/kvs-nginx/cloudflare-realip.conf

# Capture the expanded configuration rather than logging its contents.
# Nginx names the conflicting file if manual Real IP directives remain.
if ! cloudflare_expanded=$(nginx -T); then
    echo "ERROR: Cloudflare configuration is invalid; check existing manual Real IP directives before enabling CLOUDFLARE_ENABLED" >&2
    exit 1
fi
if ! printf '%s\n' "$cloudflare_expanded" | grep -Fxq "# configuration file ${cloudflare_config}:"; then
    echo "ERROR: nginx.conf does not load the generated Cloudflare configuration; update the Nginx image and configuration together" >&2
    exit 1
fi
echo "Cloudflare visitor IP restoration enabled"
