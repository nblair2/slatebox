#!/bin/bash
# Root CA: generate one (self) or import the one provided (external).
set -euo pipefail
case "$CA_MODE" in
  self) topgen-ca.sh init ;;
  external)
    cd /tmp/slatebox/ca
    if [ -s chain.pem ]; then
      topgen-ca.sh import ca.cer ca.key chain.pem
    else
      topgen-ca.sh import ca.cer ca.key
    fi
    ;;
  *) echo "unknown CA_MODE '$CA_MODE'" >&2; exit 1 ;;
esac
