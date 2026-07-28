#!/usr/bin/env bash
# Resolve the current version of every unpinned tool.
# Prints KEY=value lines suitable for $GITHUB_OUTPUT or `set -a; . file`.
set -euo pipefail

OPENCODE_REPO="${OPENCODE_REPO:-anomalyco/opencode}"

parse_opencode_version() {
  jq -r '.tag_name' | sed 's/^v//'
}

# Sort numerically rather than trusting the API's ordering: taking the first
# stable entry would silently ship an older Go if go.dev ever reorders, and
# every assertion would still pass.
parse_go_version() {
  jq -r '
    [ .[]
      | select(.stable == true)
      | .version
      | ltrimstr("go")
      | select(test("^[0-9]+[.][0-9]+([.][0-9]+)?$")) ]
    | sort_by(split(".") | map(tonumber))
    | last
  '
}

# Character class [.] instead of \. — survives shell quoting layers.
parse_julia_version() {
  jq -r '
    [ to_entries[]
      | select(.value.stable == true)
      | select(.key | test("^[0-9]+[.][0-9]+[.][0-9]+$"))
      | .key ]
    | sort_by(split(".") | map(tonumber))
    | last
  '
}

# Args: version. Stdin: versions.json. Prints "<url> <sha256>".
parse_julia_asset() {
  jq -r --arg v "$1" '
    .[$v].files[]
    | select(.triplet == "x86_64-linux-gnu")
    | "\(.url) \(.sha256)"
  '
}

main() {
  local opencode go julia_json julia_ver julia_asset

  if [ -n "${OPENCODE_VERSION_OVERRIDE:-}" ]; then
    opencode="${OPENCODE_VERSION_OVERRIDE#v}"
  else
    opencode=$(curl -fsSL "https://api.github.com/repos/${OPENCODE_REPO}/releases/latest" \
      | parse_opencode_version)
  fi

  go=$(curl -fsSL "https://go.dev/dl/?mode=json" | parse_go_version)

  julia_json=$(curl -fsSL "https://julialang-s3.julialang.org/bin/versions.json")
  julia_ver=$(printf '%s' "$julia_json" | parse_julia_version)
  julia_asset=$(printf '%s' "$julia_json" | parse_julia_asset "$julia_ver")

  [ -n "$opencode" ] || { echo "failed to resolve opencode version" >&2; exit 1; }
  [ -n "$go" ]       || { echo "failed to resolve go version" >&2; exit 1; }
  [ -n "$julia_ver" ]|| { echo "failed to resolve julia version" >&2; exit 1; }

  [ -n "$julia_asset" ] || { echo "failed to resolve julia asset for $julia_ver" >&2; exit 1; }
  if [ "$(printf '%s\n' "$julia_asset" | wc -l)" -ne 1 ]; then
    echo "julia asset selector matched multiple files for $julia_ver" >&2
    exit 1
  fi

  echo "$opencode"  | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' || { echo "bad opencode version: $opencode" >&2; exit 1; }
  echo "$go"        | grep -qE '^[0-9]+\.[0-9]+' || { echo "bad go version: $go" >&2; exit 1; }
  echo "$julia_ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "bad julia version: $julia_ver" >&2; exit 1; }
  echo "${julia_asset%% *}" | grep -qE '^https://' || { echo "bad julia url" >&2; exit 1; }
  echo "${julia_asset##* }" | grep -qE '^[0-9a-f]{64}$' || { echo "bad julia sha256" >&2; exit 1; }

  printf 'OPENCODE_VERSION=%s\n' "$opencode"
  printf 'GO_VERSION=%s\n' "$go"
  printf 'JULIA_VERSION=%s\n' "$julia_ver"
  printf 'JULIA_URL=%s\n' "${julia_asset%% *}"
  printf 'JULIA_SHA256=%s\n' "${julia_asset##* }"
}

# Only run main when executed directly, so tests can source the parsers.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
