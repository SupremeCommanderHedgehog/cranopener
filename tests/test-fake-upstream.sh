#!/usr/bin/env bash
# The fake upstream is the thing every offline claim about the provider-A path
# rests on, so it gets tested itself. Runs in-process via selftest.py -- no
# background server to leak, and no inline `python3 -c` for Defender to score
# as a downloader.
set -uo pipefail
# Fatal: the fixtures below are repo-relative, and assertions run against a tree
# that does not hold them fail in ways that read like a broken fixture.
cd "$(dirname "$0")/.." || { echo "${0##*/}: cannot reach the repository root" >&2; exit 1; }
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

assert_ok 'the fake upstream behaves as specified' \
  python3 tests/fake-upstream/selftest.py

# --- the multi-turn fixture ------------------------------------------------
# openhands-multi-turn.json is what carries a harness past turn three, and the
# only test that plays it needs a container engine and a 6GB image. Without
# these two lines a typo in it surfaces on the build host, minutes into a run,
# as a conversation that stopped after one turn -- which looks exactly like the
# harness failing.
FIXTURE='tests/fake-upstream/scripts/openhands-multi-turn.json'

assert_ok 'the multi-turn fixture is valid JSON' \
  python3 -c "import json; json.load(open('$FIXTURE'))"

# Four is the number that matters: turn three is where flattened history
# breaks, so a fixture that runs out before then cannot show the thing the
# integration test exists to show.
turns=$(python3 -c "
import json
responses = json.load(open('$FIXTURE'))['responses']
print(sum(1 for text in responses if '<function=' in text))
")
assert_ok "the fixture carries at least four action turns (carries $turns)" \
  test "$turns" -ge 4

finish
