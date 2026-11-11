#!/usr/bin/env bash
set -euo pipefail

# Hosted runners occasionally cannot resolve the Ubuntu package archives.
# Repair only the disposable runner, and fail before a long apt retry loop.
archive_dns_works() {
  local host
  for host in archive.ubuntu.com security.ubuntu.com; do
    timeout 10 getent ahostsv4 "$host" >/dev/null || return 1
  done
}

if archive_dns_works; then
  exit 0
fi

echo 'Ubuntu archive DNS failed; configuring fallback DNS on this runner.'
interface=$(ip -o -4 route show default | awk '{print $5; exit}')
if [[ -z "$interface" ]]; then
  echo 'Cannot determine the runner default network interface.' >&2
  exit 1
fi

sudo resolvectl dns "$interface" 1.1.1.1 8.8.8.8
sudo resolvectl domain "$interface" '~.'
sudo resolvectl flush-caches

if ! archive_dns_works; then
  echo 'Ubuntu archive DNS is still unavailable after runner DNS recovery.' >&2
  exit 1
fi
