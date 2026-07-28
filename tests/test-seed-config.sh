#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

SEED=$(mktemp -d)
trap 'rm -rf "$SEED"' EXIT

# Build a fake /etc/opencode
mkdir -p "$SEED/src/agent"
printf '{"model":"default"}\n' > "$SEED/src/opencode.json"
printf '# house rules\n'       > "$SEED/src/AGENTS.md"
printf 'nested\n'              > "$SEED/src/agent/example.md"

run_seed() {
  HOME="$1" XDG_CONFIG_HOME="" CRANOPENER_SEED_SRC="$SEED/src" \
    bash scripts/seed-config.sh
}

# --- case 1: empty destination gets seeded ---
H1="$SEED/h1"; mkdir -p "$H1"
run_seed "$H1"
assert_eq "seeds opencode.json" \
  '{"model":"default"}' "$(cat "$H1/.config/opencode/opencode.json" 2>/dev/null)"
assert_eq "seeds AGENTS.md" \
  '# house rules' "$(cat "$H1/.config/opencode/AGENTS.md" 2>/dev/null)"
assert_eq "seeds nested files" \
  'nested' "$(cat "$H1/.config/opencode/agent/example.md" 2>/dev/null)"

# --- case 2: existing file is NEVER overwritten ---
H2="$SEED/h2"; mkdir -p "$H2/.config/opencode"
printf 'USER SETTINGS\n' > "$H2/.config/opencode/opencode.json"
run_seed "$H2"
assert_eq "does not clobber an existing opencode.json" \
  'USER SETTINGS' "$(cat "$H2/.config/opencode/opencode.json")"
assert_eq "still fills in files the user did not provide" \
  '# house rules' "$(cat "$H2/.config/opencode/AGENTS.md" 2>/dev/null)"

# --- case 3: idempotent ---
H3="$SEED/h3"; mkdir -p "$H3"
run_seed "$H3"
printf 'EDITED\n' > "$H3/.config/opencode/AGENTS.md"
run_seed "$H3"
assert_eq "second run does not revert user edits" \
  'EDITED' "$(cat "$H3/.config/opencode/AGENTS.md")"

# --- case 4: standard subdirectories always exist ---
H4="$SEED/h4"; mkdir -p "$H4"
run_seed "$H4"
for d in agent command plugin; do
  assert_ok "creates $d/ directory" test -d "$H4/.config/opencode/$d"
done

# --- case 5: XDG_CONFIG_HOME is honoured over HOME ---
H5="$SEED/h5"; XDG="$SEED/xdg5"; mkdir -p "$H5" "$XDG"
HOME="$H5" XDG_CONFIG_HOME="$XDG" CRANOPENER_SEED_SRC="$SEED/src" \
  bash scripts/seed-config.sh
assert_ok "respects XDG_CONFIG_HOME" test -f "$XDG/opencode/opencode.json"

# --- case 6: missing seed source is not an error ---
H6="$SEED/h6"; mkdir -p "$H6"
HOME="$H6" XDG_CONFIG_HOME="" CRANOPENER_SEED_SRC="$SEED/does-not-exist" \
  bash scripts/seed-config.sh
assert_eq "missing seed source exits cleanly" "0" "$?"

finish
