#!/usr/bin/env bash
# A secrets check that cannot fail is worse than none: it reports clean on a
# repository that is leaking and nobody looks again. These assertions plant one
# violation per rule and require the checker to catch each.
#
# Every planted value is assembled at runtime from fragments, so this file
# never contains a credential-shaped literal for the checker to find in itself.
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "${0##*/}: cannot reach the repository root" >&2; exit 1; }
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

CHECK='scripts/check-secrets.sh'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Runs the checker over one planted file. Prints its output; the caller greps.
planted() {
  local name="$1" content="$2"
  printf '%s\n' "$content" > "$WORK/$name"
  bash "$CHECK" "$WORK/$name" 2>&1
}

caught() {
  local desc="$1" name="$2" content="$3" rule="$4"
  local out
  out=$(planted "$name" "$content")
  if printf '%s' "$out" | grep -q "$rule"; then
    assert_eq "$desc" 'caught' 'caught'
  else
    assert_eq "$desc" "caught ($rule)" "MISSED -- checker said: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fi
}

# --- the clean case ---------------------------------------------------------
# First, because every assertion below is meaningless if the checker simply
# reports everything as a finding.
printf 'baseURL: http://localhost:4000/v1\napi_key: os.environ/PROVIDER_A_API_KEY\n' > "$WORK/clean.yaml"
bash "$CHECK" "$WORK/clean.yaml" >/dev/null 2>&1
assert_eq 'an innocent file passes' '0' "$?"

# --- one planted violation per rule ----------------------------------------
caught 'a GitHub token is caught' 'a.txt' \
  "token = gh""p_$(printf 'A%.0s' $(seq 1 36))" 'credential-shaped token'

caught 'an AWS access key id is caught' 'b.txt' \
  "id = AK""IA$(printf 'B%.0s' $(seq 1 16))" 'credential-shaped token'

caught 'a private key block is caught' 'c.txt' \
  "-----BE""GIN RSA PRIVATE KEY-----" 'credential-shaped token'

caught 'a literal api key is caught' 'd.yaml' \
  'api_key: "9f2b7c1d4e8a3f6b2c9d"' 'credential written as a literal'

caught 'a literal bearer token is caught' 'e.txt' \
  "Authorization: Bea""rer 9f2b7c1d4e8a3f6b2c9d5e" 'credential written as a literal'

# Assembled, like the tokens above. A tracked file in a public repository has
# no business containing a .mil or .gov hostname even a fabricated one, and a
# history scan that has to be told to ignore its own test fixtures is a
# history scan nobody trusts.
caught 'a .mil hostname is caught' 'f.yaml' \
  "api_base: https://api.example-host.""mil/v1" '.mil or .gov hostname'

caught 'a .gov hostname is caught' 'g.yaml' \
  "api_base: https://data.example-host.""gov/v1" '.mil or .gov hostname'

caught 'a routable IP literal is caught' 'h.txt' \
  'PROXY=http://203.0.113.9:8080' 'IP address literal'

caught 'a real-looking username in a path is caught' 'i.txt' \
  'cert: C:\Users\jsmith\certs\roots.pem' 'username in an absolute path'

caught 'a vendor-specific key variable is caught' 'j.sh' \
  'export ACMECORP_API_KEY=x' 'provider-specific API key variable name'

# --- the placeholders this repository actually uses must NOT trip ----------
# A rule that flags the documentation is a rule that gets disabled.
for ok in 'path: C:\Users\me\proj' \
          'path: C:\Users\my proj' \
          'a raw C:\Users\... parses as' \
          'baseURL: http://127.0.0.1:4000/v1' \
          'listen: 0.0.0.0' \
          'key: os.environ/PROVIDER_B_API_KEY' \
          'apiKey: "unused"' \
          'model: provider-a/PLACEHOLDER-MODEL'; do
  printf '%s\n' "$ok" > "$WORK/ok.txt"
  bash "$CHECK" "$WORK/ok.txt" >/dev/null 2>&1
  assert_eq "placeholder is not flagged: ${ok:0:38}" '0' "$?"
done

# --- the repository itself --------------------------------------------------
# The check that matters on every run: this tree is clean right now.
bash "$CHECK" >/dev/null 2>&1
assert_eq 'the tracked tree is clean' '0' "$?"

# --- the tracked-path rule --------------------------------------------------
# The likeliest real leak here is not a pasted key, it is committing docs/.
assert_eq 'docs/ is not tracked' '' "$(git ls-files -- docs/)"
assert_eq 'the probe output directory is not tracked' '' "$(git ls-files -- 'spike/office/out/**')"

finish
