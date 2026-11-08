# slatebox

A single-host Internet simulator in one VM image. It combines two CMU-SEI projects:

- **[greybox](https://github.com/cmu-sei/greybox)**: a [CORE](https://github.com/coreemu/core)
  map of 69 FRR BGP backbone routers plus client nodes.
- **[topgen](https://github.com/cmu-sei/topgen)**: fake web (nginx), DNS (bind9: root, TLD and
  caching servers) and mail (postfix and dovecot) services. They run in the map's `topgen.info` node.

Upstream targets Fedora and CORE 8 or earlier. slatebox keeps the upstream code as it is under
`vendor/` and adds small patches. It runs on **Ubuntu 26.04** with **CORE 9.2.1**, and Packer builds
it into a **qcow2** image. It also adds:

- a CRL;
- web content scraped at build time or pulled from S3;
- a root CA that is either generated during the build or supplied by you.

topgen and greybox are Copyright 2016 Carnegie Mellon University. They are BSD-licensed, with a
US Government Purpose Rights notice; see `vendor/*/LICENSE` and `vendor/*/LICENSE.US_GOV`.
`vendor/UPSTREAM.md` gives the pinned upstream commits.

## Quick start

You need `packer` (1.10 or later), `qemu-system-x86`, `qemu-utils` and `xorriso`.
`/dev/kvm` is strongly recommended.

```sh
cp packer/example.pkrvars.hcl packer/my.pkrvars.hcl   # edit as needed
make image VARS=packer/my.pkrvars.hcl                 # -> build/image/slatebox.qcow2
ACCEL=kvm tests/smoke.sh build/image/slatebox.qcow2   # optional end-to-end check
make test                                             # shellcheck, PKI test, converter tests
```

The build boots the Ubuntu cloud image and runs the scripts in `packer/provision/` in order:

| Script | What it does |
|---|---|
| `00-base.sh` | Installs the packages. |
| `10-core.sh` | Installs CORE in `/opt/core/venv`. |
| `20-install.sh` | Runs `install.sh`. |
| `30-pki.sh` | Creates or imports the CA. |
| `40-content.sh` | Fetches the web content. |
| `50-topgen-config.sh` | Generates the mail and DNS configuration. |
| `60-greybox.sh` | Converts the map to CORE XML. |
| `90-finalize.sh` | Cleans up the image. |

`install.sh` also works on its own, on any Ubuntu 26.04 host that has the packages from `00-base.sh`
and CORE installed.

## Variables

Every variable has a default; see `packer/variables.pkr.hcl`. Relative paths are resolved from `packer/`.

| Variable | Default | Meaning |
|---|---|---|
| `accelerator` | `kvm` | `tcg` if there is no KVM. It works, but is very slow. |
| `cpus`, `memory`, `disk_size` | `4`, `8192`, `20G` | Build VM and image size. |
| `ubuntu_image_url`, `ubuntu_image_checksum` | resolute cloud image, `file:` SHA256SUMS | Base image. |
| `output_dir`, `vm_name` | `../build/image`, `slatebox` | Output is `<output_dir>/<vm_name>.qcow2`. |
| `admin_password` | `slatebox` | Password of the `slatebox` login user. |
| `core_version` | `9.2.1` | CORE release `.deb`. |
| `map` | `backbone` | `vendor/greybox/share/maps/<map>.imn`. |
| `rj45_ifaces` | `""` | Maps RJ45 nodes to host NICs, e.g. `ethX=ens4` (for `backbone_ext`). |
| `content_source` | `scrape` | `scrape` or `s3`. |
| `scrape_sites_file` | `../config/scrape_sites.txt` | One `URL [DEPTH]` per line. |
| `vmail_cfg_file`, `delegations_file` | `../config/vmail.cfg`, `../config/delegations.dns` | topgen mail domains and DNS delegations. |
| `s3_endpoint`, `s3_bucket`, `s3_prefix`, `s3_region` | | S3 source. |
| `s3_access_key_id`, `s3_secret_access_key` | | Sensitive. Can be set as `PKR_VAR_…` in the environment. |
| `ca_mode` | `self` | `self` or `external`. |
| `ca_subject`, `ca_days` | `/C=US/…/CN=topgen_ca`, `7300` | Used in self mode. |
| `ca_cert_file`, `ca_key_file`, `ca_chain_file` | | Used in external mode. The chain is optional. |
| `crl_url`, `crl_days` | `http://topgen.info/topgen_ca.crl`, `3650` | CRL distribution point and lifetime. |
| `build_proxy`, `build_ca_file` | | HTTPS proxy and extra CA, used only during the build. |

## CA modes

- **`self`**: the build generates a root CA (`topgen-ca.sh init`).
- **`external`**: you provide a CA certificate and key, and optionally a chain up to your own root.
  `topgen-ca.sh import` checks that the key matches the certificate and that the chain verifies.
  The chain is appended to every leaf certificate.

  Clients may also check the CA certificate against your root's CRL distribution point, so that URL
  must be reachable inside the simulation.

Either way, the CA and its database are in `/var/lib/topgen/etc/` (`topgen_ca.cer`, `ca/`). Leaf
certificates get random serials, `extendedKeyUsage=serverAuth` and a CRL distribution point of
`crl_url`. Use `topgen-ca.sh issue|revoke|gencrl` to manage certificates after the build.

## CRL

The CRL is written in DER to `/var/lib/topgen/vhosts/topgen.info/topgen_ca.crl`, with a PEM copy, and
served at `http://topgen.info/topgen_ca.crl`. Regenerate it with `topgen-ca.sh gencrl`.
`topgen-add-crl.sh` adds a CRL to images built without one.

## Web content

- **`scrape`**: `topgen-scrape.sh` mirrors the sites listed in `scrape_sites_file` with wget.
  Each site gets a certificate and an nginx vhost at its real IP.
- **`s3`**: `rclone` copies prebuilt content from an S3-compatible bucket, then topgen generates
  certificates and nginx configuration for it without scraping. Bucket layout:

  ```
  <prefix>/vhosts/<fqdn>/...   one directory per site, served as-is
  <prefix>/hosts.nginx         optional "<ip> <fqdn>" lines; otherwise real DNS is used
  ```

  Credentials are passed only to the build and never written to the image.

## Using the image

Log in as **`slatebox`** with the password `admin_password` (default `slatebox`), on the console or
with SSH (password authentication is enabled). The user has sudo. Change the password after the
first login.

cloud-init is still enabled, so you can attach your own NoCloud seed (`cidata`) to add SSH keys and
users, or to turn off password logins.

On boot, `greybox.service` starts `core-daemon` and loads `/etc/greybox/map.xml`.

```sh
greybox-ctl status                      # session state and nodes
greybox-ctl exec DeltaUser1 traceroute -n topgen.info
greybox-ctl exec DeltaUser1 curl --cacert /var/lib/topgen/etc/topgen_ca.cer https://example.com/
sudo greybox-ctl stop && sudo greybox-ctl start
```

To get a shell inside a node, run `sudo vcmd -c /tmp/pycore.<session>/<node> -- bash`. The CORE GUI
(`core-gui`) can attach to the running session over X forwarding. FRR routers have `vtysh`.

The host's `/etc/resolv.conf` is `nameserver 8.8.8.8`, which is the simulated DNS inside the map,
as greybox recommends. CORE nodes share the host's filesystem, so they use the same file.

## Changes from upstream

The upstream trees in `vendor/` are never edited. `install.sh` copies them and applies:

- `patches/topgen/`
  - `0001-ubuntu-paths`: Debian paths (`/etc/ssl`, `/var/cache/bind`, root hints) and guards on
    the SELinux calls.
  - `0002-vmail-getopts`: fixes the `-c` option of `topgen-vmail.sh`.
  - `0003-persistent-ca-crl`: a persistent CA database, random serials, an external CA chain, a CRL distribution point and
    serverAuth on leaf certificates, and a CRL on topgen.info.
  - `0004-no-fetch`: `topgen-scrape.sh -n` uses existing vhosts, and `-H` sets preset IPs (used for S3).
  - `0005-dovecot-2.4`: rewrites the generated `dovecot.conf` for Dovecot 2.4 (IMAP only).
  - `0006-vmail-ca-certs`: the mail server certificates are issued by the TopGen CA instead of
    being self-signed.
- `patches/greybox/0001-topgenboot-ubuntu`: `TopGenBoot.sh` fixes in the maps for Ubuntu
  (`named -u bind`, `/var/cache/bind/data`).

New files:

| File | What it does |
|---|---|
| `src/imn2xml.py` | Converts legacy `.imn` maps to CORE 9 XML. |
| `src/core_services/` | A generic CORE 9 `UserDefined` service (CORE 9 removed it), driven by the maps' own `dirs`/`files`/`cmdup`/`cmddown`. |
| `src/sbin/greybox-ctl` | Starts, stops and inspects the session over CORE's gRPC API. |
| `src/sbin/topgen-ca.sh`, `topgen-add-crl.sh`, `topgen-fetch-content.sh` | PKI and content tools. |
| `src/systemd/` | A new `greybox.service`, and `/usr/lib/frr` on core-daemon's `PATH`. |

## Repository layout

```
vendor/{topgen,greybox}/   upstream, verbatim
patches/{topgen,greybox}/  patches applied by install.sh
src/                       slatebox additions (see above)
config/                    default scrape list, vmail.cfg, delegations.dns
install.sh                 patches and installs everything (runs inside the VM as root)
packer/                    slatebox.pkr.hcl, variables.pkr.hcl, example.pkrvars.hcl, provision/
tests/                     test_pki.sh, pytest converter tests, smoke.sh (boots the image)
```

## Notes

- **No KVM:** with `accelerator = "tcg"`, QEMU emulates the CPU and the build takes hours. SSH
  waits up to 60 minutes.
- **Proxies:** `build_proxy` must be an HTTPS (CONNECT) proxy. It is used for apt's HTTPS sources,
  wget, rclone and uv; plain HTTP goes direct. Under QEMU user networking, the build host is
  `10.0.2.2`. `build_ca_file` is added to the trust store for the build only. `90-finalize.sh`
  removes both.
- The host's own `frr`, `nginx`, `named`, `postfix`, `dovecot`, `tor` and `isc-dhcp-server` units
  are disabled, because these daemons run inside CORE nodes.
- `topgen-tor.sh` is installed but not used, because the backbone map has no Tor network.
