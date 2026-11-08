#!/bin/bash
# Re-fetch upstream CMU-SEI sources into vendor/ at a given ref (default: master)
# and show what changed. Afterwards check that patches/ still apply (make test).
# usage: scripts/vendor-sync.sh [topgen|greybox] [REF]
set -euo pipefail
cd "$(dirname "$0")/.."

sync() {
  local name=$1 ref=${2:-master} tmp
  tmp=$(mktemp -d)
  git clone -q "https://github.com/cmu-sei/$name" "$tmp"
  git -C "$tmp" checkout -q "$ref"
  rm -rf "vendor/$name" && mkdir -p "vendor/$name"
  git -C "$tmp" archive HEAD | tar -x -C "vendor/$name"
  echo "$name: $(git -C "$tmp" log -1 --format='%H %cs')  (update vendor/UPSTREAM.md)"
  rm -rf "$tmp"
}

if [ $# -gt 0 ]; then sync "$@"; else sync topgen; sync greybox; fi
git status --short vendor/
