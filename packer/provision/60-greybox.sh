#!/bin/bash
# Convert the selected greybox map to CORE 9 XML and start it on boot.
set -euo pipefail
args=()
for m in $RJ45_IFACES; do args+=(--rj45 "$m"); done
mkdir -p /etc/greybox
python3 /usr/share/slatebox/imn2xml.py "${args[@]}" \
  "/usr/share/greybox/maps/$MAP.imn" -o /etc/greybox/map.xml
systemctl enable greybox.service
