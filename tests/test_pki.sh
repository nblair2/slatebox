#!/bin/bash
# PKI test for the patched topgen-scrape.sh (-n -H, no network) and topgen-ca.sh,
# in self and external CA mode. Runs without root against temp directories.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp -r "$REPO/vendor/topgen" "$WORK/topgen"
for p in "$REPO"/patches/topgen/*.patch; do
  patch -s -p1 -d "$WORK/topgen" < "$p"
done
export PATH="$WORK/topgen/sbin:$REPO/src/sbin:$PATH"

# fixture content: 2 sites and their preset IPs (the layout of an S3 bucket)
FIX=$WORK/content
for s in www.foo.test bar.test; do
  mkdir -p "$FIX/vhosts/$s"
  echo "<h1>$s</h1>" > "$FIX/vhosts/$s/index.html"
done
printf '%s\n' "10.0.0.1 www.foo.test" "10.0.0.2 bar.test" "10.0.0.3 topgen.info" \
  > "$FIX/hosts.nginx"

FAILED=0
check() { # check DESCRIPTION COMMAND...
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "ok   $what"; else echo "FAIL $what"; FAILED=1; fi
}
# shellcheck disable=SC2329 # invoked via check
not() { ! "$@"; }

# verify CERT against $ROOT, using the intermediates in CERT and the published CRL
# shellcheck disable=SC2329
verify() {
  openssl verify -crl_check -CAfile "$ROOT" -untrusted "$1" \
          -CRLfile <(openssl crl -inform DER -in "$V/vhosts/topgen.info/topgen_ca.crl") "$1"
}

# make a throwaway external root CA and an intermediate it issues (for topgen)
make_external_ca() {
  local d=$WORK/external
  mkdir -p "$d"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/root.key" -out "$d/root.cer" \
          -days 30 -subj "/CN=External Root" 2>/dev/null
  openssl req -new -newkey rsa:2048 -nodes -keyout "$d/ca.key" -out "$d/ca.csr" \
          -subj "/CN=TopGen Intermediate" 2>/dev/null
  openssl x509 -req -in "$d/ca.csr" -CA "$d/root.cer" -CAkey "$d/root.key" \
          -set_serial 1 -days 30 -out "$d/ca.cer" -extfile <(
    echo "basicConstraints = critical, CA:true"
    echo "keyUsage = critical, keyCertSign, cRLSign"
    echo "subjectKeyIdentifier = hash"
    echo "authorityKeyIdentifier = keyid") 2>/dev/null
}

run() { # run self|external
  local mode=$1 s
  echo "== CA_MODE=$mode"
  export TOPGEN_VARLIB=$WORK/$mode
  V=$TOPGEN_VARLIB
  mkdir -p "$V/etc" "$V/certs"
  cp -r "$FIX/vhosts" "$V"

  if [ "$mode" = self ]; then
    topgen-ca.sh init
    ROOT=$V/etc/topgen_ca.cer
  else
    make_external_ca
    check "import rejects a mismatched key" \
      not topgen-ca.sh import "$WORK/external/ca.cer" "$WORK/external/root.key"
    topgen-ca.sh import "$WORK/external/ca.cer" "$WORK/external/ca.key" "$WORK/external/root.cer"
    ROOT=$WORK/external/root.cer
  fi

  topgen-scrape.sh -n -H "$FIX/hosts.nginx" -t "$V"

  local certs=("$V"/certs/*.cer) c
  check "3 vhost certs issued" test ${#certs[@]} -eq 3
  for c in "${certs[@]}"; do
    s=${c##*/}
    check "$s: CRL distribution point" \
      grep -q "URI:http://topgen.info/topgen_ca.crl" <(openssl x509 -in "$c" -noout -text)
    check "$s: EKU serverAuth" \
      grep -q "TLS Web Server Authentication" <(openssl x509 -in "$c" -noout -text)
    check "$s: verifies with CRL check" verify "$c"
  done
  check "serials unique" \
    test "$(for c in "${certs[@]}"; do openssl x509 -in "$c" -noout -serial; done |
            sort -u | wc -l)" -eq 3
  check "hosts.nginx uses preset IPs" grep -qx "10.0.0.2 bar.test" "$V/etc/hosts.nginx"
  check "nginx.conf has vhosts" grep -q "server_name www.foo.test;" "$V/etc/nginx.conf"
  check "landing page lists vhosts" grep -q '"//bar.test"' "$V/vhosts/topgen.info/index.html"
  check "CA cert published" test -s "$V/vhosts/topgen.info/topgen_ca.cer"
  if [ "$mode" = external ]; then
    check "chain appended to leaf" \
      test "$(grep -c 'BEGIN CERTIFICATE' "$V/certs/bar.test.cer")" -eq 3
    check "chain published" test -s "$V/vhosts/topgen.info/topgen_ca_chain.pem"
  fi

  topgen-ca.sh revoke "$V/certs/bar.test.cer"
  topgen-ca.sh gencrl
  check "revoked cert fails verification" not verify "$V/certs/bar.test.cer"
  check "other cert still verifies" verify "$V/certs/www.foo.test.cer"
}

run self

# retrofit: topgen-add-crl.sh gives a cert issued without a CDP one
OLD=$WORK/old.cer
openssl req -new -key "$V/etc/topgen_vh.key" -subj "/CN=old.test" \
        -addext "subjectAltName=DNS:old.test" 2>/dev/null |
  openssl x509 -req -CA "$V/etc/topgen_ca.cer" -CAkey "$V/etc/topgen_ca.key" \
          -copy_extensions copy -set_serial 10 -days 30 -out "$OLD" 2>/dev/null
# (OpenSSL < 3.2 refuses to re-sign certs that are not self-signed)
if openssl x509 -in "$OLD" -CA "$V/etc/topgen_ca.cer" -CAkey "$V/etc/topgen_ca.key" \
           -out /dev/null 2>/dev/null; then
  topgen-add-crl.sh "$OLD" >/dev/null
  check "add-crl: CRL distribution point" \
    grep -q "URI:http://topgen.info/topgen_ca.crl" <(openssl x509 -in "$OLD" -noout -text)
  check "add-crl: SAN kept" grep -q "DNS:old.test" <(openssl x509 -in "$OLD" -noout -text)
  check "add-crl: verifies with CRL check" verify "$OLD"
  topgen-ca.sh revoke "$OLD"
  topgen-ca.sh gencrl
  check "add-crl: revocable" not verify "$OLD"
else
  echo "skip add-crl: $(openssl version) cannot re-sign certs"
fi

run external

# CONTENT_SOURCE=s3 against a local S3 server (moto)
s3() {
  echo "== CONTENT_SOURCE=s3"
  unset AWS_CA_BUNDLE # (rclone can't use it with a plain-http endpoint)
  local port=$((20000 + RANDOM % 10000)) pid
  uvx -q --from 'moto[server]' moto_server -p "$port" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 60); do curl -s "http://127.0.0.1:$port/" >/dev/null && break; sleep 1; done
  export S3_ENDPOINT=http://127.0.0.1:$port S3_BUCKET=content S3_PREFIX=range1 \
         S3_ACCESS_KEY_ID=test S3_SECRET_ACCESS_KEY=test
  RCLONE_CONFIG_UP_TYPE=s3 RCLONE_CONFIG_UP_PROVIDER=Other RCLONE_CONFIG_UP_ENDPOINT=$S3_ENDPOINT \
    RCLONE_CONFIG_UP_ACCESS_KEY_ID=test RCLONE_CONFIG_UP_SECRET_ACCESS_KEY=test \
    RCLONE_CONFIG=/dev/null rclone copy "$FIX" up:content/range1

  export TOPGEN_VARLIB=$WORK/s3
  V=$TOPGEN_VARLIB
  mkdir -p "$V/etc" "$V/certs" "$V/vhosts/stale.test"
  topgen-ca.sh init
  ROOT=$V/etc/topgen_ca.cer
  CONTENT_SOURCE=s3 topgen-fetch-content.sh || FAILED=1
  kill "$pid"

  check "content synced" cmp "$FIX/vhosts/bar.test/index.html" "$V/vhosts/bar.test/index.html"
  check "stale vhost removed" test ! -e "$V/vhosts/stale.test"
  check "hosts.nginx uses preset IPs" grep -qx "10.0.0.1 www.foo.test" "$V/etc/hosts.nginx"
  check "bar.test.cer verifies with CRL check" verify "$V/certs/bar.test.cer"
}
if command -v rclone >/dev/null && command -v uvx >/dev/null; then
  s3
else
  echo "skip CONTENT_SOURCE=s3: needs rclone and uvx"
fi

if [ "$FAILED" = 0 ]; then echo PASS; else echo FAILED; exit 1; fi
