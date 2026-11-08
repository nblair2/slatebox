#!/bin/bash
# Fill $TOPGEN_VARLIB/vhosts with web content, then let topgen-scrape.sh issue
# the certs and write nginx.conf and hosts.nginx for it.
#
#   CONTENT_SOURCE=scrape  scrape the sites in $SCRAPE_SITES
#   CONTENT_SOURCE=s3      copy s3://$S3_BUCKET/$S3_PREFIX/vhosts/<fqdn>/... and the
#                          optional $S3_PREFIX/hosts.nginx ("<ip> <fqdn>" lines)
#
# env: TOPGEN_VARLIB (/var/lib/topgen), SCRAPE_SITES (/etc/topgen/scrape_sites.txt),
#      S3_ENDPOINT S3_BUCKET S3_PREFIX S3_REGION S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
set -euo pipefail

TOPGEN_VARLIB=${TOPGEN_VARLIB:-/var/lib/topgen}

case ${CONTENT_SOURCE:-scrape} in
scrape)
  exec topgen-scrape.sh -s "${SCRAPE_SITES:-/etc/topgen/scrape_sites.txt}" -t "$TOPGEN_VARLIB"
  ;;
s3)
  # an rclone remote named "s3", configured from the environment only
  export RCLONE_CONFIG=/dev/null RCLONE_CONFIG_S3_TYPE=s3 RCLONE_CONFIG_S3_PROVIDER=Other \
         RCLONE_CONFIG_S3_ENDPOINT="$S3_ENDPOINT" \
         RCLONE_CONFIG_S3_REGION="${S3_REGION:-us-east-1}" \
         RCLONE_CONFIG_S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-}" \
         RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}" \
         RCLONE_CONFIG_S3_FORCE_PATH_STYLE=true
  SRC="s3:$S3_BUCKET/${S3_PREFIX:+${S3_PREFIX%/}/}"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  rclone sync "${SRC}vhosts" "$TOPGEN_VARLIB/vhosts"
  rclone copy --max-depth 1 --include /hosts.nginx "$SRC" "$TMP"
  if [ -s "$TMP/hosts.nginx" ]; then
    topgen-scrape.sh -n -H "$TMP/hosts.nginx" -t "$TOPGEN_VARLIB"
  else
    topgen-scrape.sh -n -t "$TOPGEN_VARLIB"
  fi
  ;;
*)
  echo "topgen-fetch-content.sh: unknown CONTENT_SOURCE=$CONTENT_SOURCE" >&2
  exit 1
  ;;
esac
