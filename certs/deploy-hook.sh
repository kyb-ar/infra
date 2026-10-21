#!/bin/sh
# Installs a certificate for Envoy. Run by certbot inside its container (see ./renew) whenever
# a certificate is issued or renewed, with:
#   RENEWED_LINEAGE  /etc/letsencrypt/live/<cert name>
#   ENVOY_UID        the uid Envoy runs as, so only Envoy can read the private key
# ../envoy/certs is mounted at /envoy-certs.
set -eu

d="/envoy-certs/$(basename "$RENEWED_LINEAGE")"
mkdir -p "$d"
cp "$RENEWED_LINEAGE/fullchain.pem" "$RENEWED_LINEAGE/privkey.pem" "$d/"
chown -R "$ENVOY_UID:$ENVOY_UID" "$d"
chmod 755 "$d"
chmod 644 "$d/fullchain.pem"
chmod 600 "$d/privkey.pem"
# Tells ./renew (outside the container) that Envoy needs a reload.
touch /envoy-certs/.renewed
echo "Installed $d for Envoy"
