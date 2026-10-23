#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo 'Specify the media test dependencies' >&2
  exit 1
fi

# The hosted-runner mirror can stall before tests even start. Use the signed
# public Ubuntu archive and avoid unrelated recommended desktop packages.
if [[ -f /etc/apt/apt-mirrors.txt ]]; then
  printf '%s\n' 'http://archive.ubuntu.com/ubuntu/' | sudo tee /etc/apt/apt-mirrors.txt >/dev/null
fi
sudo apt-get -o Acquire::Retries=3 update
sudo apt-get -o Acquire::Retries=3 install --yes --no-install-recommends "$@"
