#!/usr/bin/env bash
# Host-side smoke test driver. Usage: smoke-test.sh <image-ref>
set -uo pipefail

IMAGE="${1:?usage: smoke-test.sh <image-ref>}"
ENGINE="${CONTAINER_ENGINE:-podman}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RC=0

echo "=== in-container checks ==="
"$ENGINE" run --rm -i \
  -e "EXPECT_OPENCODE_VERSION=${EXPECT_OPENCODE_VERSION:-}" \
  "$IMAGE" bash -s < "$HERE/container-checks.sh" || RC=1

echo
echo "=== mounted config must not be clobbered ==="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/opencode"
printf 'USER SETTINGS\n' > "$TMP/opencode/opencode.json"

OUT=$("$ENGINE" run --rm \
  -v "$TMP:/home/opencode/.config:Z" \
  "$IMAGE" cat /home/opencode/.config/opencode/opencode.json 2>/dev/null)

if [ "$OUT" = "USER SETTINGS" ]; then
  echo "ok   mounted opencode.json survived seeding"
else
  echo "FAIL mounted opencode.json was clobbered (got: ${OUT:-<empty>})"
  RC=1
fi

echo
if [ "$RC" -eq 0 ]; then echo "SMOKE TEST PASSED"; else echo "SMOKE TEST FAILED"; fi
exit "$RC"
