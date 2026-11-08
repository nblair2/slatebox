#!/bin/bash
# Base OS: build-time proxy/CA, full upgrade, packages; host service units off.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

cloud-init status --wait >/dev/null || true

# Build-only proxy and CA (removed again by 90-finalize.sh).
if [ -n "${BUILD_PROXY:-}" ]; then
  echo "Acquire::https::Proxy \"$BUILD_PROXY\";" >/etc/apt/apt.conf.d/95slatebox-build-proxy
fi
if [ -s /tmp/slatebox/build-ca.crt ]; then
  cp /tmp/slatebox/build-ca.crt /usr/local/share/ca-certificates/slatebox-build.crt
  update-ca-certificates
fi

apt_get() { apt-get -y -o DPkg::Lock::Timeout=600 "$@"; }

# postfix: no debconf-generated config; topgen supplies its own.
echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections

apt_get update
apt_get full-upgrade
apt_get install \
  frr keepalived bind9 bind9-utils dns-root-data nginx postfix \
  dovecot-core dovecot-imapd tor wget rclone openssl iproute2 \
  isc-dhcp-server iodine tayga thc-ipv6 ethtool nftables tcpdump \
  traceroute curl patch psmisc procps tk libtk-img libev4t64

# In greybox these daemons run inside the CORE topgen.info node, not on the host.
for u in frr nginx named postfix dovecot tor isc-dhcp-server isc-dhcp-server6; do
  systemctl disable --now "$u.service" || true
done
