#!/bin/bash
# Turns the Ubuntu cloud image into slatebox. Run by Packer as root, with the
# repo's files/ uploaded to /tmp/files. Cheap failures come before the scrape.
set -euo pipefail
export PS4='+ provision.sh:${LINENO}: '
set -x
trap 'echo "provision.sh: FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
: "${EXT_IFACE:?}" "${SCRAPE_SITES:?}" "${SCRAPE_DEPTH:?}" "${SCRAPE_TIMEOUT:?}"

CORE_VERSION=9.2.1
UV_VERSION=0.11.32
GOSCRAPE_VERSION=v0.3.0
GOSCRAPE_SHA256=599c6fc834b8fa7f8ec5b089f4943bd5e6b5d8def188a13349d011f867dda088
V=/var/lib/topgen
tmp=$(mktemp -d)

: "== 1. wait for cloud-init"
cloud-init status --wait || true

: "== 2. packages"
aptget() { apt-get -y -o DPkg::Lock::Timeout=600 "$@"; }
# "Local only" makes the package create /etc/aliases(.db), which topgen's main.cf uses
debconf-set-selections <<EOF
postfix postfix/main_mailer_type select Local only
postfix postfix/mailname string slatebox.topgen.info
EOF
aptget update
aptget full-upgrade
aptget install frr keepalived bind9 bind9-utils bind9-dnsutils dns-root-data \
  nginx postfix dovecot-core dovecot-imapd isc-dhcp-server openssl iproute2 \
  traceroute tcpdump curl psmisc libev4t64

: "== 3. host units off: these daemons run inside CORE nodes"
# networkd-dispatcher would run once per each of the map's ~800 interfaces
for u in frr nginx named postfix dovecot isc-dhcp-server isc-dhcp-server6 \
  keepalived networkd-dispatcher; do
  systemctl disable --now "$u.service" || true
done

: "== 4. CORE"
curl -fsSL -o "$tmp/core.deb" \
  "https://github.com/coreemu/core/releases/download/release-$CORE_VERSION/core_${CORE_VERSION}_amd64.deb"
# skip the deb's pip step: the distro Python is too new for CORE's pins
NO_PYTHON=1 aptget install "$tmp/core.deb"
curl -fsSL "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz" |
  tar -xz -C "$tmp" --strip-components=1
export UV_PYTHON_INSTALL_DIR=/opt/core/python UV_PYTHON_BIN_DIR=$tmp/bin \
  UV_CACHE_DIR=$tmp/cache UV_LINK_MODE=copy
"$tmp/uv" python install 3.12
"$tmp/uv" venv --python 3.12 /opt/core/venv
"$tmp/uv" pip install --python /opt/core/venv/bin/python /opt/core/core-"$CORE_VERSION"-*.whl
# the rest of the deb's postinst, which NO_PYTHON skipped
sed -i 's|[$]DAEMON|/opt/core/venv/bin/core-daemon|' /usr/lib/systemd/system/core-daemon.service
ln -sf /opt/core/venv/bin/core-* /usr/bin/
sed -i 's|^#\?custom_services_dir *=.*|custom_services_dir = /usr/local/share/slatebox/core_services|' /opt/core/etc/core.conf
grep -qx 'custom_services_dir = /usr/local/share/slatebox/core_services' /opt/core/etc/core.conf
/opt/core/venv/bin/python -c 'import core, grpc'

: "== 5. goscrape"
curl -fsSL -o "$tmp/goscrape.tgz" \
  "https://github.com/cornelk/goscrape/releases/download/$GOSCRAPE_VERSION/goscrape_${GOSCRAPE_VERSION}_linux_64bit.tar.gz"
echo "$GOSCRAPE_SHA256  $tmp/goscrape.tgz" | sha256sum -c
tar -xzf "$tmp/goscrape.tgz" -C "$tmp" goscrape
install -m 0755 "$tmp/goscrape" /usr/local/bin/

: "== 6. overlay and glue"
cp -rT --no-preserve=mode /tmp/files /
chmod 0755 /usr/local/sbin/*
# FRR 10 behind CORE 9.2's frrboot.sh: the shim is found first in
# /usr/local/sbin; without a host frr.conf, frrboot.sh uses each node's own
for d in zebra staticd bgpd ospfd ospf6d ripd ripngd babeld pimd; do
  ln -sfn /usr/local/sbin/frr-shim "/usr/local/sbin/$d"
done
rm -f /etc/frr/frr.conf /etc/frr/vtysh.conf
install -d $V/{etc/postfix,vhosts,certs,named}
install -d -m 0700 -o dovenull -g dovenull $V/vmail
install -d -o bind -g bind /var/cache/bind/data
install -d -o postfix -g root /var/spool/postfix/private
ln -sfn $V/etc/nginx.conf /etc/nginx/conf.d/topgen.conf
rm -f /etc/nginx/sites-enabled/default
# named in CORE nodes reads topgen's files and creates /run/named in its private /run
printf '%s\n' "$V/** r," '/run/named/ rw,' >/etc/apparmor.d/local/usr.sbin.named
if aa-enabled --quiet; then apparmor_parser -r /etc/apparmor.d/usr.sbin.named; fi
echo "GREYBOX_EXT_IFACE=$EXT_IFACE" >/etc/default/greybox
systemctl daemon-reload
systemctl enable core-daemon.service greybox.service

: "== 7. content"
read -ra sites <<<"$SCRAPE_SITES"
topgen-ca.sh init
topgen-scrape.sh "$SCRAPE_DEPTH" "$SCRAPE_TIMEOUT" "${sites[@]}"
topgen-vmail.sh -f
topgen-mkdns.sh -f -x /etc/greybox/backbone.hosts
topgen-ca.sh gencrl

: "== 8. build-time checks"
nginx -t
named-checkconf $V/etc/named.conf
postfix -c $V/etc/postfix check
doveconf -c $V/etc/postfix/dovecot.conf -n >/dev/null
openssl verify -CAfile $V/etc/topgen_ca.cer $V/certs/*.cer
openssl crl -inform DER -noout -in $V/vhosts/topgen.info/topgen_ca.crl
cat $V/etc/hosts.nginx

: "== 9. finalize"
# The stale netplan pins the build NIC's MAC; networkd files match by name and
# keep the host off the external NIC (greybox's RJ45 node owns it)
rm -f /etc/netplan/50-cloud-init.yaml
printf '[Match]\nName=%s\n\n[Link]\nUnmanaged=yes\n' "$EXT_IFACE" \
  >/etc/systemd/network/10-greybox-ext.network
printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n' \
  >/etc/systemd/network/20-slatebox.network
# sudo now asks for the password
rm -f /etc/sudoers.d/90-cloud-init-users
# sorts before the cloud image's 60- "no"; a user's cloud-init seed still wins
echo 'PasswordAuthentication yes' >/etc/ssh/sshd_config.d/55-slatebox.conf
rm -f /etc/ssh/ssh_host_*
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/files "$tmp"
cloud-init clean --logs --machine-id
# Last: the host and all CORE nodes resolve via 8.8.8.8 inside the sim (greybox
# README). A static file replaces the resolved stub; resolved keeps running.
rm -f /etc/resolv.conf
echo 'nameserver 8.8.8.8' >/etc/resolv.conf
grep -qw "$(hostname)" /etc/hosts || echo "127.0.1.1 $(hostname)" >>/etc/hosts
fstrim -av || true
