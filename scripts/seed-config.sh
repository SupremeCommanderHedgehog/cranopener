#!/usr/bin/env bash
# Seed default opencode config without ever overwriting existing files.
set -euo pipefail

SRC="${CRANOPENER_SEED_SRC:-/etc/opencode}"
CONFIG_HOME="${XDG_CONFIG_HOME:-}"
[ -n "$CONFIG_HOME" ] || CONFIG_HOME="$HOME/.config"
DEST="$CONFIG_HOME/opencode"

# Nothing to seed is not an error.
[ -d "$SRC" ] || exit 0

mkdir -p "$DEST"

# Mirror directory structure.
while IFS= read -r -d '' dir; do
  rel="${dir#"$SRC"}"
  rel="${rel#/}"
  [ -n "$rel" ] || continue
  mkdir -p "$DEST/$rel"
done < <(find "$SRC" -type d -print0)

# Copy only files that do not already exist.
while IFS= read -r -d '' src; do
  rel="${src#"$SRC"/}"
  dst="$DEST/$rel"
  if [ ! -e "$dst" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
  fi
done < <(find "$SRC" -type f -print0)

# These are always expected to exist, even when shipped empty.
for d in agent command plugin; do
  mkdir -p "$DEST/$d"
done

exit 0
