#!/usr/bin/env bash
# Refuse to publish anything this repository must not carry.
#
# This repository is PUBLIC and the whole design keeps real endpoints, model
# identifiers, hostnames, and credentials out of it -- docs/ is gitignored for
# that reason alone. This is the check that makes that a rule rather than a
# habit. It runs in CI and from .githooks/pre-push.
#
# Usage: bash scripts/check-secrets.sh [file...]
#
#   With no arguments it scans every TRACKED file (git ls-files). Untracked and
#   gitignored files are never read: docs/ holds the real values on purpose,
#   and a checker that opened it could echo them into a log.
#
#   With arguments it scans exactly those files and skips the tracked-path
#   check. That form exists for tests/test-check-secrets.sh.
#
# Exit status:
#   0  nothing found
#   1  something found -- every hit is printed with its file and line
#   2  usage or environment error
#
# Local denylist (optional): docs/secret-denylist.txt, one literal string per
# line, blank lines and #-comments ignored. It is gitignored along with the
# rest of docs/, which is the point -- the strings that must never appear can
# live there without this repository publishing them. Keep real endpoints,
# hostnames, usernames, and proxy addresses in it.
#
# The rules below are ALLOWLISTS wherever naming the bad value would disclose
# it. A denylist of forbidden hostnames would have to spell out the very names
# it exists to keep out, in the public file that keeps them out.
#
# This script and its test exclude themselves from the scan: both necessarily
# contain credential-shaped patterns. Do not paste a real value into either.
set -uo pipefail

cd "$(dirname "$0")/.." || { echo "check-secrets.sh: cannot reach the repo root" >&2; exit 2; }

SELF='scripts/check-secrets.sh'
SELF_TEST='tests/test-check-secrets.sh'
DENYLIST='docs/secret-denylist.txt'

findings=0

# Prints a finding. Never echoes the matched value for the denylist rule --
# that value is the secret, and this output goes to CI logs.
report() {
  findings=$((findings + 1))
  printf 'SECRET-CHECK: %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /'
  return 0
}

scan_explicit=0
if [ "$#" -gt 0 ]; then
  scan_explicit=1
  FILES=("$@")
else
  command -v git >/dev/null 2>&1 || { echo "check-secrets.sh: no git on PATH" >&2; exit 2; }
  mapfile -t FILES < <(git ls-files | grep -vxF "$SELF" | grep -vxF "$SELF_TEST")
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "check-secrets.sh: nothing to scan" >&2
  exit 2
fi

# Binary files produce noise and cannot hold a reviewable secret in text form.
TEXT=()
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null && TEXT+=("$f")
done

# --- 1. gitignored-sensitive paths must not be tracked ---------------------
# The likeliest real leak in this repo is not a pasted key, it is `git add -f
# docs/` -- the one directory that holds every real endpoint by design.
if [ "$scan_explicit" -eq 0 ]; then
  tracked=$(git ls-files -- docs/ 'spike/office/out/**' spike/RESULTS.md \
                             .env 'auth.json' '*.pem' '*.key' '*.gpg' '*.asc' \
                             .opencode/ .claude/ 'AGENTS.local.md' 'CLAUDE.local.md' 2>/dev/null)
  [ -n "$tracked" ] && report 'gitignored-sensitive paths are TRACKED' "$tracked"
fi

# --- 2. credential-shaped tokens -------------------------------------------
# Generic formats only. GitHub's own secret scanning covers public repos too;
# this catches them before the push rather than after.
tokens=$(grep -nEI \
  -e 'gh[pousr]_[A-Za-z0-9]{20,}' \
  -e 'github_pat_[A-Za-z0-9_]{20,}' \
  -e 'AKIA[0-9A-Z]{16}' \
  -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
  -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
  -e 'AIza[0-9A-Za-z_-]{30,}' \
  "${TEXT[@]}" 2>/dev/null)
[ -n "$tokens" ] && report 'credential-shaped token' "$tokens"

# --- 3. a credential written as a literal ----------------------------------
# api_key: "sk-..." and Authorization: Bearer <literal>. os.environ/ and
# ${VAR} forms are how this repo is supposed to do it and are left alone.
literals=$(grep -nEI \
  -e '(api_?key|apikey|password|passwd|secret|token)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'$<{[:space:]]{12,}' \
  -e 'Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{16,}' \
  "${TEXT[@]}" 2>/dev/null \
  | grep -vE 'os\.environ|\$\{|\{env:|PLACEHOLDER|EXAMPLE|example|unused|not-a-real')
[ -n "$literals" ] && report 'a credential written as a literal' "$literals"

# --- 4. real hostnames ------------------------------------------------------
# Extends the kube/-only check in tests/test-kube-templates.sh to every
# tracked file. Which networks this runs on is not for a public repository.
hosts=$(grep -nEIo '[a-z0-9][a-z0-9-]*\.(mil|gov)\b' "${TEXT[@]}" 2>/dev/null)
[ -n "$hosts" ] && report 'a .mil or .gov hostname' "$hosts"

# --- 5. IP literals ---------------------------------------------------------
# Loopback and unspecified are configuration, not disclosure. Anything else is
# an address on somebody's network -- a proxy, a router, an internal host.
ips=$(grep -nEIo '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "${TEXT[@]}" 2>/dev/null \
  | grep -vE ':(127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.255|1\.2\.3\.4|0\.0\.0\.1)$')
[ -n "$ips" ] && report 'an IP address literal' "$ips"

# --- 6. real usernames in absolute paths ------------------------------------
# C:\Users\me and friends are documentation. A real account name is an
# identity, and it is exactly what a Windows path in an example leaks.
users=$(grep -nEIo 'C:[\\/]Users[\\/][A-Za-z0-9._-]+' "${TEXT[@]}" 2>/dev/null \
  | grep -viE '[\\/](me|my|user|users|you|yourname|username|someone|test|example|\.{3}|<[a-z]+>)$')
[ -n "$users" ] && report 'a real-looking username in an absolute path' "$users"

# --- 7. provider env vars stay generic --------------------------------------
# Allowlist, not denylist: which vendor sits behind PROVIDER_A is local
# configuration, and naming it discloses an affiliation that cannot be taken
# back once indexed.
envs=$(grep -rIohE '\b[A-Z][A-Z0-9_]*_API_KEY\b' "${TEXT[@]}" 2>/dev/null \
  | sort -u \
  | grep -vxE '(PROVIDER_[ABC]|ANTHROPIC|OPENAI|CRANOPENER_LLM|PROBE|GENERIC)_API_KEY')
[ -n "$envs" ] && report 'a provider-specific API key variable name' "$envs"

# --- 8. the local denylist --------------------------------------------------
# The file name and line are printed; the matched string never is.
if [ "$scan_explicit" -eq 0 ] && [ -f "$DENYLIST" ]; then
  patterns=$(grep -vE '^[[:space:]]*(#|$)' "$DENYLIST")
  if [ -n "$patterns" ]; then
    hits=$(printf '%s\n' "$patterns" | grep -nIFf - "${TEXT[@]}" 2>/dev/null | cut -d: -f1,2 | sort -u)
    [ -n "$hits" ] && report 'a string from the local denylist (value withheld)' "$hits"
  fi
fi

echo
if [ "$findings" -eq 0 ]; then
  echo "check-secrets.sh: clean (${#TEXT[@]} tracked text files scanned)"
  [ "$scan_explicit" -eq 0 ] && [ ! -f "$DENYLIST" ] && \
    echo "  note: no $DENYLIST -- add one to catch this site's own identifiers."
  exit 0
fi

echo "check-secrets.sh: $findings rule(s) matched. Nothing was pushed."
echo "  This repository is public. If a value above is real, do NOT just amend"
echo "  the file -- assume it is compromised and rotate it."
exit 1
