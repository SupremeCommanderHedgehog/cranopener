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

# Stdin: https://pypi.org/pypi/<package>/json. Prints the latest version.
#
# No sorting here, unlike Go and Julia: PyPI resolves "latest" itself and
# publishes it as a single scalar in .info.version, so there is no list whose
# ordering could be trusted wrongly. What PyPI will happily hand back is a
# pre-release when the project has published one more recently than any final,
# which is why main() shape-checks the result -- an `rc` baked into the image
# is a thing to find out during the build, not at the office.
parse_pypi_version() {
  jq -r '.info.version'
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
  local opencode go julia_json julia_ver julia_asset openhands aider

  if [ -n "${OPENCODE_VERSION_OVERRIDE:-}" ]; then
    opencode="${OPENCODE_VERSION_OVERRIDE#v}"
  else
    opencode=$(curl -fsSL "https://api.github.com/repos/${OPENCODE_REPO}/releases/latest" \
      | parse_opencode_version)
  fi

  # Overridable because these two are the harnesses, not the toolchain: when a
  # release breaks the run the office trip depends on, pinning back has to be a
  # one-variable change and not an edit to a file that CI also builds from.
  if [ -n "${OPENHANDS_VERSION_OVERRIDE:-}" ]; then
    openhands="${OPENHANDS_VERSION_OVERRIDE#v}"
  else
    openhands=$(curl -fsSL "https://pypi.org/pypi/openhands/json" | parse_pypi_version)
  fi

  if [ -n "${AIDER_VERSION_OVERRIDE:-}" ]; then
    aider="${AIDER_VERSION_OVERRIDE#v}"
  else
    aider=$(curl -fsSL "https://pypi.org/pypi/aider-chat/json" | parse_pypi_version)
  fi

  go=$(curl -fsSL "https://go.dev/dl/?mode=json" | parse_go_version)

  julia_json=$(curl -fsSL "https://julialang-s3.julialang.org/bin/versions.json")
  julia_ver=$(printf '%s' "$julia_json" | parse_julia_version)
  julia_asset=$(printf '%s' "$julia_json" | parse_julia_asset "$julia_ver")

  [ -n "$opencode" ] || { echo "failed to resolve opencode version" >&2; exit 1; }
  [ -n "$go" ]       || { echo "failed to resolve go version" >&2; exit 1; }
  [ -n "$julia_ver" ]|| { echo "failed to resolve julia version" >&2; exit 1; }
  [ -n "$openhands" ]|| { echo "failed to resolve openhands version" >&2; exit 1; }
  [ -n "$aider" ]    || { echo "failed to resolve aider version" >&2; exit 1; }

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

  # Anchored at both ends, unlike opencode above: this is the check that stops
  # a PyPI pre-release (1.17.0rc1, 1.17.0.dev3) from being installed into an
  # image that then goes somewhere it cannot be rebuilt.
  echo "$openhands" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "bad openhands version: $openhands" >&2; exit 1; }
  echo "$aider"     | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "bad aider version: $aider" >&2; exit 1; }

  printf 'OPENCODE_VERSION=%s\n' "$opencode"
  printf 'GO_VERSION=%s\n' "$go"
  printf 'JULIA_VERSION=%s\n' "$julia_ver"
  printf 'JULIA_URL=%s\n' "${julia_asset%% *}"
  printf 'JULIA_SHA256=%s\n' "${julia_asset##* }"
  printf 'OPENHANDS_VERSION=%s\n' "$openhands"
  printf 'AIDER_VERSION=%s\n' "$aider"
}

# Only run main when executed directly, so tests can source the parsers.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
