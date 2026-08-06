#!/usr/bin/env bash
# Measure the token cost of opencode's tool schemas.
#
# Runs where a container engine and the cranopener image are available. Starts
# a capture server, points a throwaway opencode session at it, and reports how
# much of the context window the tool definitions consume before any
# conversation happens.
#
#   IMAGE      image to probe          (default: cranopener:dev)
#   CONTEXT    context window, tokens  (default: 128000)
#   ENGINE     podman or docker        (default: podman)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-cranopener:dev}"
CONTEXT="${CONTEXT:-128000}"
ENGINE="${ENGINE:-podman}"
PORT="${PORT:-8899}"

WORK="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

command -v "$ENGINE" >/dev/null || { echo "no $ENGINE on PATH" >&2; exit 1; }

# A provider aimed at the capture server. opencode still builds and sends its
# full tool schema, which is the only thing we are after.
mkdir -p "$WORK/config" "$WORK/workspace"
cat > "$WORK/config/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "provider": {
    "capture": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "capture",
      "options": { "baseURL": "http://127.0.0.1:${PORT}/v1", "apiKey": "unused" },
      "models": { "probe": { "name": "probe" } }
    }
  },
  "permission": { "*": "deny" }
}
EOF

# Something has to exist in the workspace or opencode may not exercise its
# file tools when assembling the request.
echo "# probe" > "$WORK/workspace/README.md"

echo "==> starting capture server on :${PORT}"
python3 "$HERE/capture-request.py" "$WORK/captured.json" "$PORT" &
SERVER_PID=$!

for _ in $(seq 1 40); do
  python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(0.3)
sys.exit(0 if s.connect_ex(('127.0.0.1',${PORT}))==0 else 1)" && break
  sleep 0.25
done

echo "==> running opencode against the capture server"
# --network=host so the container reaches the capture server on the loopback
# interface. Permissions are denied in the config above, so the session cannot
# act on the workspace; it only has to get as far as composing one request.
timeout 180 "$ENGINE" run --rm --network=host \
  -v "$WORK/config:/home/opencode/.config/opencode:z" \
  -v "$WORK/workspace:/workspace:z" \
  "$IMAGE" \
  opencode run --model capture/probe "list the files in this directory" \
  >"$WORK/opencode.log" 2>&1 || true

kill "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

if [ ! -f "$WORK/captured.json" ]; then
  echo "no request was captured. opencode output:" >&2
  cat "$WORK/opencode.log" >&2
  exit 1
fi

echo
python3 "$HERE/count-tool-tokens.py" "$WORK/captured.json" --context "$CONTEXT"

# The captured body is the ground truth every shim transform test would be
# written against, so keep it. The model name can name an internal host.
mkdir -p "$HERE/../tests/fixtures"
python3 - "$WORK/captured.json" "$HERE/../tests/fixtures/opencode-request.json" <<'EOF'
import json, sys
req = json.load(open(sys.argv[1]))
req["model"] = "placeholder/model"
json.dump(req, open(sys.argv[2], "w"), indent=2)
EOF

echo
echo "fixture written to tests/fixtures/opencode-request.json"
