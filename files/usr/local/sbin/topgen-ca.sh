#!/bin/bash
# TopGen CA with a persistent database, so that issued certs can be revoked
# and published in a CRL on the topgen.info vhost.
set -euo pipefail

USAGE="usage: topgen-ca.sh init                     self-generate the CA (unless present)
       topgen-ca.sh issue KEY CERT NAME...   issue a server cert (KEY made if missing)
       topgen-ca.sh revoke CERT
       topgen-ca.sh gencrl                   write the DER CRL to the topgen.info vhost
env:   TOPGEN_VARLIB (/var/lib/topgen), CA_SUBJECT, CA_DAYS (7300),
       CRL_URL (http://topgen.info/topgen_ca.crl), CRL_DAYS (3650)"

TOPGEN_VARLIB=${TOPGEN_VARLIB:-/var/lib/topgen}
CA_SUBJECT=${CA_SUBJECT:-/C=US/ST=PA/L=Pgh/O=CMU/OU=CERT/CN=topgen_ca}
CA_DAYS=${CA_DAYS:-7300}
CRL_URL=${CRL_URL:-http://topgen.info/topgen_ca.crl}
CRL_DAYS=${CRL_DAYS:-3650}

ETC=$TOPGEN_VARLIB/etc
DB=$ETC/ca
CA_KEY=$ETC/topgen_ca.key
CA_CER=$ETC/topgen_ca.cer
CRL=$TOPGEN_VARLIB/vhosts/topgen.info/topgen_ca.crl

die() { echo "topgen-ca.sh: $*" >&2; exit 1; }

# run "openssl ca" against the persistent database (quiet unless it fails)
ca() {
  { [ -s "$CA_KEY" ] && [ -s "$CA_CER" ]; } || die "missing $CA_KEY or $CA_CER"
  mkdir -p "$DB/newcerts"
  touch "$DB/index"
  [ -s "$DB/crlnumber" ] || echo 01 > "$DB/crlnumber"
  local log
  log=$(openssl ca -batch -notext -config <(cat <<EOF
[ ca ]
default_ca = topgen_ca

[ topgen_ca ]
private_key = $CA_KEY
certificate = $CA_CER
database = $DB/index
new_certs_dir = $DB/newcerts
crlnumber = $DB/crlnumber
rand_serial = yes
default_days = 3650
default_crl_days = $CRL_DAYS
default_md = sha256
unique_subject = no
copy_extensions = copy
policy = policy_any
x509_extensions = leaf_ext
crl_extensions = crl_ext

[ policy_any ]
countryName = optional
stateOrProvinceName = optional
localityName = optional
organizationName = optional
organizationalUnitName = optional
commonName = supplied

[ leaf_ext ]
basicConstraints = CA:false
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
extendedKeyUsage = serverAuth
crlDistributionPoints = URI:$CRL_URL

[ crl_ext ]
authorityKeyIdentifier = keyid:always
EOF
) "$@" 2>&1) || die "openssl ca $*: $log"
}

init() {
  # a CA supplied beforehand (e.g. by overlay_dir) is kept
  [ -s "$CA_KEY" ] && [ -s "$CA_CER" ] && { chmod 600 "$CA_KEY"; return; }
  mkdir -p "$ETC"
  openssl req -x509 -newkey rsa:4096 -nodes -keyout "$CA_KEY" -out "$CA_CER" \
          -days "$CA_DAYS" -subj "$CA_SUBJECT" \
          -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
  chmod 600 "$CA_KEY"
}

issue() {
  local key=$1 cer=$2 cn=$3 san
  shift 2
  [ -s "$key" ] || (umask 077; openssl genrsa -out "$key" 2048 2>/dev/null)
  [ ${#cn} -le 64 ] || cn=topgen_vh # CN length limit; the SAN has the name
  san=$(printf 'DNS:%s,' "$@")
  ca -out "$cer" -in <(openssl req -new -key "$key" -addext "subjectAltName=${san%,}" \
                               -subj "/C=US/ST=PA/L=Pgh/O=CMU/OU=CERT/CN=$cn")
}

gencrl() {
  ca -gencrl -out "$DB/crl.pem"
  mkdir -p "${CRL%/*}"
  openssl crl -in "$DB/crl.pem" -outform DER -out "$CRL"
}

usage() { echo "$USAGE" >&2; exit 2; }

case ${1:-} in
  init)   init ;;
  issue)  [ $# -ge 4 ] || usage; shift; issue "$@" ;;
  revoke) [ $# -eq 2 ] || usage; ca -revoke "$2" ;;
  gencrl) gencrl ;;
  *) usage ;;
esac
