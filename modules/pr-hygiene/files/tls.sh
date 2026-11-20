#!/bin/bash
# Obtains the service's certificate from Let's Encrypt if the data volume
# does not already hold one, then turns on the HTTPS side of nginx.
#
# Run by pr-hygiene-tls.service, which retries every 15 minutes until this
# succeeds: on a new host the DNS record and the Elastic IP may arrive a
# little after the first boot.
#
# Asking for a certificate accepts the Let's Encrypt Subscriber Agreement
# (--agree-tos) on behalf of whoever applied this configuration. No contact
# address is registered; renewal runs from certbot's own timer.
set -euo pipefail

. /etc/pr-hygiene/host.env

live="/etc/letsencrypt/live/$PRH_HOSTNAME"
if [ ! -s "$live/fullchain.pem" ]; then
  certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
    --webroot -w /var/www/acme -d "$PRH_HOSTNAME" \
    --deploy-hook 'systemctl reload nginx'
fi

install -m 0644 /etc/pr-hygiene/nginx-tls.conf /etc/nginx/conf.d/pr-hygiene-tls.conf
if ! nginx -t; then
  rm -f /etc/nginx/conf.d/pr-hygiene-tls.conf
  exit 1
fi
systemctl reload nginx
