PACKER_ARGS ?=
DOCKER_ARGS ?=
CA_CERTS ?= certs
REGISTRY ?= docker.io
SCRAPE_SITES ?=
MAIL_SITES ?=
IMAGE ?= output/slatebox.qc2
TEST_ARGS ?=

.PHONY: help install-dev init lint check-sites check-mail builder build watch test clean

help:
	@echo '  install-dev     Install the test and lint tools and the Git hooks (apt on Ubuntu)'
	@echo '  init            Install the Packer plugins on the host, for lint'
	@echo '  lint            Run all prek checks (needs Packer)'
	@echo '  check-sites     Check that each site can be mirrored from here'
	@echo '    SCRAPE_SITES    URLs of the sites'
	@echo '  check-mail      Check that each mail server gets its own address'
	@echo '    MAIL_SITES      Names of the mail servers'
	@echo '  builder         Build the build container and install the Packer plugins'
	@echo '    CA_CERTS        Directory or Git URL of extra CA certificates (default: certs/)'
	@echo '    REGISTRY        Registry to pull the hashicorp/packer image from'
	@echo '  build           Build output/slatebox.qc2 in the build container (needs /dev/kvm)'
	@echo '    PACKER_ARGS     Packer arguments, such as -var-file=site.pkrvars.hcl'
	@echo '    DOCKER_ARGS     Arguments for the build container, such as --volume'
	@echo '  watch           Follow the console of the build VM'
	@echo '  test            Boot an image and test it'
	@echo '    IMAGE           Image to test'
	@echo '    TEST_ARGS       pytest arguments'
	@echo '  clean           Stop a running build and delete what the targets made'

install-dev:
	sudo apt-get update
	sudo apt-get install -y qemu-system-x86 sshpass busybox dnsutils libnss3-tools traceroute
	uv tool install prek
	python3 -m venv .venv
	.venv/bin/python -m pip install -r tests/requirements.txt
	.venv/bin/python -m playwright install --with-deps --only-shell chromium
	prek install

init:
	packer init .

lint:
	prek run --all-files

check-sites:
	scripts/check-sites.sh $(SCRAPE_SITES)

check-mail:
	files/usr/local/sbin/topgen-mail-sites.sh $(MAIL_SITES)

builder:
	docker build \
		--build-arg REGISTRY=$(REGISTRY) \
		--build-context certs=$(CA_CERTS) \
		--tag slatebox-builder \
		- < Dockerfile
	docker run --rm \
		--volume $(CURDIR):$(CURDIR) \
		--workdir $(CURDIR) \
		--env PACKER_PLUGIN_PATH=$(CURDIR)/.packer.d/plugins \
		--env PACKER_GITHUB_API_TOKEN \
		slatebox-builder packer init .

# The build container runs as root, so the files it writes are owned by root
build: builder
	docker run --rm --tty --init \
		--name slatebox-build \
		--network host \
		--device /dev/kvm \
		--volume $(CURDIR):$(CURDIR) \
		--workdir $(CURDIR) \
		--env PACKER_PLUGIN_PATH=$(CURDIR)/.packer.d/plugins \
		--env PACKER_CACHE_DIR=$(CURDIR)/.packer.d/cache \
		--env PACKER_LOG \
		--env PACKER_LOG_PATH \
		$(DOCKER_ARGS) \
		slatebox-builder packer build $(PACKER_ARGS) .

watch:
	tail -n +1 -F serial-build.log

test:
	.venv/bin/python -m pytest tests --image $(IMAGE) $(TEST_ARGS)

# The build container deletes the build output, which root owns
clean:
	-docker rm --force slatebox-build
	-docker run --rm --pull=never \
		--volume $(CURDIR):$(CURDIR) \
		--workdir $(CURDIR) \
		slatebox-builder rm -rf output serial-build.log packer.log
	rm -rf test-output tests/__pycache__ .ruff_cache
