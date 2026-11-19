#!/usr/bin/env bash
set -euo pipefail
# Public subscription publishing is retired. No credentials are sent to GitHub.
if [[ ! -x /usr/local/sbin/update-cf-subscription ]]; then
  echo 'Private IP updater is not installed on this server.' >&2
  exit 1
fi
exec /usr/local/sbin/update-cf-subscription "$@"
