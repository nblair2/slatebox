#!/bin/bash
# Last step: in-game DNS, drop build-only settings, make the image generic.
set -euo pipefail

# greybox README: the host (and every CORE node) resolves via 8.8.8.8, which
# lives inside the simulated Internet. Done last; earlier steps need real DNS.
systemctl disable --now systemd-resolved.service
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" >/etc/resolv.conf
grep -qw "$(hostname)" /etc/hosts || echo "127.0.1.1 $(hostname)" >>/etc/hosts

# Build-only proxy and CA.
rm -f /etc/apt/apt.conf.d/95slatebox-build-proxy \
      /usr/local/share/ca-certificates/slatebox-build.crt
update-ca-certificates --fresh >/dev/null

# The login user keeps its password but sudo asks for it from now on.
rm -f /etc/sudoers.d/90-cloud-init-users

# Regenerate SSH host keys on first boot even if cloud-init has no seed.
cat >/etc/systemd/system/slatebox-ssh-keygen.service <<'UNIT'
[Unit]
Description=Generate missing SSH host keys
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=ssh.service
UNIT
systemctl enable slatebox-ssh-keygen.service
rm -f /etc/ssh/ssh_host_*

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/slatebox
cloud-init clean --logs --machine-id
