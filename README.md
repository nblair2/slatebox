# slatebox

A single-host Internet simulator packaged as one qcow2 VM image, built with Packer on Ubuntu 26.04.

Inside the image, [CORE](https://github.com/coreemu/core) 9.2.1 runs the greybox backbone map:
69 FRR routers speaking BGP, plus client hosts. One node, `topgen.info`, runs the topgen services:
web (nginx serving sites mirrored at build time), DNS (bind9 root, TLD and caching servers,
reachable as 8.8.8.8) and mail (postfix and dovecot). One RJ45 node connects the map to a NIC of
the VM, so outside machines can join the simulated Internet.

## Provenance

greybox and topgen are CMU-SEI projects, Copyright 2016 Carnegie Mellon University, BSD-licensed
with a US Government Purpose Rights notice (`LICENSE.greybox`, `LICENSE.topgen`). The files derived
from them were taken from these upstream commits and adapted for Ubuntu, CORE 9 and FRR 10:

- [topgen](https://github.com/cmu-sei/topgen) `e0ab5441a860a98fce4a49c249fe9b61a0e56747`:
  `topgen-mkdns.sh`, `topgen-vmail.sh`, `vmail.cfg`, `delegations.dns`, and the landing page in
  `topgen-scrape.sh`.
- [greybox](https://github.com/cmu-sei/greybox) `e89c3754491db97599db073bbeb18fc7b20a7240`:
  `backbone.hosts`, `keepalived.conf`, `topgen-boot` (the map's `TopGenBoot.sh`) and the map.
  `files/etc/greybox/map.xml` was converted once to CORE XML from `share/maps/backbone_ext.imn`
  and is now maintained by hand.

`greybox-ctl`, `frr-shim`, the CORE `UserDefined` service, `topgen-ca.sh` and the rest of
`topgen-scrape.sh` are slatebox's own. Everything that goes into the image lives under `files/`, at its installed path.

## Repository layout

| Path | Contents |
|---|---|
| `slatebox.pkr.hcl`, `variables.pkr.hcl` | Packer build |
| `scripts/provision.sh` | Runs as root in the build VM: packages, CORE, overlay, content, checks |
| `files/` | Copied onto the image's `/` |
| `tests/smoke.sh` | Boots the image and checks it end to end |
| `.github/workflows/build.yml` | CI |

## How CI builds it

On every push (and on manual dispatch), `.github/workflows/build.yml` runs two jobs:

1. **lint**: `packer fmt` and `packer validate`, shellcheck, `xmllint` on the map, and a Python
   syntax check of `greybox-ctl` and the CORE service.
2. **build**: enables KVM on the runner, runs `packer build`, then `tests/smoke.sh` on the image.
   The smoke test boots the image with a second NIC on a tap device, waits for the map to start,
   and checks routing, DNS, HTTPS with the TopGen CA, the CRL, mail, and a DHCP lease from
   outside. On success the image is uploaded as the `slatebox-qcow2` artifact (kept 3 days); on
   failure the Packer log, serial console logs and smoke diagnostics are uploaded instead.

A build takes about two hours, most of it the site scrape.

## Building locally

You need Packer 1.10 or later, `qemu-system-x86`, `qemu-utils`, `xorriso` and a working
`/dev/kvm`. The smoke test also needs `sshpass`, `busybox`, `dig` and sudo.

```sh
packer init .
packer build .                                  # -> build/image/slatebox.qcow2
packer build -var 'scrape_sites=["https://example.com"]' -var scrape_depth=1 .
tests/smoke.sh build/image/slatebox.qcow2
```

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `ubuntu_image_url`, `ubuntu_image_checksum` | resolute cloud image, `file:` SHA256SUMS | Base image |
| `cpus`, `memory` | `4`, `8192` | Build VM size (MiB) |
| `disk_size` | `40G` | Virtual disk size; the qcow2 is sparse and compressed |
| `output_dir` | `build/image` | Receives `slatebox.qcow2` |
| `admin_password` | `slatebox` | Password of the `slatebox` login user |
| `ext_iface` | `ens4` | NIC given to the map's RJ45 node |
| `scrape_sites` | `["https://www.cmu.edu"]` | Sites mirrored into the image (`http://` or `https://`) |
| `scrape_depth` | `3` | Link depth per site |
| `scrape_timeout` | `60m` | Time limit per site; a partial mirror is kept |

CORE, uv, Python and goscrape versions are pinned in `scripts/provision.sh`.

## External interface

The RJ45 node is attached to `iap1-rtr.disa.mil`, which owns `12.0.0.0/24`:

- router address `12.0.0.41`;
- DHCP on that router hands out `12.0.0.100` to `12.0.0.250`, with `12.0.0.41` as gateway and
  `8.8.8.8` as DNS server.

Connect machines to the VM's `ext_iface` NIC (the second NIC, `ens4`, on a typical KVM setup) and
they get an address and reach the simulated Internet. The host itself does not configure that
NIC. If the NIC is missing at boot, `greybox-ctl` creates a dummy interface with that name so the
map still starts.

To use a different NIC on a built image, change the name in both
`/etc/default/greybox` (`GREYBOX_EXT_IFACE=`) and `/etc/systemd/network/10-greybox-ext.network`
(`Name=`), then reboot.

## Using the image

Log in as `slatebox` with `admin_password`, on the console or with SSH (password logins are
enabled). The user has sudo. The first NIC gets its address by DHCP. cloud-init is still
installed, so a NoCloud seed (`cidata`) can add SSH keys or users.

At boot, `greybox.service` starts the map from `/etc/greybox/map.xml`; with 69 routers this takes
a few minutes, and BGP needs a few more to converge.

```sh
greybox-ctl status
greybox-ctl exec CharlieUser1 traceroute -n www.cmu.edu
greybox-ctl exec CharlieUser1 curl --cacert /var/lib/topgen/etc/topgen_ca.cer https://www.cmu.edu/
sudo systemctl restart greybox
```

The host's `/etc/resolv.conf` is `nameserver 8.8.8.8`, the simulated resolver, as greybox
recommends; CORE nodes share it. The host's own `frr`, `nginx`, `named`, `postfix`, `dovecot`,
`keepalived` and `isc-dhcp-server` units are disabled, because these daemons run inside nodes.
`https://topgen.info/` lists the mirrored sites.

## CA and CRL

The build generates a root CA (`/C=US/ST=PA/L=Pgh/O=CMU/OU=CERT/CN=topgen_ca`, 20 years) in
`/var/lib/topgen/etc/` (`topgen_ca.cer`, `topgen_ca.key`, database in `ca/`). Every vhost and mail
server certificate is issued by it, with a random serial, `extendedKeyUsage=serverAuth` and a CRL
distribution point of `http://topgen.info/topgen_ca.crl`. Clients in the simulation must trust
`topgen_ca.cer`; it is also served at `https://topgen.info/topgen_ca.cer`.

The CRL is written in DER to `/var/lib/topgen/vhosts/topgen.info/topgen_ca.crl`. Manage
certificates with:

```sh
sudo topgen-ca.sh issue KEY CERT NAME...
sudo topgen-ca.sh revoke CERT
sudo topgen-ca.sh gencrl
```
