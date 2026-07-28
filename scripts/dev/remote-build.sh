#!/usr/bin/env bash
# Sync the working tree to a Linux build host, then build and smoke test.
# Configure via .env (gitignored) or the environment — see .env.example.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Local, gitignored developer configuration.
# shellcheck source=/dev/null
[ -f "$REPO_ROOT/.env" ] && . "$REPO_ROOT/.env"

HOST="${CRANOPENER_BUILD_HOST:?set CRANOPENER_BUILD_HOST (see .env.example)}"
KEY="${CRANOPENER_BUILD_KEY:?set CRANOPENER_BUILD_KEY (see .env.example)}"
DIR="${CRANOPENER_BUILD_DIR:-\$HOME/cranopener}"
TAG="${CRANOPENER_TAG:-cranopener:dev}"

# Expand a leading ~ in the key path.
KEY="${KEY/#\~/$HOME}"

echo "==> syncing $REPO_ROOT -> $HOST:$DIR"
ssh -i "$KEY" "$HOST" "mkdir -p '$DIR'"
tar -C "$REPO_ROOT" --exclude=.git -czf - . \
  | ssh -i "$KEY" "$HOST" "tar -xzf - -C '$DIR'"

echo "==> resolving versions on build host"
# shellcheck disable=SC2029
ssh -i "$KEY" "$HOST" "cd '$DIR' && bash scripts/resolve-versions.sh > /tmp/cranopener.versions && cat /tmp/cranopener.versions"

echo "==> building $TAG"
ssh -i "$KEY" "$HOST" "cd '$DIR' && set -a && . /tmp/cranopener.versions && set +a && \
  podman build \
    --build-arg OPENCODE_VERSION=\"\$OPENCODE_VERSION\" \
    --build-arg GO_VERSION=\"\$GO_VERSION\" \
    --build-arg JULIA_VERSION=\"\$JULIA_VERSION\" \
    --build-arg JULIA_URL=\"\$JULIA_URL\" \
    --build-arg JULIA_SHA256=\"\$JULIA_SHA256\" \
    -t '$TAG' ."

echo "==> smoke testing $TAG"
ssh -i "$KEY" "$HOST" "cd '$DIR' && CONTAINER_ENGINE=podman bash scripts/smoke-test.sh '$TAG'"
