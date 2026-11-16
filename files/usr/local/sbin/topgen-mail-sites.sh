#!/bin/bash
# Print a vmail.cfg line for each mail server: its name, the address real mail
# for its domain goes to, and the default account. Fails when a server is left
# without an address of its own.
# usage: topgen-mail-sites.sh SERVER...   (e.g. mail.cmu.edu)
set -uo pipefail

ACCOUNT=administrator:password

# the addresses of a domain's mail servers, best first, then its own
addresses() {
  {
    dig +short MX "$1" | sort -n | while read -r _ mx; do dig +short A "$mx"; done
    dig +short A "$1"
  } | grep -E '^[0-9.]+$'
}

[ $# -gt 0 ] || { echo "usage: topgen-mail-sites.sh SERVER..." >&2; exit 2; }

declare -A taken
for server; do
  ip=
  for address in $(addresses "${server#*.}"); do
    [ -z "${taken[$address]:-}" ] && { ip=$address; break; }
  done
  [ -n "$ip" ] || { echo "topgen-mail-sites.sh: no free address for $server" >&2; exit 1; }
  taken[$ip]=$server
  echo "$server $ip $ACCOUNT"
done
