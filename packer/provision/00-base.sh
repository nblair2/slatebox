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

# postfix: "Local only" so the package creates /etc/aliases(.db), which the
# topgen main.cf still uses; the host's own postfix is disabled below.
debconf-set-selections <<EOT
postfix postfix/main_mailer_type select Local only
postfix postfix/mailname string slatebox.topgen.info
EOT

apt_get update
apt_get full-upgrade
apt_get install \
  frr keepalived bind9 bind9-utils dns-root-data nginx postfix \
  dovecot-core dovecot-imapd tor wget rclone openssl iproute2 \
  isc-dhcp-server iodine tayga thc-ipv6 ethtool nftables tcpdump \
  traceroute curl patch psmisc procps tk libtk-img libev4t64

# In greybox these daemons run inside CORE nodes, not on the host.
# (networkd-dispatcher would re-run on each of the map's ~800 interfaces.)
for u in frr nginx named postfix dovecot tor isc-dhcp-server isc-dhcp-server6 tayga iodined networkd-dispatcher; do
  systemctl disable --now "$u.service" || true
done
