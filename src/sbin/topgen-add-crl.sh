#!/bin/bash
# Add a CRL to an existing TopGen CA without re-scraping:
#  - re-signs certs (same subject, SANs, extensions and public key) with a CRL
#    distribution point and a fresh random serial, recording them in the
#    persistent CA database (topgen-ca.sh) so they can be revoked later;
#  - publishes the CRL on the topgen.info vhost.
#
# usage: topgen-add-crl.sh [CERT ...]   (default: all of $TOPGEN_VARLIB/certs/*.cer)
# env:   TOPGEN_VARLIB (default /var/lib/topgen)
#        CRL_URL       (default http://topgen.info/topgen_ca.crl)
#        DAYS          (validity of re-signed certs, default 3650)
#        CRL_DAYS      (validity of the CRL, default 3650)
set -euo pipefail

export TOPGEN_VARLIB=${TOPGEN_VARLIB:-/var/lib/topgen}
export CRL_URL=${CRL_URL:-http://topgen.info/topgen_ca.crl}
DAYS=${DAYS:-3650}

VARETC="$TOPGEN_VARLIB/etc"
SITE="$TOPGEN_VARLIB/vhosts/topgen.info"
CA_KEY="$VARETC/topgen_ca.key"
CA_CER="$VARETC/topgen_ca.cer"
CA_CHAIN="$VARETC/topgen_ca_chain.pem"

{ [ -s "$CA_KEY" ] && [ -s "$CA_CER" ]; } || { echo "missing $CA_KEY or $CA_CER" >&2; exit 1; }
[ -d "$SITE" ] || { echo "missing $SITE" >&2; exit 1; }

if [ $# -gt 0 ]; then
  CERTS=("$@")
else
  CERTS=("$TOPGEN_VARLIB"/certs/*.cer)
  BACKUP="$TOPGEN_VARLIB/certs.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$TOPGEN_VARLIB/certs" "$BACKUP"
  echo "backed up certs to $BACKUP"
fi

EXT=$(mktemp)
trap 'rm -f "$EXT" "$EXT.new"' EXIT
echo "crlDistributionPoints = URI:$CRL_URL" > "$EXT"

n=0
for CER in "${CERTS[@]}"; do
  openssl verify -partial_chain -CAfile "$CA_CER" "$CER" >/dev/null 2>&1 || {
    echo "skip (not issued by TopGen CA): $CER" >&2; continue; }
  openssl x509 -in "$CER" -CA "$CA_CER" -CAkey "$CA_KEY" -sha256 \
          -set_serial "0x$(openssl rand -hex 16)" -days "$DAYS" \
          -extfile "$EXT" -out "$EXT.new" 2>/dev/null
  [ ! -s "$CA_CHAIN" ] || cat "$CA_CHAIN" >> "$EXT.new"
  mv "$EXT.new" "$CER"
  topgen-ca.sh record "$CER"
  n=$((n + 1))
done
echo "re-signed $n cert(s)"

topgen-ca.sh gencrl
echo "wrote $SITE/topgen_ca.crl (served at $CRL_URL)"
