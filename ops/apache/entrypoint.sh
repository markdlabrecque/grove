#!/bin/sh
# Renders the Apache config templates with TAILSCALE_HOSTNAME from the
# environment, then hands off to httpd-foreground.
#
# Templates live read-only at /etc/apache-templates/. The rendered output is
# written into the container's writable layer at the paths httpd expects.

set -e

: "${TAILSCALE_HOSTNAME:?TAILSCALE_HOSTNAME must be set in .env}"

mkdir -p /usr/local/apache2/conf/extra

sed "s|@@TAILSCALE_HOSTNAME@@|${TAILSCALE_HOSTNAME}|g" \
  /etc/apache-templates/httpd.conf.template \
  > /usr/local/apache2/conf/httpd.conf

sed "s|@@TAILSCALE_HOSTNAME@@|${TAILSCALE_HOSTNAME}|g" \
  /etc/apache-templates/oracle.conf.template \
  > /usr/local/apache2/conf/extra/oracle.conf

exec "$@"
