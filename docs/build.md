# Build

The image is built in a Docker container. You need Linux with KVM, Docker and GNU Make.

```sh
make build
```

The image is written to `output/slatebox.qc2`. The default build takes about 15 minutes.

## Settings

Put your settings in a Packer variable file.

```hcl title="site.pkrvars.hcl"
scrape_sites = ["https://www.example.com", "https://www.example.org"]
mail_sites   = ["mail.example.com"]
```

```sh
make build PACKER_ARGS=-var-file=site.pkrvars.hcl
```

| Variable | Default | Purpose |
|---|---|---|
| `ubuntu_image_url` | Ubuntu 26.04 cloud image | Base image of the VM |
| `ubuntu_image_checksum` | Ubuntu's `SHA256SUMS` | Checksum of the base image |
| `cpus` | `4` | vCPUs of the build VM |
| `memory` | `8192` | RAM (MiB) of the build VM |
| `disk_size` | `64G` | Virtual disk size |
| `admin_password` | `slatebox` | Password of `root` |
| `overlay_dir` | none | Directory copied onto `/` of the image |
| `scrape_sites` | `["https://www.cmu.edu"]` | Websites to mirror |
| `mail_sites` | `["mail.cmu.edu"]` | Mail servers to simulate |
| `scrape_depth` | `1` | Link depth to follow on each site |
| `scrape_timeout` | `60m` | Time limit for the whole scrape |
| `scrape_jobs` | `8` | Scrape processes at once |
| `scrape_site_jobs` | `2` | Scrape processes at once on one site |

## Make

| Target | Purpose |
|---|---|
| `install-dev` | Install the test and lint tools and the Git hooks |
| `init` | Install the Packer plugins on the host, for `lint` |
| `lint` | Run all lint checks. Needs Packer on the host. |
| `check-sites` | Check that each site can be mirrored from here |
| `check-mail` | Check that each mail server gets its own address |
| `builder` | Build the build container and install the Packer plugins |
| `build` | Build the image in the build container |
| `watch` | Follow the console of the build VM |
| `test` | Boot an image and test routing, DNS, web and mail |
| `docs` | Build this site |
| `clean` | Stop a running build and delete what the targets made |

Some targets take variables.

| Target | Variable | Purpose |
|---|---|---|
| `check-sites` | `SCRAPE_SITES` | URLs of the sites. Defaults to `scrape_sites`. |
| `check-mail` | `MAIL_SITES` | Names of the mail servers. Defaults to `mail_sites`. |
| `builder` | `CA_CERTS` | Directory or Git URL of extra CA certificates for the build container. Defaults to `certs/`, which is empty. |
| `builder` | `REGISTRY` | Registry to pull the `hashicorp/packer` image from. Defaults to Docker Hub. |
| `build` | `PACKER_ARGS` | Packer arguments, such as `-var-file=site.pkrvars.hcl` or `-var cpus=16` |
| `build` | `DOCKER_ARGS` | Arguments for the build container, such as `--volume` |
| `test` | `IMAGE` | Image to test. Defaults to `output/slatebox.qc2`. |
| `test` | `TEST_ARGS` | Arguments for `pytest` |

The build container sees only this directory. Mount anything outside it with `DOCKER_ARGS`.

Some sites block scrapers. Check yours before a long build.

```sh
make check-sites check-mail PACKER_ARGS=-var-file=site.pkrvars.hcl
```
