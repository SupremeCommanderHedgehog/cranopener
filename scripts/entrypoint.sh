#!/usr/bin/env bash
# Seed config, then hand over to the requested command.
set -euo pipefail
/usr/local/bin/seed-config.sh
exec "$@"
