# slatebox

[![Release](https://img.shields.io/github/v/release/nblair2/slatebox?style=flat-square)](https://github.com/nblair2/slatebox/releases/latest)
[![Build](https://img.shields.io/github/actions/workflow/status/nblair2/slatebox/build.yml?branch=main&style=flat-square&label=build)](https://github.com/nblair2/slatebox/actions/workflows/build.yml)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)
[![Ubuntu](https://img.shields.io/badge/ubuntu-26.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/server)

> "Have you ever had a dream, Neo, that you were so sure was real? … How would you know the difference between the dream world and the real world?”
> - Morpheus, *The Matrix*

**`slatebox` is an internet simulator in a VM.** It is a "clean slate" implementation of CMU-SEI's excellent [`greybox`](https://github.com/cmu-sei/greybox) tool

![slatebox](.media/slatebox.jpg)

A qcow2 image built on Ubuntu Server 26.04. [CORE](https://github.com/coreemu/core) runs a 69-router
FRR/BGP backbone; TopGen supplies DNS, web and mail.

## Build

Requires Linux/KVM, GNU Make, Packer 1.10+, `ansible-core` 2.20+ with `ansible.posix`,
`qemu-system-x86`, `qemu-utils` and `xorriso`. Packer boots the cloud image;
[Ansible](ansible/playbook.yml) installs services, generates certificates and mirrors websites.

```sh
make build PACKER_ARGS='-var ext_iface=enp2s0'
```

Build variables are defined in [variables.pkr.hcl](variables.pkr.hcl):

| Variable | Default | Purpose |
|---|---|---|
| `ubuntu_image_url`, `ubuntu_image_checksum` | Ubuntu 26.04 resolute, upstream SHA256SUMS | Base image |
| `cpus`, `memory` | `4`, `8192` | vCPUs and RAM in MiB |
| `disk_size` | `40G` | Virtual disk size |
| `output_dir` | `build/image` | Image output directory |
| `admin_password` | `slatebox` | root's console/SSH password |
| `ext_iface` | `ens4` | NIC connected to the simulated network |
| `scrape_sites` | `["https://www.cmu.edu"]` | Websites to mirror |
| `scrape_depth` | `1` | Crawl depth |
| `scrape_timeout` | `60m` | Limit for the whole scrape; partial mirrors are kept |
| `scrape_jobs` | `8` | Parallel goscrape processes, over all sites |
| `scrape_site_jobs` | `2` | Parallel goscrape processes on one site; lower it to be gentler on mirrored sites |
| `overlay_dir` | `""` | Directory copied onto `/` before the CA, scrape and mail setup |

## Services

The first NIC gets management access by DHCP; `ext_iface` connects external clients to the
simulation. Its name must match the target VM's NIC. Log in as `root` with `admin_password`.
Keep the simulated network isolated from production networks.

### Network Map

[The map](files/etc/greybox/map.xml) contains 69 FRR/BGP routers and client hosts.
`greybox.service` starts it through CORE at boot; allow a few minutes for routing to converge.
Application services run inside the `topgen.info` node, not as host services.

```sh
greybox-ctl status
greybox-ctl exec CharlieUser1 traceroute -n www.cmu.edu
systemctl restart greybox
```

### DHCP

The external link joins `iap1-rtr.disa.mil` on `12.0.0.0/24`. Clients receive
`12.0.0.100`–`12.0.0.250`, gateway `12.0.0.41` and DNS `8.8.8.8`.

### DNS

BIND9 provides simulated root, TLD and caching servers; clients and the VM resolve through
`8.8.8.8`. To add A/PTR records, append `IP name` lines to
[/etc/topgen/hosts.custom](files/etc/topgen/hosts.custom), then run
`greybox-ctl exec topgen.info topgen-boot reload-dns`. Custom records never replace built-in ones.

### Web

nginx serves the build-time website mirrors over HTTPS. `https://topgen.info/` lists them.
Choose sites and crawl limits with the `scrape_*` build variables. A site whose start page fails
(e.g. blocked by bot protection) is skipped with a warning; the build fails only if all do.

### Mail

Postfix and Dovecot provide SMTP submission (587, STARTTLS) and IMAPS (993).
Domains and accounts come from [vmail.cfg](files/etc/topgen/vmail.cfg).

### Certificates

Clients must trust the generated CA at `/var/lib/topgen/etc/topgen_ca.cer`.
To use an existing CA, put its PEM key and certificate in `overlay_dir` as
`var/lib/topgen/etc/topgen_ca.key` and `var/lib/topgen/etc/topgen_ca.cer`. The overlay can also
replace `etc/topgen/vmail.cfg` or `etc/topgen/hosts.custom`. File modes are kept.
`topgen-ca.sh` issues and revokes certificates and regenerates the CRL, served at
`http://topgen.info/topgen_ca.crl`.

## Development

The [Makefile](Makefile) wraps the build, test and lint commands:

| Command | Purpose |
|---|---|
| `make install-dev` | Install build/test packages (apt), dev tools, test environment, Git hooks and Packer plugins |
| `make init` | Install Packer plugins |
| `make build` | Initialize plugins and build the image |
| `make test` | Boot and test `IMAGE` (default: `build/image/slatebox.qc2`) |
| `make lint` | Run all [prek checks](prek.toml), including Packer validation |

Development requires uv, Packer, Python 3.12+, sudo, the build tools above, `sshpass`, `busybox`,
`dig`, `certutil` and `traceroute`; on Ubuntu, `make install-dev` installs them with apt. Run
`make install-dev` once, then `make lint` or `make test`.
Use `TEST_ARGS='--keep'` to leave the VM running
or `TEST_ARGS='--attach -k dns'` to reuse it. Results and diagnostics go to `test-output/`.

[CI](.github/workflows/build.yml) validates, builds and tests the image for pull requests to and
pushes on the default branch, or any branch on demand; successful qcow2 artifacts are kept for three days. Dependabot updates actions and test dependencies;
hook revisions use `prek update`. Ruff targets CORE's and CI's Python 3.12.

[Releasaurus](.github/workflows/release.yml) opens a release PR on the default branch; merge it
to publish a tag and release notes. Versions are `vYYYY.MM.DD.MICRO`, with a counter starting
at 1 each UTC day. Enable **Allow GitHub Actions to create and approve pull requests** in the
repository's Actions settings. Images remain CI artifacts, not release attachments.

## License

Original code and modifications are [GPL-3.0-or-later](LICENSE). Derived material comes from
CMU-SEI's [greybox](https://github.com/cmu-sei/greybox/tree/e89c3754491db97599db073bbeb18fc7b20a7240)
and [topgen](https://github.com/cmu-sei/topgen/tree/e0ab5441a860a98fce4a49c249fe9b61a0e56747),
Copyright 2016 Carnegie Mellon University. Their [greybox](LICENSE.greybox) and
[topgen](LICENSE.topgen) licenses and Government Purpose Rights notices are preserved in
`/usr/local/share/doc/slatebox/` alongside this document. Bundled software
and content retain their own licenses; redistribution must include required notices and source.
