#!/usr/bin/env bash
# Minimal assertion helpers. Source this; call assert_eq/assert_ok/finish.

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    printf 'ok   %s\n' "$desc"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' \
      "$desc" "$expected" "$actual"
  fi
}

assert_ok() {
  local desc="$1"; shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@" >/dev/null 2>&1; then
    printf 'ok   %s\n' "$desc"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL %s (command failed: %s)\n' "$desc" "$*"
  fi
}

# For asserting a string is ABSENT. `assert_ok ! grep ...` does not work: the
# helper runs its arguments as a command, and `!` is shell syntax.
assert_not_ok() {
  local desc="$1"; shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@" >/dev/null 2>&1; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL %s (command unexpectedly succeeded: %s)\n' "$desc" "$*"
  else
    printf 'ok   %s\n' "$desc"
  fi
}

finish() {
  printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
