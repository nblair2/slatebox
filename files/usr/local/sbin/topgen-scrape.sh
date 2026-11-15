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
#      TOPGEN_SCRAPE_SITE_JOBS (2): goscrape processes at once on one site
#      TOPGEN_SCRAPE_PROGRESS (/dev/null): gets a line as each site or page finishes
#
# goscrape fetches one URL at a time, so a deep crawl of a big site is slow.
# We run several goscrape processes side by side instead (see "fan-out" below).
set -euo pipefail

[ $# -ge 3 ] || { echo "usage: topgen-scrape.sh DEPTH TIMEOUT URL..." >&2; exit 2; }
export TOPGEN_VARLIB=${TOPGEN_VARLIB:-/var/lib/topgen} # also for topgen-ca.sh
ETC=$TOPGEN_VARLIB/etc VH=$TOPGEN_VARLIB/vhosts CERTS=$TOPGEN_VARLIB/certs
LOG=${TOPGEN_SCRAPE_LOG:-/var/log/topgen-scrape.log}
JOBS=${TOPGEN_SCRAPE_JOBS:-8}
SITE_JOBS=${TOPGEN_SCRAPE_SITE_JOBS:-2}
PROGRESS=${TOPGEN_SCRAPE_PROGRESS:-/dev/null}
TOPGEN_INFO_IP=198.51.100.10 # TEST-NET-2, routed to the topgen.info node
UA="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
# matched against the URL path only (goscrape ignores the query string)
SKIP='\.(mp4|m4v|mov|avi|mkv|webm|mp3|wav|ogg|zip|tgz|gz|bz2|xz|7z|rar|iso|dmg|exe|msi)$'

die() { echo "topgen-scrape.sh: $*" >&2; exit 1; }
url_host() { local h=${1#*://}; echo "${h%%[/?#]*}"; }
ipv4() { getent ahostsv4 "$1" | awk 'NR == 1 { print $1 }' || true; } # "" if unresolvable

depth=$1 limit=$2
shift 2
[[ $depth =~ ^[0-9]+$ ]] || die "DEPTH must be a number"
for url; do [[ $url =~ ^https?://[^/?#]+ ]] || die "not an http(s) URL with a host: $url"; done
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "TOPGEN_SCRAPE_JOBS must be a positive number"
[[ $SITE_JOBS =~ ^[1-9][0-9]*$ ]] || die "TOPGEN_SCRAPE_SITE_JOBS must be a positive number"
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

# retry_job TRIES NAME DEPTH URL: job, tried up to TRIES times. goscrape fails
# only if its first page does, which is mostly a dropped connection (a
# "connection reset by peer" from the site) or a rate limit, so wait a little
# and try again.
retry_job() {
  local tries=$1 try
  shift
  for ((try = 1; try <= tries; try++)); do
    job "$@"
    case $(cat "$work/$1.rc") in
      0 | 124) return 0 ;;
    esac
    if [ "$try" -lt "$tries" ]; then
      echo "scrape: $3 failed (exit $(cat "$work/$1.rc")), trying again" >&2
      sleep $((try * 15))
    fi
  done
}

# site_job NAME DEPTH URL: job, for a site's start page
site_job() { retry_job 3 "$@"; }

# page_job NAME DEPTH URL: job, for a linked page, unless it redirects to
# another host (that would mirror the other site) or is gone (404 or 410);
# NAME.rc says "skip" for those. curl checks only for these: other answers,
# such as a bot check that refuses curl but not goscrape, are left to goscrape.
page_job() {
  local host code final
  # past the deadline, job only records 124: no need to check with curl
  if [ "$SECONDS" -ge "$deadline" ]; then job "$@"; return; fi
  host=$(url_host "$3")
  read -r code final < <(curl -sL -o /dev/null --max-time 30 --retry 2 --retry-all-errors \
    -A "$UA" -w '%{http_code} %{url_effective}\n' "$3" || true) || true
  final=$(url_host "${final:-$3}")
  if [ "$code" = 404 ] || [ "$code" = 410 ] || [ "$final" != "$host" ]; then
    echo skip > "$work/$1.rc"
  else
    retry_job 2 "$@"
  fi
}

# progress NAME URL: report a finished job, counted against $total
progress() {
  local name=$1 url=$2 n result
  case $(cat "$work/$name.rc") in
    0) result="done" ;;
    124) result="stopped at the deadline" ;;
    skip) result=skipped ;;
    *) result=failed ;;
  esac
  # jobs finish concurrently: count and report under one lock
  {
    flock 9
    echo "$url" >> "$work/${name%%[0-9]*}.done"
    n=$(wc -l < "$work/${name%%[0-9]*}.done")
    echo "scrape: $(date +%T) [$n/$total] $url $result" >> "$PROGRESS"
  } 9>> "$work/progress.lock"
}

# run_queue: run each "HOST FUNC NAME DEPTH URL" entry of $queue in the
# background and report it when it finishes. Entries start in queue order while
# fewer than $JOBS run in all and fewer than $SITE_JOBS on that HOST; one whose
# host is busy is passed over until a slot on it frees up.
run_queue() {
  local i host func name depth url pid running=0
  local -A busy=() host_of=()
  while [ "${#queue[@]}" -gt 0 ] || [ "$running" -gt 0 ]; do
    for i in "${!queue[@]}"; do
      [ "$running" -lt "$JOBS" ] || break
      read -r host func name depth url <<< "${queue[i]}"
      [ "${busy[$host]:-0}" -lt "$SITE_JOBS" ] || continue
      { "$func" "$name" "$depth" "$url" && progress "$name" "$url"; } &
      host_of[$!]=$host
      busy[$host]=$((${busy[$host]:-0} + 1))
      running=$((running + 1))
      unset 'queue[i]'
    done
    [ "$running" -gt 0 ] || continue
    wait -n -p pid || true
    host=${host_of[$pid]}
    busy[$host]=$((busy[$host] - 1))
    running=$((running - 1))
  done
}

# Fan-out. "goscrape --depth N site" fetches the start page, then everything up
# to N links away, one URL at a time. The same pages are reached by fetching
# the start page and the pages it links to (depth 1), then crawling each of
# those pages to depth N-1, and those crawls can run side by side:
#   1. every site's start page at depth 1 (all sites at once);
#   2. every page found in step 1, at depth N-1, $JOBS at a time.
# Many requests to one site at once trip its rate limits and bot checks, so
# step 2 takes the sites in turn and runs at most $SITE_JOBS on each.
# All runs write into $VH. goscrape skips assets (images, CSS, ...) already on
# disk, so a run reuses what earlier ones fetched; pages that several runs
# reach are fetched again and written with the same content (links in a saved
# page only depend on its own URL). A run killed at the deadline can leave its
# current file incomplete, as a single sequential run would.
first=$depth
if [ "$depth" -ge 2 ]; then first=1; fi
: > "$work/sites"
queue=() i=0 total=$#
for url; do
  i=$((i + 1))
  printf -v name 'site%03d' "$i"
  echo "scrape: $url (depth $depth, at most $limit)"
  echo "$name $url" >> "$work/sites"
  : > "$work/$name.pages"
  queue+=("$(url_host "$url") site_job $name $first $url")
done
run_queue

mirrored=0 failed_sites=()
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
      rmdir "$VH/$(url_host "$url")" 2>/dev/null || true # only if nothing was mirrored
      continue
      ;;
  esac
  # NAME.pages: the URLs of the linked pages. The start page is the first
  # "Downloading webpage"; JSON escapes & as \u0026.
  if [ "$depth" -ge 2 ]; then
    { grep 'Downloading webpage' "$work/$name.log" || true; } | tail -n +2 |
      sed 's/.*"url":"//; s/".*//; s/\\u0026/\&/g' > "$work/$name.pages"
  fi
done < "$work/sites"
[ "$mirrored" -gt 0 ] || die "every site failed (see $LOG)"

# one page of each site in turn, so that every site's pages spread over the run
mapfile -t pages < <(paste -d '\n' "$work"/site*.pages | grep -v '^$')
if [ "${#pages[@]}" -gt 0 ]; then
  echo "scrape: ${#pages[@]} linked pages to depth $((depth - 1)), $JOBS at a time," \
    "at most $SITE_JOBS per site"
  # keep only the host directories that step 1 created, should a page_job
  # still have mirrored another host
  ls "$VH" > "$work/hosts"
  queue=() i=0 total=${#pages[@]}
  for page in "${pages[@]}"; do
    i=$((i + 1))
    printf -v name 'page%05d' "$i"
    queue+=("$(url_host "$page") page_job $name $((depth - 1)) $page")
  done
  run_queue
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
  [ "$skipped" -eq 0 ] || echo "scrape: skipped $skipped of them (not found, or a redirect to another host)"
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
