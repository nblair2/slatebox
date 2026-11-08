#!/bin/bash
# CORE daemon: the release .deb (without its Python step) plus a venv built on a
# uv-managed CPython, because the distro Python is too new for CORE's pins.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive UV_SYSTEM_CERTS=1
CORE_VERSION=${CORE_VERSION:-9.2.1}
CORE_PYTHON=${CORE_PYTHON:-3.12}
UV_VERSION=${UV_VERSION:-0.11.32}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

deb=$tmp/core_${CORE_VERSION}_amd64.deb
wget -qO "$deb" "https://github.com/coreemu/core/releases/download/release-$CORE_VERSION/core_${CORE_VERSION}_amd64.deb"
NO_PYTHON=1 apt-get -y -o DPkg::Lock::Timeout=600 install "$deb"

# uv is only needed at build time.
wget -qO- "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz" |
  tar -xz -C "$tmp" --strip-components=1
export UV_PYTHON_INSTALL_DIR=/opt/core/python UV_PYTHON_BIN_DIR=$tmp/bin \
  UV_CACHE_DIR=$tmp/cache UV_LINK_MODE=copy
"$tmp/uv" python install "$CORE_PYTHON"
"$tmp/uv" venv --allow-existing --python "$CORE_PYTHON" /opt/core/venv
"$tmp/uv" pip install --python /opt/core/venv/bin/python /opt/core/core-"$CORE_VERSION"-*.whl

# The rest of the deb's after-install step.
sed -i 's|[$]DAEMON|/opt/core/venv/bin/core-daemon|' /usr/lib/systemd/system/core-daemon.service
ln -sf /opt/core/venv/bin/core-* /usr/bin/

sed -i 's|^#\?custom_services_dir *=.*|custom_services_dir = /usr/share/slatebox/core_services|' /opt/core/etc/core.conf
grep -q '^custom_services_dir = /usr/share/slatebox/core_services$' /opt/core/etc/core.conf

systemctl enable core-daemon.service
