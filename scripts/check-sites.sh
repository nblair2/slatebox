#!/bin/bash
# Check that each site's start page can be mirrored from this network. The
# scrape skips a site whose start page fails, and a bot check or a
# JavaScript-only page mirrors as an empty shell.
# usage: check-sites.sh URL...
set -uo pipefail

if [ $# -eq 0 ]; then
  echo "usage: check-sites.sh URL..." >&2
  exit 2
fi

# the scraper's user agent
UA=$(sed -n 's/^UA="\(.*\)"$/\1/p' "$(dirname "$0")/../files/usr/local/sbin/topgen-scrape.sh")

check() {
  local url=$1 tmp out code final links
  tmp=$(mktemp -d)
  if ! out=$(curl -sS -L -o "$tmp/body" --max-time 30 -A "$UA" \
    -w '%{http_code} %{url_effective}' "$url" 2> "$tmp/err"); then
    echo "ERROR    $url ($(head -n 1 "$tmp/err"))"
  else
    read -r code final <<< "$out"
    links=$(tr '\n\t' '  ' < "$tmp/body" | grep -oi '<a [^>]*href=' | wc -l)
    if [ "$code" != 200 ]; then
      echo "BLOCKED  $url (HTTP $code)"
    elif [ "$(echo "$final" | cut -d/ -f3)" != "$(echo "$url" | cut -d/ -f3)" ]; then
      echo "MOVED    $url (redirects to $final; list that URL if it is the site you want)"
    elif [ "$links" -eq 0 ]; then
      echo "EMPTY    $url (no links: a bot check or a JavaScript-only page)"
    else
      echo "OK       $url ($links links)"
    fi
  fi
  rm -rf "$tmp"
}

# check all sites at once
results=$(
  for url in "$@"; do
    check "$url" &
  done
  wait
)
echo "$results" | sort

if echo "$results" | grep -qv '^OK'; then
  exit 1
fi
