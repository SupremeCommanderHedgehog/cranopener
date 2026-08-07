#!/usr/bin/env bash
# Proves the provider-A path end to end against a fake tool-refusing upstream.
#
# Deliberately outside tests/run-all.sh: it needs a container engine and the
# built image, and the authoring machine's suite is offline by design.
# run-all.sh globs tests/test-*.sh at the top level only, so living here is what
# keeps it out. Run it on the build host, or anywhere that can run the image:
#
#   CRANOPENER_IMAGE=localhost/cranopener:dev bash tests/integration/openhands-wire.sh
#
# What it asserts is exactly what the office visit must not be spent
# discovering, because the endpoint is reachable from there about once a month:
#
#   - no request carries a `tools` array -- the claim the whole design rests on
#   - the conversation reaches at least four turns, past the point where
#     flattened history breaks; one successful turn proves almost nothing
#   - the harness actually wrote to the workspace
#   - the adapter's exit status reflects reality. The CLI it wraps exits 0 when
#     every single request fails, so a wrapper that trusts $? would ship a
#     broken configuration to the office and report green.
#
# The scripted turns come from tests/fake-upstream/scripts/openhands-multi-turn.json,
# which carries the action syntax the harness's own prompt asks for. That is
# test data copied out of a recorded request body, not a dialect this
# repository parses -- see the header in that file.
set -uo pipefail
# Fatal: the fixture, the stub server and the record directories below are all
# repo-relative. A run that started in the wrong tree would fail at the stub and
# read as a harness fault, on the machine where a rerun costs a 6GB image.
cd "$(dirname "$0")/../.." || { echo "${0##*/}: cannot reach the repository root" >&2; exit 1; }
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

IMAGE="${CRANOPENER_IMAGE:-ghcr.io/supremecommanderhedgehog/cranopener:latest}"
PORT="${CRANOPENER_FAKE_PORT:-8899}"
SCRIPT='tests/fake-upstream/scripts/openhands-multi-turn.json'
TASK='create a file called hello.txt containing the word hello'

for tool in podman python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FAIL %s: no %s -- this test needs a container engine and the built image\n' \
      "${0##*/}" "$tool"
    exit 2
  fi
done
if ! podman image exists "$IMAGE"; then
  printf 'FAIL %s: no image %s -- build it first, or set CRANOPENER_IMAGE\n' \
    "${0##*/}" "$IMAGE"
  exit 2
fi

WORK="$(mktemp -d)"
SERVER_PID=''

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# The container runs as uid 1000 and rootless podman maps the invoking user to
# container root, so a default 0700 mktemp directory is unreachable from
# inside. Read-only would not be enough either: the harness must write.
mkdir -p "$WORK"
chmod -R a+rwX "$WORK"

start_fake() {
  # $1 is the record directory. A fresh server per case, because the stub
  # numbers requests and walks the script from process start -- sharing one
  # across cases would interleave two conversations into one record.
  local rec="$1"
  mkdir -p "$rec"
  chmod -R a+rwX "$WORK"
  FAKE_PORT="$PORT" \
  FAKE_TOOLS_MODE=reject \
  FAKE_SCRIPT="$SCRIPT" \
  FAKE_RECORD_DIR="$rec" \
    python3 tests/fake-upstream/server.py >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!

  # Polled rather than slept. A fixed sleep is either too short on a loaded
  # build host -- where the failure is a connection refused that reads as a
  # harness fault -- or wasted time on every run. /dev/tcp keeps this free of
  # curl, which is not everywhere.
  local _
  for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
      exec 3>&- 2>/dev/null
      return 0
    fi
    sleep 0.2
  done
  echo "the fake upstream never came up on :$PORT" >&2
  cat "$WORK/server.log" >&2
  return 1
}

stop_fake() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  SERVER_PID=''
}

run_harness() {
  # $1 workspace, $2 log file, $3 base URL. Echoes the adapter's exit status.
  #
  # host.containers.internal is how the container reaches a server on the host;
  # --add-host makes podman provide it. `:Z` on the mount is not optional on an
  # SELinux host: without it the bind is unlabelled, every access inside is
  # denied, and the harness dies with "Permission denied: '/workspace'" on a
  # directory that is mode 0777. It is a no-op where SELinux is not enforcing.
  local ws="$1" log="$2" base="$3"
  # MAX_ITERATIONS is a bound here, not a budget, and it is deliberately
  # nowhere near what the fixture needs. The adapter counts every stream event
  # rather than agent steps -- an action and its observation are two events for
  # one step -- so the count is not the number of scripted turns. Measured
  # against this fixture: 11 stream events for its five turns. The 20 that used
  # to be here was therefore under a factor of two away, which two more turns
  # would cross. Crossing it fails the successful-run assertion while every
  # workspace assertion still passes, and that reads as the harness derailing
  # rather than as a test constant being too tight -- on the machine where a
  # rerun costs a 6GB image.
  #
  # A round number is the point, not an approximation of a tighter one.
  # Anything within a factor of two of the fixture's count would have to be
  # re-derived every time a turn is added to the script, and nothing here needs
  # the cap to be tight: a runaway is caught just as well at 200, because the
  # stub repeats its last scripted turn forever rather than ending the
  # conversation, and TIMEOUT_SECONDS is the real backstop.
  podman run --rm \
    --add-host "host.containers.internal:host-gateway" \
    -v "$ws:/workspace:Z" \
    -e CRANOPENER_SEED_SRC=/nonexistent \
    -e "CRANOPENER_LLM_BASE_URL=$base" \
    -e CRANOPENER_MAX_ITERATIONS=200 \
    -e CRANOPENER_TIMEOUT_SECONDS=240 \
    "$IMAGE" \
    run-openhands.sh openai/provider-a/fake "$TASK" \
    >"$log" 2>&1
  echo $?
}

count_requests() {
  # Counted by glob rather than `ls | wc -l`: the count feeds a `-ge 4`
  # assertion, and a pipeline that miscounts here reports a conversation that
  # never happened as four healthy turns. nullglob is what makes an empty
  # directory count 0 instead of 1 for the unexpanded pattern.
  local -a files
  shopt -s nullglob
  files=( "$1"/req-*.json )
  shopt -u nullglob
  echo "${#files[@]}"
}

count_with_tools() {
  # Parsed, never grepped. In prompt mode the tool definitions are rendered
  # INTO the system prompt, so the word "tools" is all over a perfectly correct
  # request body and a grep would report every one of them as a violation. The
  # claim is about the top-level `tools` key of the request -- the thing an
  # endpoint that refuses tool calling rejects -- and only a parse can tell
  # those apart.
  python3 - "$1" <<'PY'
import json
import os
import sys

directory = sys.argv[1]
offenders = 0
for name in sorted(os.listdir(directory)):
    if not name.startswith("req-"):
        continue
    with open(os.path.join(directory, name)) as handle:
        try:
            body = json.load(handle)
        except ValueError:
            continue
    if isinstance(body, dict) and "tools" in body:
        offenders += 1
        print("%s carries a top-level tools array" % name, file=sys.stderr)
print(offenders)
PY
}

# --- case 1: the path the office trip is for -------------------------------
OK_REC="$WORK/recorded-ok"
OK_WS="$WORK/workspace-ok"
mkdir -p "$OK_WS"
chmod -R a+rwX "$WORK"

start_fake "$OK_REC" || { finish; exit 1; }
ok_rc=$(run_harness "$OK_WS" "$WORK/ok.log" "http://host.containers.internal:$PORT/v1")
stop_fake

ok_count=$(count_requests "$OK_REC")
ok_tools=$(count_with_tools "$OK_REC")

# The claim the whole design rests on. If a tools array reaches the wire, the
# harness is not in prompt mode and provider A rejects every request.
assert_eq 'no request carried a tools array' '0' "$ok_tools"

# Turn three is where flattened history breaks, so turn four is the evidence
# that matters. A single successful turn only proves a socket opened.
assert_ok "the conversation reached at least four turns (reached $ok_count)" \
  test "$ok_count" -ge 4

assert_ok 'the harness wrote hello.txt to the workspace' \
  test -f "$OK_WS/hello.txt"

assert_eq 'the file it wrote has the content it was asked for' \
  'hello' "$(cat "$OK_WS/hello.txt" 2>/dev/null)"

assert_eq 'the adapter reported the successful run as success' '0' "$ok_rc"

# --- case 2: the same run when every request fails -------------------------
# The whole reason run-openhands.sh exists. Same image, same task, a base URL
# whose path the stub does not serve -- so every completion comes back 404 and
# the conversation cannot proceed. The requests are still made, which is what
# distinguishes this from a run that never dialled at all.
BAD_REC="$WORK/recorded-bad"
BAD_WS="$WORK/workspace-bad"
mkdir -p "$BAD_WS"
chmod -R a+rwX "$WORK"

start_fake "$BAD_REC" || { finish; exit 1; }
bad_rc=$(run_harness "$BAD_WS" "$WORK/bad.log" "http://host.containers.internal:$PORT/nope/v1")
stop_fake

bad_count=$(count_requests "$BAD_REC")

assert_ok "the failing run still reached the endpoint ($bad_count request(s))" \
  test "$bad_count" -ge 1

assert_ok "the adapter reported the failing run as a failure (exit $bad_rc)" \
  test "$bad_rc" -ne 0

# The premise the adapter's whole event-stream reading exists for, asserted
# rather than assumed -- it is the adapter's own record of what the CLI
# returned for the run above. If this ever fails, that is news and not a
# defect: the CLI would have started reporting failure honestly, and the
# machinery in run-openhands.sh could be reconsidered. Until then, anything
# that trusts $? here ships green.
assert_ok 'the CLI underneath it exited 0 on that same failure' \
  grep -q 'the harness itself exited 0' "$WORK/bad.log"

# Printed only on a failure, and then in full enough to diagnose without a
# second run -- the image is 6GB and the build host is remote, so "run it again
# with more output" is an expensive instruction.
if [ "$TESTS_FAILED" -ne 0 ]; then
  for log in ok bad; do
    printf -- '--- %s.log (last 40 lines) ---\n' "$log"
    tail -40 "$WORK/$log.log"
  done
fi

finish
