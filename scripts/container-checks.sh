#!/usr/bin/env bash
# Runs INSIDE the image. Exits non-zero if any assertion fails.
set -uo pipefail

FAILED=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok   %s\n' "$desc"
  else
    printf 'FAIL %s\n' "$desc"
    FAILED=$((FAILED + 1))
  fi
}

check "git present"            git --version
check "git-lfs present"        git-lfs version
check "curl present"           curl --version
check "jq present"             jq --version
check "ripgrep present"        rg --version
check "fd present"             fd --version
check "less present"           less --version
check "unzip present"          unzip -v
check "gcc present"            gcc --version
check "g++ present"            g++ --version
check "make present"           make --version
check "cmake present"          cmake --version
check "python3 present"        python3 --version
check "opencode present"       opencode --version

# Config seeding must have run via the entrypoint.
check "seeded opencode.json"   test -f "$HOME/.config/opencode/opencode.json"
check "seeded AGENTS.md"       test -f "$HOME/.config/opencode/AGENTS.md"
check "seeded agent/ dir"      test -d "$HOME/.config/opencode/agent"
check "seeded command/ dir"    test -d "$HOME/.config/opencode/command"
check "seeded plugin/ dir"     test -d "$HOME/.config/opencode/plugin"

# Must not run as root.
check "runs as uid 1000"       test "$(id -u)" = "1000"
check "workdir is /workspace"  test "$PWD" = "/workspace"

# opencode version must match what the build intended.
if [ -n "${EXPECT_OPENCODE_VERSION:-}" ]; then
  actual=$(opencode --version 2>/dev/null | tr -d 'v \n')
  if [ "$actual" = "$EXPECT_OPENCODE_VERSION" ]; then
    printf 'ok   opencode version is %s\n' "$actual"
  else
    printf 'FAIL opencode version: expected %s, got %s\n' \
      "$EXPECT_OPENCODE_VERSION" "$actual"
    FAILED=$((FAILED + 1))
  fi
fi

printf '\ncontainer-checks: %d failed\n' "$FAILED"
[ "$FAILED" -eq 0 ]
