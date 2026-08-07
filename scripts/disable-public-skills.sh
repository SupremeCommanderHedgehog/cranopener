#!/usr/bin/env bash
# Runs at IMAGE BUILD TIME, as root. Stops the OpenHands CLI cloning the public
# skills repository from github.com on every startup.
#
# `AgentStore._build_agent_context()` hardcodes `load_public_skills=True`, and
# the SDK honours it by cloning -- or, against a warm cache, fetching, checking
# out and `reset --hard`ing -- github.com/OpenHands/extensions into
# ~/.openhands/cache/skills/public-skills before the agent starts. Every run,
# whether or not anything changed upstream.
#
# This is a patch to the installed package because there is no other lever.
# `_apply_runtime_config()` replaces `agent_context` on the agent
# unconditionally, so the flag in the generated agent_settings.json is thrown
# away before it is read; no environment variable switches it off (EXTENSIONS_REF
# only picks the branch); and a warm cache does not avoid the network call. The
# SDK's own field default is False -- this restores it.
#
# `load_user_skills` stays True on purpose: it reads local directories and opens
# no socket, so it is not part of the problem, and asserting it survived is how
# a careless future edit to this script gets caught.
#
# Every assertion below is load-bearing. The failure this whole file exists to
# prevent is not a crash -- it is this patch quietly becoming a no-op after an
# upstream rename or reformat, and the image resuming its per-run call to GitHub
# with nobody the wiser. So: the target must be present before, gone after, and
# the patched module must report the new value when it is actually imported.
#
# Usage: disable-public-skills.sh [path/to/agent_store.py]
#
# The optional path exists so the guard can be aimed at a mutated copy of the
# file and watched to fail; a guard nobody has watched fail is not a guard. The
# build never passes one. The site-packages path carries the interpreter's minor
# version, which moves the day uv resolves a different Python, so the real path
# is asked of the interpreter rather than written down here.
set -uo pipefail

PROG=$(basename "$0")

fail() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  printf '%s\n' \
    "  This patch keeps the OpenHands CLI from cloning" \
    "  github.com/OpenHands/extensions on every startup. It cannot be applied" \
    "  to a file it does not recognise, and it must never be skipped quietly:" \
    "  the image would ship and phone GitHub on every agent run at a site that" \
    "  does not tolerate it. If the installed openhands changed, re-read" \
    "  AgentStore._build_agent_context and update this script deliberately." >&2
  exit 1
}

# The line as upstream writes it, indentation included. A reformat is drift and
# must stop the build, not be absorbed.
TARGET='            load_public_skills=True,'
PATCHED='            load_public_skills=False,'
KEEP='            load_user_skills=True,'

FILE="${1:-}"
if [ -z "$FILE" ]; then
  # Asked of the interpreter that has the package, never assembled from a
  # hardcoded pythonX.Y path. stderr is dropped and the last line taken: the
  # import prints a banner and, on an unpatched install, the skills machinery
  # can log to the same terminal.
  FILE=$(OPENHANDS_SUPPRESS_BANNER=1 openhands-python -c \
    'import openhands_cli.stores.agent_store as m; print(m.__file__)' \
    2>/dev/null | tail -n 1)
  [ -n "$FILE" ] || fail "could not ask openhands-python where agent_store.py is"
fi

[ -f "$FILE" ] || fail "no such file: $FILE"

# The method, not the file. A flag of the same name somewhere else in the file
# is not this flag, and patching it would leave the real one set.
method_body() {
  awk 'f && /^    def / { exit } /^    def _build_agent_context\(/ { f = 1 } f' "$1"
}

BODY=$(method_body "$FILE")
[ -n "$BODY" ] || fail "no _build_agent_context method in $FILE"

n=$(printf '%s\n' "$BODY" | grep -c -x -- "$TARGET")
[ "$n" = 1 ] || fail "expected exactly one '$TARGET' in _build_agent_context, found $n"

printf '%s\n' "$BODY" | grep -q -x -- "$KEEP" \
  || fail "no '$KEEP' in _build_agent_context; refusing to patch a method this script no longer understands"

# File-wide, so the in-place edit below cannot reach a second occurrence.
n=$(grep -c -x -- "$TARGET" "$FILE")
[ "$n" = 1 ] || fail "expected exactly one '$TARGET' in $FILE, found $n"

sed -i "s|^${TARGET}\$|${PATCHED}|" "$FILE" || fail "sed failed on $FILE"

# sed -i writes a new inode; the tree was made world-readable for the
# unprivileged runtime user and the replacement has to stay that way.
chmod a+r "$FILE" || fail "could not restore read permission on $FILE"

# uv compiles bytecode at install time. A .pyc that outlives its source is the
# one way this patch could pass every text assertion and still not run.
rm -rf "$(dirname "$FILE")/__pycache__"

BODY=$(method_body "$FILE")
printf '%s\n' "$BODY" | grep -q -x -- "$PATCHED" \
  || fail "patch did not take: no '$PATCHED' in _build_agent_context"
grep -q -- 'load_public_skills=True' "$FILE" \
  && fail "load_public_skills=True still present in $FILE after patching"
printf '%s\n' "$BODY" | grep -q -x -- "$KEEP" \
  || fail "patch removed '$KEEP'; user skills are local-only and must stay on"

# The text is patched. Whether the interpreter agrees is a different question --
# see the .pyc note above -- so the answer comes from importing it and building
# the context the CLI builds. Skipped when a path was passed in, because that
# mode is aimed at a copy the interpreter does not import.
if [ -z "${1:-}" ]; then
  OPENHANDS_SUPPRESS_BANNER=1 openhands-python -c '
from openhands_cli.stores.agent_store import AgentStore
c = AgentStore()._build_agent_context()
assert c.load_public_skills is False, c.load_public_skills
assert c.load_user_skills is True, c.load_user_skills
' || fail "the imported module still does not report load_public_skills=False"
fi

printf '%s: patched %s\n' "$PROG" "$FILE"
