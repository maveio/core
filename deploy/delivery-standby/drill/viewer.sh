#!/bin/sh
# Requests one media file per second the way a viewer would: through the
# caching resolver, under the public hostname.
url="$1"
host=$(echo "$url" | sed -E 's#^https?://([^/]+)/.*#\1#')

while true; do
  address=$(nslookup "$host" 2>/dev/null | awk '/^Address/ && !/:53/ { a = $NF } END { print a }')
  headers=$(wget -q -S -T 2 -O /dev/null "$url" 2>&1)
  status=$(echo "$headers" | sed -n 's/.*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' | tail -n 1)
  side=$(echo "$headers" | awk 'tolower($1) == "x-mave-delivery:" { print $2 }' | tr -d '\r')
  printf '%s  dns=%-12s  http=%-3s  served-by=%s\n' "$(date -u +%H:%M:%S)" "${address:-none}" "${status:-ERR}" "${side:--}"
  sleep 1
done
