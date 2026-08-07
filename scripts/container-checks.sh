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
check "gh present"             gh --version
check "node present"           node --version
check "npm present"            npm --version
check "npx present"            npx --version
check "pnpm present"           pnpm --version
check "uv present"             uv --version
check "go present"              go version
check "rustc present"          rustc --version
check "cargo present"          cargo --version
check "cargo toolchain not world-writable" \
  sh -c 'test ! -w /usr/local/cargo/bin/cargo'
# The single quotes are the check. $CARGO_HOME must be resolved by the shell
# that runs inside the image, from the image's own environment. Double quotes
# would expand it here instead, testing whatever value this script's shell holds
# -- empty, in the normal case, which makes `test -w ""` fail and reports a
# correctly configured image as broken.
# shellcheck disable=SC2016
check "user cargo home is writable"        \
  sh -c 'test -w "$CARGO_HOME"'
check "dotnet present"         dotnet --version
check "F# interactive present" dotnet fsi --version
check "julia present"          julia --version
check "R present"              R --version

# Agent harnesses. Both ship pre-installed because the fallback has to already
# be on the machine when the primary fails at a site that is a monthly trip
# away and behind a proxy with its own CA bundle.
check "openhands present"      openhands --help
check "aider present"          aider --version
# The generator builds a real openhands.sdk.Agent, so it needs the interpreter
# the SDK was installed into. If this symlink breaks, the adapter fails with an
# ImportError that reads like a broken image rather than a moved path.
check "openhands SDK importable" \
  openhands-python -c 'from openhands.sdk import LLM, Agent'
# The CLI hardcodes load_public_skills=True, which makes the SDK clone or fetch
# github.com/OpenHands/extensions on every single startup; the build patches
# that out (see the Dockerfile). Asserted by building the context the CLI builds
# and reading the flag off it, so a stale .pyc or a patch that landed in the
# wrong place fails here rather than in the field. An unpatched image fails this
# check -- it answers True.
check "openhands public skills disabled" \
  openhands-python -c 'from openhands_cli.stores.agent_store import AgentStore
c = AgentStore()._build_agent_context()
raise SystemExit(0 if (c.load_public_skills is False and c.load_user_skills is True) else 1)'
check "settings generator present" \
  test -f /usr/local/lib/cranopener/make-openhands-settings.py
check "run-openhands present"  test -x /usr/local/bin/run-openhands.sh
# Cheap proof the adapter is wired rather than merely copied, and it needs no
# network: a model with no litellm provider prefix is refused before anything
# else happens, because litellm would otherwise give up before opening a
# socket and the run would exit 0 having sent nothing.
check "run-openhands refuses a model with no litellm prefix" \
  sh -c '! run-openhands.sh bare-model write a file'

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
