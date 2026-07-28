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

# The fixture must be reachable by the container's uid 1000 regardless of the
# developer's umask and of how the engine maps UIDs. Rootless podman maps the
# host user to container root, so a umask-077 fixture is invisible to uid 1000
# and the test would fail for reasons that have nothing to do with seeding.
# These are ephemeral temp files, so wide permissions are safe here.
chmod -R 0777 "$TMP"

OUT=$("$ENGINE" run --rm \
  -v "$TMP:/home/opencode/.config:Z" \
  "$IMAGE" cat /home/opencode/.config/opencode/opencode.json 2>/dev/null)

if [ "$OUT" = "USER SETTINGS" ]; then
  echo "ok   mounted opencode.json survived seeding"
else
  echo "FAIL mounted opencode.json was clobbered (got: ${OUT:-<empty>})"
  RC=1
fi

# The check above would also pass if seeding never ran at all. Prove it did:
# AGENTS.md was NOT in the mount, so it must have been filled in from defaults.
SEEDED=$("$ENGINE" run --rm \
  -v "$TMP:/home/opencode/.config:Z" \
  "$IMAGE" sh -c 'test -f /home/opencode/.config/opencode/AGENTS.md && echo yes || echo no' 2>/dev/null)

if [ "$SEEDED" = "yes" ]; then
  echo "ok   seeding still filled in files absent from the mount"
else
  echo "FAIL seeding did not run against the mount (AGENTS.md missing)"
  RC=1
fi

echo
echo "=== version labels ==="
for lbl in org.opencontainers.image.version \
           dev.cranopener.go.version \
           dev.cranopener.julia.version \
           dev.cranopener.node.major \
           dev.cranopener.dotnet.channel; do
  val=$("$ENGINE" inspect --format "{{ index .Config.Labels \"$lbl\" }}" "$IMAGE" 2>/dev/null)
  if [ -n "$val" ] && [ "$val" != "<no value>" ]; then
    echo "ok   $lbl = $val"
  else
    echo "FAIL $lbl is empty"
    RC=1
  fi
done

echo
if [ "$RC" -eq 0 ]; then echo "SMOKE TEST PASSED"; else echo "SMOKE TEST FAILED"; fi
exit "$RC"
