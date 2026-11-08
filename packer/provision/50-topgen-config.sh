#!/bin/bash
# Generate mail and DNS configuration (DNS also covers the backbone router IPs).
set -euo pipefail
topgen-vmail.sh -f
topgen-mkdns.sh -f -x /usr/share/greybox/etc/backbone.hosts
