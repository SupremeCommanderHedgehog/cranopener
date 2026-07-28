#!/usr/bin/env bash
# Seed config, then hand over to the requested command.
set -euo pipefail

# Seeding is a convenience, not a prerequisite. A read-only or foreign-owned
# config mount must degrade to a warning rather than stopping the container
# from starting at all.
if ! /usr/local/bin/seed-config.sh; then
  echo "cranopener: warning: config seeding skipped (config dir not writable?)" >&2
fi

exec "$@"
