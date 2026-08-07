#!/usr/bin/env bash
set -uo pipefail
# Fatal, not advisory. Every path below this line is repo-relative, so a cd that
# failed would leave the glob running against whatever directory the caller
# happened to be in -- matching nothing, or matching someone else's tests -- and
# a suite that never ran its own files is indistinguishable from a green one.
cd "$(dirname "$0")/.." || { echo "${0##*/}: cannot reach the repository root" >&2; exit 1; }

# nullglob so an unmatched pattern yields an empty array rather than the literal
# glob string, which would otherwise be handed to bash as a filename.
shopt -s nullglob
tests=(tests/test-*.sh)
shopt -u nullglob

# Zero tests is a failure, not a pass — a silently empty suite in CI is
# indistinguishable from a green one.
if [ "${#tests[@]}" -eq 0 ]; then
  echo "no test files found matching tests/test-*.sh" >&2
  exit 1
fi

rc=0
for t in "${tests[@]}"; do
  printf '\n=== %s ===\n' "$t"
  bash "$t" || rc=1
done
exit "$rc"
