#!/bin/sh
set -eu
# Certbot invokes this only after renewing this site's certificate.
[ "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/tesla.ponypro.party ] || exit 0
target=/home/web/certs/tesla.ponypro.party
install -d -m 0700 "$target"
install -m 0644 "$RENEWED_LINEAGE/fullchain.pem" "$target/fullchain.pem"
install -m 0600 "$RENEWED_LINEAGE/privkey.pem" "$target/privkey.pem"
docker exec nginx nginx -t
docker exec nginx nginx -s reload
