#!/bin/bash
# Install patched topgen + greybox and the slatebox additions (run as root).
# Used by the Packer build; also works on any Ubuntu 26.04 host that has the
# packages from packer/provision/00-base.sh and CORE (10-core.sh) installed.
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
CONFIG=/tmp/slatebox/config
[ -d "$CONFIG" ] || CONFIG=$REPO/config
VARLIB=/var/lib/topgen
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Patch copies of the vendored upstream trees.
for p in topgen greybox; do
  cp -r "$REPO/vendor/$p" "$WORK/$p"
  for f in "$REPO/patches/$p"/*.patch; do
    [ -e "$f" ] || continue
    patch -d "$WORK/$p" -p1 --forward --quiet <"$f"
  done
done
TG=$WORK/topgen
GB=$WORK/greybox

# topgen
install -m 0755 -t /usr/sbin "$TG"/sbin/*
install -m 0644 -D -t /usr/share/man/man8 "$TG"/man/*
install -d /etc/topgen
install -m 0644 -t /etc/topgen \
  "$CONFIG/scrape_sites.txt" "$CONFIG/vmail.cfg" "$CONFIG/delegations.dns"
install -d "$VARLIB"/{etc/postfix,vhosts,certs,named}
install -d -m 0700 -o dovenull -g dovenull "$VARLIB/vmail"
# runtime dirs the daemons in the topgen.info node expect
install -d -o bind -g bind /var/cache/bind/data
install -d -o postfix -g root /var/spool/postfix/private
ln -sfn "$VARLIB/etc/nginx.conf" /etc/nginx/conf.d/topgen.conf
rm -f /etc/nginx/sites-enabled/default

# named (also inside CORE nodes) must read the generated zones and config.
# (/run/named is created afresh in each CORE node's private /run.)
printf '%s\n' "$VARLIB/** r," "/run/named/ rw," >/etc/apparmor.d/local/usr.sbin.named
if aa-enabled --quiet 2>/dev/null; then
  apparmor_parser -r /etc/apparmor.d/usr.sbin.named
fi

# greybox
for d in clipart etc maps; do
  install -m 0644 -D -t "/usr/share/greybox/$d" "$GB/share/$d"/*
done
install -m 0644 "$GB/etc/profile.d_greybox.sh" /etc/profile.d/greybox.sh

# slatebox
install -m 0755 -t /usr/sbin "$REPO"/src/sbin/*
install -m 0644 -D -t /usr/share/slatebox "$REPO/src/imn2xml.py"
# FRR 10 behind CORE 9.2's frrboot.sh: the shim is found first (/usr/local/sbin),
# and with no host /etc/frr/frr.conf frrboot.sh links it to each node's own file.
install -m 0755 "$REPO/src/frr-shim" /usr/share/slatebox/frr-shim
for d in zebra staticd bgpd ospfd ospf6d ripd ripngd babeld pimd; do
  ln -sfn /usr/share/slatebox/frr-shim "/usr/local/sbin/$d"
done
rm -f /etc/frr/frr.conf /etc/frr/vtysh.conf
rm -rf /usr/share/slatebox/core_services
cp -r "$REPO/src/core_services" /usr/share/slatebox/core_services
cp -r "$REPO/src/systemd/." /usr/lib/systemd/system/
systemctl daemon-reload
