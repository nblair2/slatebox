.DEFAULT_GOAL := help

PACKER ?= packer
PREK ?= prek
UV ?= uv
PYTHON ?= python3
VENV ?= .venv
IMAGE ?= build/image/slatebox.qcow2
PACKER_ARGS ?=
TEST_ARGS ?=

.PHONY: help init build install-dev test lint

help:
	@printf '%s\n' \
		'lint         Run all prek checks, including Packer validation' \
		'init         Install Packer plugins' \
		'build        Build the qcow2 image' \
		'test         Boot and test IMAGE (extra options: TEST_ARGS)' \
		'install-dev  Install build and test tools (apt on Ubuntu), test dependencies and Git hooks'

lint:
	$(PREK) run --all-files

init:
	$(PACKER) init .

build: init
	$(PACKER) build $(PACKER_ARGS) .

test:
	"$(VENV)/bin/python" -m pytest tests --image "$(IMAGE)" $(TEST_ARGS)

install-dev: init
	sudo apt-get update
	sudo apt-get install -y qemu-system-x86 qemu-utils xorriso sshpass busybox dnsutils libnss3-tools traceroute
	$(UV) tool install prek
	$(UV) tool install 'ansible-core>=2.20'
	ansible-galaxy collection install ansible.posix
	$(PYTHON) -m venv "$(VENV)"
	"$(VENV)/bin/python" -m pip install -r tests/requirements.txt
	"$(VENV)/bin/python" -m playwright install --with-deps --only-shell chromium
	$(PREK) install
