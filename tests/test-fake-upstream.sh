#!/usr/bin/env bash
# The fake upstream is the thing every offline claim about the provider-A path
# rests on, so it gets tested itself. Runs in-process via selftest.py -- no
# background server to leak, and no inline `python3 -c` for Defender to score
# as a downloader.
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

assert_ok 'the fake upstream behaves as specified' \
  python3 tests/fake-upstream/selftest.py

finish
