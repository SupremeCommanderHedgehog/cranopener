#!/usr/bin/env bash
# Point this clone at the tracked hooks in .githooks/.
#
# Usage: bash scripts/install-hooks.sh
#
# core.hooksPath is per-clone local configuration, so every clone needs this
# once. It is not something a repository can set for you.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

git config core.hooksPath .githooks || exit 2
chmod +x .githooks/* 2>/dev/null

echo "hooks enabled: core.hooksPath -> .githooks"
for h in .githooks/*; do
  [ -f "$h" ] && echo "  $(basename "$h")"
done
echo
echo "pre-push now runs scripts/check-secrets.sh. Verify with:"
echo "  bash scripts/check-secrets.sh"
