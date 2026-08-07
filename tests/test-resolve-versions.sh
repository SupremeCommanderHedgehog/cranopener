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

# resolve-versions.sh sets -e when sourced; the suite deliberately does not use
# it, so every assertion runs and reports rather than aborting on the first.
set +e

F=tests/fixtures

assert_eq "opencode version strips the v prefix" \
  "1.18.7" "$(parse_opencode_version < "$F/opencode-release.json")"

assert_eq "go picks newest stable and strips the go prefix" \
  "1.26.5" "$(parse_go_version < "$F/go-dl.json")"

assert_eq "go selection does not depend on API ordering" \
  "1.26.5" "$(parse_go_version < "$F/go-dl-reordered.json")"

assert_eq "julia sorts numerically, so 1.12.6 beats 1.9.0" \
  "1.12.6" "$(parse_julia_version < "$F/julia-versions.json")"

# PyPI resolves "latest" itself, so the parser takes the scalar rather than
# sorting the release list. The fixture carries a newer release candidate to
# pin that: an rc must not be what comes back, because main()'s shape check is
# the only thing that would stop it reaching the image, and a test that never
# saw an rc would not notice if this parser started sorting keys.
assert_eq "pypi takes the resolved latest, not the newest release key" \
  "1.16.0" "$(parse_pypi_version < "$F/pypi-project.json")"

assert_eq "julia asset selects the x86_64 triplet" \
  "https://example.invalid/julia-1.12.6.tar.gz ccc" \
  "$(parse_julia_asset 1.12.6 < "$F/julia-versions.json")"

finish
