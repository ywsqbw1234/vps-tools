#!/usr/bin/env bash
set -euo pipefail
# Public subscription publishing is retired. No credentials are sent to GitHub.
if [[ ! -x /usr/local/sbin/export-private-subscriptions ]]; then
  echo 'Private exporter is not installed on this server.' >&2
  exit 1
fi
exec /usr/local/sbin/export-private-subscriptions
