#!/bin/bash
# Mirror web sites with goscrape into $TOPGEN_VARLIB/vhosts, issue a TopGen CA
# certificate per vhost, and write etc/nginx.conf and etc/hosts.nginx (read by
# topgen-mkdns.sh and topgen-boot). Run "topgen-ca.sh init" before this and
# "topgen-ca.sh gencrl" after it.
#
# usage: topgen-scrape.sh DEPTH TIMEOUT URL...
#   DEPTH    goscrape link depth (1 = the start page and the pages it links to)
#   TIMEOUT  limit for the whole scrape, as for timeout(1): a number with an
#            optional s, m, h or d suffix, e.g. 60m. All sites share it; a site
#            still running at the limit keeps what was mirrored so far.
#   A site whose start page fails is skipped with a warning; the scrape fails
#   only if every site does.
# env: TOPGEN_VARLIB (/var/lib/topgen), TOPGEN_SCRAPE_LOG (/var/log/topgen-scrape.log),
#      TOPGEN_SCRAPE_JOBS (8): goscrape processes at once, over all sites
#
# goscrape fetches one URL at a time, so a deep crawl of a big site is slow.
# We run several goscrape processes side by side instead (see "fan-out" below).
set -euo pipefail

[ $# -ge 3 ] || { echo "usage: topgen-scrape.sh DEPTH TIMEOUT URL..." >&2; exit 2; }
export TOPGEN_VARLIB=${TOPGEN_VARLIB:-/var/lib/topgen} # also for topgen-ca.sh
ETC=$TOPGEN_VARLIB/etc VH=$TOPGEN_VARLIB/vhosts CERTS=$TOPGEN_VARLIB/certs
LOG=${TOPGEN_SCRAPE_LOG:-/var/log/topgen-scrape.log}
JOBS=${TOPGEN_SCRAPE_JOBS:-8}
TOPGEN_INFO_IP=198.51.100.10 # TEST-NET-2, routed to the topgen.info node
UA="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
# matched against the URL path only (goscrape ignores the query string)
SKIP='\.(mp4|m4v|mov|avi|mkv|webm|mp3|wav|ogg|zip|tgz|gz|bz2|xz|7z|rar|iso|dmg|exe|msi)$'

die() { echo "topgen-scrape.sh: $*" >&2; exit 1; }
ipv4() { getent ahostsv4 "$1" | awk 'NR == 1 { print $1 }' || true; } # "" if unresolvable

depth=$1 limit=$2
shift 2
[[ $depth =~ ^[0-9]+$ ]] || die "DEPTH must be a number"
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "TOPGEN_SCRAPE_JOBS must be a positive number"
[[ $limit =~ ^([0-9]+)([smhd]?)$ ]] ||
  die "TIMEOUT must be a whole number with an optional s, m, h or d suffix"
case ${BASH_REMATCH[2]} in
  m) unit=60 ;;
  h) unit=3600 ;;
  d) unit=86400 ;;
  *) unit=1 ;;
esac
# every goscrape run stops at this point (bash's SECONDS counts up from 0)
deadline=$((SECONDS + 10#${BASH_REMATCH[1]} * unit))

mkdir -p "$ETC" "$VH" "$CERTS"
work=$(mktemp -d)
# every goscrape run logs to its own file in $work; together they become $LOG
finish() { cat "$work"/*.log > "$LOG" 2>/dev/null || true; rm -rf "$work"; }
trap finish EXIT

# job NAME DEPTH URL: one goscrape run, stopped at the deadline. Writes
# $work/NAME.log and NAME.rc (the exit code; 124 = stopped by the deadline).
job() {
  local name=$1 depth=$2 url=$3 left=$((deadline - SECONDS)) rc=0
  if [ "$left" -gt 0 ]; then
    timeout "$left" goscrape --depth "$depth" --timeout 30 --useragent "$UA" \
      --exclude "$SKIP" --output "$VH" "$url" > "$work/$name.log" 2>&1 || rc=$?
  else
    rc=124
  fi
  echo "$rc" > "$work/$name.rc"
}

# retry_job NAME DEPTH URL: job, tried up to 3 times. goscrape fails only if
# its first page does, which is mostly a dropped connection (a "connection
# reset by peer" from the site), so wait a little and try again.
retry_job() {
  local try
  for try in 1 2 3; do
    job "$@"
    case $(cat "$work/$1.rc") in
      0 | 124) return 0 ;;
    esac
    if [ "$try" -lt 3 ]; then
      echo "scrape: $3 failed (exit $(cat "$work/$1.rc")), trying again" >&2
      sleep $((try * 15))
    fi
  done
}

# page_job NAME DEPTH URL: job, for a page that still loads on its own host.
# One that redirects to another host would mirror that site instead, and one
# that fails would only fail again; NAME.rc says "skip" for those.
page_job() {
  local host=${3#*://} final
  host=${host%%/*}
  final=$(curl -sL -o /dev/null --max-time 30 --retry 2 --retry-all-errors -A "$UA" \
    -w '%{http_code} %{url_effective}' "$3" | awk '{ split($2, u, "/"); print $1, u[3] }' || true)
  if [ "$final" = "200 $host" ]; then
    retry_job "$@"
  else
    echo skip > "$work/$1.rc"
  fi
}

# run a command in the background, once fewer than $JOBS are running
spawn() {
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
  "$@" &
}

# Fan-out. "goscrape --depth N site" fetches the start page, then everything up
# to N links away, one URL at a time. The same pages are reached by fetching
# the start page and the pages it links to (depth 1), then crawling each of
# those pages to depth N-1, and those crawls can run side by side:
#   1. every site's start page at depth 1 (all sites at once);
#   2. every page found in step 1, at depth N-1, $JOBS at a time.
# All runs write into $VH. goscrape skips assets (images, CSS, ...) already on
# disk, so a run reuses what earlier ones fetched; pages that several runs
# reach are fetched again and written with the same content (links in a saved
# page only depend on its own URL). A run killed at the deadline can leave its
# current file incomplete, as a single sequential run would.
first=$depth
if [ "$depth" -ge 2 ]; then first=1; fi
: > "$work/sites"
i=0
for url; do
  i=$((i + 1))
  echo "scrape: $url (depth $depth, at most $limit)"
  printf 'site%03d %s\n' "$i" "$url" >> "$work/sites"
  spawn retry_job "$(printf 'site%03d' "$i")" "$first" "$url"
done
wait

pages=() mirrored=0 failed_sites=()
while read -r name url; do
  rc=$(cat "$work/$name.rc")
  case $rc in
    0) mirrored=$((mirrored + 1)) ;;
    124)
      mirrored=$((mirrored + 1))
      echo "scrape: $url stopped after $limit, keeping the partial mirror"
      continue
      ;;
    *)
      tail -n 20 "$work/$name.log" >&2
      echo "scrape: WARNING: skipping $url, its start page failed (exit $rc)" >&2
      failed_sites+=("$url")
      host=${url#*://}
      rmdir "$VH/${host%%/*}" 2>/dev/null || true # only if nothing was mirrored
      continue
      ;;
  esac
  # the start page is the first "Downloading webpage"; JSON escapes & as \u0026
  if [ "$depth" -ge 2 ]; then
    mapfile -t -O "${#pages[@]}" pages < <(
      grep 'Downloading webpage' "$work/$name.log" | tail -n +2 |
        sed 's/.*"url":"//; s/".*//; s/\\u0026/\&/g')
  fi
done < "$work/sites"
[ "$mirrored" -gt 0 ] || die "every site failed (see $LOG)"

if [ "${#pages[@]}" -gt 0 ]; then
  echo "scrape: ${#pages[@]} linked pages to depth $((depth - 1)), $JOBS at a time"
  # keep only the host directories that step 1 created, should a page_job
  # still have mirrored another host
  ls "$VH" > "$work/hosts"
  i=0
  for url in "${pages[@]}"; do
    i=$((i + 1))
    spawn page_job "$(printf 'page%05d' "$i")" "$((depth - 1))" "$url"
  done
  wait
  for d in "$VH"/*; do
    grep -qxF "${d##*/}" "$work/hosts" || rm -rf "$d"
  done
  skipped=0 failed=0 late=0
  for f in "$work"/page*.rc; do
    case $(cat "$f") in
      0) ;;
      skip) skipped=$((skipped + 1)) ;;
      124) late=$((late + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done
  [ "$skipped" -eq 0 ] || echo "scrape: skipped $skipped of them (error or redirect to another host)"
  [ "$late" -eq 0 ] || echo "scrape: $late of them stopped after $limit, keeping the partial mirror"
  [ "$failed" -eq 0 ] || echo "scrape: $failed of them failed (see $LOG)"
fi
[ "${#failed_sites[@]}" -eq 0 ] ||
  echo "scrape: skipped ${#failed_sites[@]} sites whose start page failed: ${failed_sites[*]}"
finish
trap - EXIT
# several runs can fetch the same page: count each URL once
echo "scrape: $(grep -o 'Downloading webpage.*' "$LOG" | sort -u | wc -l) pages," \
  "$(grep -o 'Downloading asset.*' "$LOG" | sort -u | wc -l) assets, $(grep -c ERROR "$LOG") errors," \
  "$(du -sh "$VH" | cut -f1) in $VH; details in $LOG"

# keep only plain host names (a start URL with a port gives "host:port")
rm -rf "$VH"/*:* "$VH/topgen.info"
[ -n "$(ls -A "$VH")" ] || die "nothing was mirrored"
mkdir "$VH/topgen.info"
cp "$ETC/topgen_ca.cer" "$VH/topgen.info/"

cat > "$ETC/nginx.conf" <<EOT
# generated by topgen-scrape.sh; one key for all vhost certificates
ssl_certificate_key $ETC/topgen_vh.key;
server_names_hash_bucket_size 256;
server_names_hash_max_size 131070;
EOT
: > "$ETC/hosts.nginx"
for d in "$VH"/*/; do
  d=${d%/}
  vh=${d##*/}
  names=("$vh")
  if [ "$vh" = topgen.info ]; then
    ip=$TOPGEN_INFO_IP
  else
    ip=$(ipv4 "$vh")
    [ -n "$ip" ] || die "cannot resolve $vh"
    # serve www.example.org as example.org too, unless that was mirrored itself
    apex=${vh#www.}
    if [ "$apex" != "$vh" ] && [ ! -d "$VH/$apex" ] && aip=$(ipv4 "$apex") && [ -n "$aip" ]; then
      names+=("$apex")
      echo "$aip $apex" >> "$ETC/hosts.nginx"
    fi
  fi
  echo "$ip $vh" >> "$ETC/hosts.nginx"
  topgen-ca.sh issue "$ETC/topgen_vh.key" "$CERTS/$vh.cer" "${names[@]}"
  cat >> "$ETC/nginx.conf" <<EOT

server {
  listen 80;
  listen 443 ssl;
  ssl_certificate $CERTS/$vh.cer;
  server_name ${names[*]};
  root $d;
  try_files \$uri \$uri.html \$uri/ =404;
}
EOT
done

# topgen.info landing page
{
  cat <<'EOT'
<html>
  <head>
    <title>Welcome to TopGen.info !</title>
  </head>
  <body> <div style="text-align: justify; width: 500pt">
    <h2>Welcome to TopGen.info !</h2>
    This is a simulation of the World Wide Web. View this site in either
    <ul>
    <li> Cleartext: <a href="http://topgen.info">http://topgen.info</a>
    <li> HTTPS: <a href="https://topgen.info">https://topgen.info</a>;
      <ul>
      <li> Your browser requires the
           <a href="topgen_ca.cer">TopGen CA Certificate</a>
           to avoid certificate warnings! All simulated Web sites are
           using certificates issued and signed by this CA!
      </ul>
    </ul>
    Below is a list of Web sites mirrored for this simulation:
    <ul>
EOT
  for d in "$VH"/*/; do
    vh=$(basename "$d")
    [ "$vh" = topgen.info ] || echo "    <li><a href=\"//$vh\">$vh</a>"
  done
  cat <<'EOT'
    </ul>
  </body>
</html>
EOT
} > "$VH/topgen.info/index.html"
echo "scrape: $(wc -l < "$ETC/hosts.nginx") names in $ETC/hosts.nginx"
