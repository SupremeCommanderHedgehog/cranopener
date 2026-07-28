#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

# These tests exercise jq programs, so jq is a hard prerequisite. Report a
# single clear skip rather than four identical assertion failures, which would
# otherwise train the reader to ignore red output. CI asserts jq is present
# before running the suite, so a skip here can never mask a real regression.
if ! command -v jq >/dev/null 2>&1; then
  printf 'SKIP %s: jq is not installed\n' "${0##*/}"
  exit 0
fi

# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh
# shellcheck source=scripts/resolve-versions.sh
. scripts/resolve-versions.sh

F=tests/fixtures

assert_eq "opencode version strips the v prefix" \
  "1.18.7" "$(parse_opencode_version < "$F/opencode-release.json")"

assert_eq "go picks newest stable and strips the go prefix" \
  "1.26.5" "$(parse_go_version < "$F/go-dl.json")"

assert_eq "julia sorts numerically, so 1.12.6 beats 1.9.0" \
  "1.12.6" "$(parse_julia_version < "$F/julia-versions.json")"

assert_eq "julia asset selects the x86_64 triplet" \
  "https://example.invalid/julia-1.12.6.tar.gz ccc" \
  "$(parse_julia_asset 1.12.6 < "$F/julia-versions.json")"

finish
