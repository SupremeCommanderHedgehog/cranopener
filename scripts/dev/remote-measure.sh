#!/usr/bin/env bash
# Run the tool-schema measurement on the Linux build host and bring the
# results back. Uses the same .env configuration as remote-build.sh.
#
# Unlike remote-build.sh this does not clear the build directory or rebuild
# anything -- it syncs only the spike tooling into its own directory and runs
# against an image that already exists on the host.
#
#   CRANOPENER_TAG   image to probe (default: cranopener:dev)
#   CONTEXT          context window in tokens (default: 128000)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck source=/dev/null
[ -f "$REPO_ROOT/.env" ] && . "$REPO_ROOT/.env"

HOST="${CRANOPENER_BUILD_HOST:?set CRANOPENER_BUILD_HOST (see .env.example)}"
KEY="${CRANOPENER_BUILD_KEY:?set CRANOPENER_BUILD_KEY (see .env.example)}"
TAG="${CRANOPENER_TAG:-cranopener:dev}"
CONTEXT="${CONTEXT:-128000}"

KEY="${KEY/#\~/$HOME}"

DIR=$(ssh -i "$KEY" "$HOST" 'echo "$HOME/cranopener-spike"')

echo "==> syncing spike tooling -> $HOST:$DIR"
ssh -i "$KEY" "$HOST" "rm -rf '$DIR' && mkdir -p '$DIR/spike' '$DIR/tests/fixtures'"
tar -C "$REPO_ROOT" -czf - spike \
  | ssh -i "$KEY" "$HOST" "tar -xzf - -C '$DIR'"

echo "==> confirming the image exists on the host"
if ! ssh -i "$KEY" "$HOST" "podman image exists '$TAG'"; then
  echo "image '$TAG' not found on $HOST." >&2
  echo "Build it first: bash scripts/dev/remote-build.sh" >&2
  exit 1
fi

echo "==> measuring"
# shellcheck disable=SC2029
ssh -i "$KEY" "$HOST" "cd '$DIR' && IMAGE='$TAG' CONTEXT='$CONTEXT' ENGINE=podman bash spike/measure-tool-schema.sh"

echo
echo "==> retrieving the captured request fixture"
ssh -i "$KEY" "$HOST" "cat '$DIR/tests/fixtures/opencode-request.json'" \
  > "$REPO_ROOT/tests/fixtures/opencode-request.json"

echo "wrote tests/fixtures/opencode-request.json ($(wc -c < "$REPO_ROOT/tests/fixtures/opencode-request.json") bytes)"
