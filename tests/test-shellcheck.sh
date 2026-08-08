#!/usr/bin/env bash
# Lints every tracked shell script. The scripts in this repository are the
# deployment: seed-config.sh, entrypoint.sh and run-openhands.sh are what the
# image actually executes, and a quoting mistake in one of them surfaces at a
# site that is a monthly trip away. Nothing else here reads them.
set -uo pipefail
# Fatal: git and shellcheck are both run against repo-relative paths below.
cd "$(dirname "$0")/.." || { echo "${0##*/}: cannot reach the repository root" >&2; exit 1; }
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

# Same shape as the jq skip in test-resolve-versions.sh: one clear skip beats N
# identical failures, which train the reader to ignore red output. CI asserts
# the linter is present before running the suite, so a skip here can never mask
# a real regression -- it only spares an authoring machine that lacks it.
if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'SKIP %s: shellcheck is not installed\n' "${0##*/}"
  exit 0
fi

# Discovered, never listed. A hardcoded list stops covering new scripts the day
# someone adds one, and does it silently -- the suite stays green while the
# coverage shrinks. git ls-files is also what keeps untracked scratch files and
# anything vendored under a build directory out of scope.
#
# Which makes a git work tree a prerequisite like jq or PyYAML, and it is a real
# case rather than a hypothetical one: remote-build.sh syncs this repository to
# the build host with --exclude=.git, so the suite run there has no index to
# query. CI runs in a checkout, so this skip cannot hide a regression from main.
if ! command -v git >/dev/null 2>&1 \
   || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'SKIP %s: not a git work tree, so the file set cannot be discovered\n' "${0##*/}"
  exit 0
fi

# .githooks/* as well as *.sh: git requires hooks be named for the hook they
# implement, so pre-push carries no extension and a glob on one would skip the
# script standing between a mistake and a public push.
mapfile -t scripts < <(git ls-files '*.sh' '.githooks/*')

# Zero files is a failure, not a pass, for the same reason run-all.sh treats an
# empty glob as one: a lint that checked nothing looks exactly like a clean one.
assert_ok 'there are tracked shell scripts to lint' \
  test "${#scripts[@]}" -gt 0
if [ "${#scripts[@]}" -eq 0 ]; then
  finish
  exit 1
fi

# -x follows `. tests/lib/assert.sh` and the `# shellcheck source=` directives,
# so a helper that broke its callers is caught at the call site rather than only
# where it is defined. Without it every sourcing script reports SC1091 instead.
#
# The output is captured and printed in full on failure rather than being let
# through unconditionally: a passing run should say one line, and a failing one
# has to name the file, line and code or the reader has to rerun by hand to
# learn anything.
out=$(shellcheck -x "${scripts[@]}" 2>&1)
rc=$?

assert_eq "shellcheck is clean across ${#scripts[@]} tracked scripts" '0' "$rc"
if [ "$rc" -ne 0 ]; then
  printf -- '--- shellcheck %s ---\n%s\n' \
    "$(shellcheck --version | awk '/^version:/ {print $2}')" "$out"
fi

finish
