#!/usr/bin/env bash
# The office probe gets one run a month. These assertions pin what it records
# about the REQUEST -- the half that was missing when August produced neither
# an answer nor a diagnosis. See docs/hazards.md.
#
# Runs against a local stub, so it is offline and belongs in run-all.sh.
set -uo pipefail
# Fatal: the paths below are repo-relative, and assertions run against a tree
# that does not hold them fail in ways that read like a broken fixture.
cd "$(dirname "$0")/.." || { echo "${0##*/}: cannot reach the repository root" >&2; exit 1; }
# shellcheck source=tests/lib/assert.sh
. tests/lib/assert.sh

for tool in curl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'SKIP %s: %s is not installed\n' "${0##*/}" "$tool"
    exit 0
  }
done

PROBE='spike/office/probe.sh'
WORK="$(mktemp -d)"
STUB_PID=''
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- configuration refusal, with no server involved ------------------------
# The one behaviour the trip already relies on: run it with nothing set and it
# names every missing variable rather than issuing a request against an empty
# URL.
( unset PROBE_BASE_URL PROBE_MODEL PROBE_API_KEY
  bash "$PROBE" "$WORK/unconfigured" >/dev/null 2>&1 )
assert_eq 'an unconfigured probe exits 2' '2' "$?"

# --- start the stub --------------------------------------------------------
PORT_FILE="$WORK/port"
REQ_LOG="$WORK/requests.jsonl"
: > "$REQ_LOG"
python3 tests/probe-stub/server.py "$PORT_FILE" "$REQ_LOG" &
STUB_PID=$!

for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
PORT="$(cat "$PORT_FILE" 2>/dev/null)"
if [ -z "$PORT" ]; then
  echo "${0##*/}: the stub never reported a port" >&2
  exit 1
fi

export PROBE_BASE_URL="http://127.0.0.1:$PORT/v1"
export PROBE_MODEL='stub-model'
export PROBE_API_KEY='not-a-real-key'

# --- a normal run ----------------------------------------------------------
# A short ladder: the point here is what gets recorded, not how big the window
# is, and an 800KB body buys nothing against a stub.
OUT="$WORK/out"
PROBE_CONTEXT_LADDER='4000 2000' bash "$PROBE" "$OUT" >/dev/null 2>&1

# The kit's promise is that a failed trip is diagnosable at a desk. The probe's
# own stdout carries the only account of a step that failed before it reached
# curl -- in August it went to a terminal at the office and is gone.
assert_ok 'the probe captures its own output' test -s "$OUT/00-probe-log.txt"

# The field whose absence made the August failure undiagnosable. Without it
# there is no way to tell a body curl never sent from a body something dropped
# in flight, and those have opposite fixes.
missing_upload=''
for meta in "$OUT"/*-meta.txt; do
  grep -q '^size_upload=' "$meta" || missing_upload="$missing_upload $(basename "$meta")"
done
assert_eq 'every request records the bytes curl put on the wire' '' "$missing_upload"

# size_upload is what curl claims it sent; this is what the probe believes it
# asked for. They agree or something between them is wrong -- which is exactly
# the question August could not answer.
missing_bytes=''
for meta in "$OUT"/*-meta.txt; do
  case "$(basename "$meta")" in
    01a-*) continue ;;  # GET, no body by design
  esac
  grep -q '^request_bytes=' "$meta" || missing_bytes="$missing_bytes $(basename "$meta")"
done
assert_eq 'every POST records the size of the body it meant to send' '' "$missing_bytes"

# The end-to-end version of the same claim, asserted from the far side of the
# wire rather than from curl's own report.
# The log path goes in argv, never inside the script text: MSYS translates a
# path-shaped argument into the Windows form python understands and leaves
# string literals alone, so an embedded path opens nothing on this machine.
empty_arrivals=$(python3 - "$REQ_LOG" <<'PY'
import json
import sys

print(sum(
    1 for line in open(sys.argv[1])
    if json.loads(line)["method"] == "POST" and json.loads(line)["body_bytes"] == 0
))
PY
)
assert_eq 'no POST reaches the endpoint with an empty body' '0' "$empty_arrivals"

# --- a run whose body generator fails --------------------------------------
# Reproduces the August shape exactly: the request body is not built, and the
# question is whether the probe notices or posts nothing and reports the
# endpoint's complaint as a finding. A non-numeric rung makes int() raise, so
# the generator dies the same way an unknown environment failure would.
OUT2="$WORK/out2"
: > "$REQ_LOG"
PROBE_CONTEXT_LADDER='notanumber' bash "$PROBE" "$OUT2" >/dev/null 2>&1

assert_ok 'a failed body generator leaves no HTTP status to misread' \
  test ! -e "$OUT2/03-context-notanumber-status.txt"

assert_ok 'a failed body generator is reported in the log' \
  grep -q 'could not build the request body' "$OUT2/00-probe-log.txt"

# The generator's own error is the thing that would have named the August root
# cause. Losing it to a terminal is what cost the trip.
assert_ok 'the generator failure keeps its error output' \
  test -s "$OUT2/03-context-notanumber-generator-stderr.txt"

# The whole point: nothing goes on the wire when the body is not there.
ladder_posts=$(python3 - "$REQ_LOG" <<'PY'
import json
import sys

print(sum(
    1 for line in open(sys.argv[1])
    if json.loads(line)["method"] == "POST" and json.loads(line)["body_bytes"] == 0
))
PY
)
assert_eq 'a body that could not be built is never posted' '0' "$ladder_posts"

# --- the August failure shape, reproduced ----------------------------------
# A large body answered with a complaint about an empty one. Diagnosing that
# in September and still having no measurement costs another month, so the
# retry is what turns the next visit from a diagnosis into an answer.
OUT3="$WORK/out3"
: > "$REQ_LOG"
kill "$STUB_PID" 2>/dev/null
rm -f "$PORT_FILE"
PROBE_STUB_MAX_BODY=1000 python3 tests/probe-stub/server.py "$PORT_FILE" "$REQ_LOG" &
STUB_PID=$!
for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
PORT="$(cat "$PORT_FILE")"
export PROBE_BASE_URL="http://127.0.0.1:$PORT/v1"

PROBE_CONTEXT_LADDER='4000' bash "$PROBE" "$OUT3" >/dev/null 2>&1

assert_ok 'an empty-body rejection is retried over HTTP/1.1' \
  test -s "$OUT3/03-context-4000-retry-http11-meta.txt"

assert_ok 'the retry records what it put on the wire too' \
  grep -q '^size_upload=' "$OUT3/03-context-4000-retry-http11-meta.txt"

assert_ok 'the log says why the retry ran' \
  grep -q 'retrying over HTTP/1.1' "$OUT3/00-probe-log.txt"

# A rejection that is genuinely about size must not drag the retry in behind
# it: the retry is for the one signature where the endpoint reports a body it
# never received.
OUT4="$WORK/out4"
kill "$STUB_PID" 2>/dev/null
rm -f "$PORT_FILE"
python3 tests/probe-stub/server.py "$PORT_FILE" "$REQ_LOG" &
STUB_PID=$!
for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
PORT="$(cat "$PORT_FILE")"
export PROBE_BASE_URL="http://127.0.0.1:$PORT/v1"
PROBE_CONTEXT_LADDER='4000' bash "$PROBE" "$OUT4" >/dev/null 2>&1

assert_ok 'an accepted body triggers no retry' \
  test ! -e "$OUT4/03-context-4000-retry-http11-meta.txt"

# --- the bracket survives a retry ------------------------------------------
# A rung genuinely refused for size, then a smaller rung that only looked
# refused and succeeds on the HTTP/1.1 retry. The window is bracketed BETWEEN
# the two, and reporting the smaller one as "the largest size tried" throws
# away the only bound the step exists to produce.
OUT5="$WORK/out5"
kill "$STUB_PID" 2>/dev/null
rm -f "$PORT_FILE"
PROBE_STUB_HARD_MAX=20000 PROBE_STUB_MAX_BODY=1000 PROBE_STUB_EMPTY_BODY_ONCE=1 \
  python3 tests/probe-stub/server.py "$PORT_FILE" "$REQ_LOG" &
STUB_PID=$!
for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
PORT="$(cat "$PORT_FILE")"
export PROBE_BASE_URL="http://127.0.0.1:$PORT/v1"

# ~8000 tokens is 32000 characters of filler, over the hard limit; ~2000 is
# 8000 characters, under it but over the empty-body threshold.
PROBE_CONTEXT_LADDER='8000 2000' bash "$PROBE" "$OUT5" >/dev/null 2>&1

assert_ok 'a rung refused for size is not retried' \
  test ! -e "$OUT5/03-context-8000-retry-http11-meta.txt"

assert_ok 'a retry that succeeds still reports the upper bound' \
  grep -q 'Window is between ~2000 and ~8000 tokens' "$OUT5/00-probe-log.txt"

# --- a run that never asked anything ---------------------------------------
# Every rung failing to build is not a finding that every size was refused.
# Nothing was refused, because nothing was sent.
OUT6="$WORK/out6"
PROBE_CONTEXT_LADDER='notanumber' bash "$PROBE" "$OUT6" >/dev/null 2>&1

assert_ok 'a ladder that sent nothing does not claim every size was refused' \
  test -z "$(grep -c 'Every size was refused' "$OUT6/00-probe-log.txt" | grep -v '^0$')"

assert_ok 'a ladder that sent nothing says so' \
  grep -q 'No size was tried' "$OUT6/00-probe-log.txt"

# --- a stale status file from an earlier run -------------------------------
# The output directory is reused across runs at the office. A step that sends
# nothing must not leave the previous run's HTTP status sitting next to it,
# because that status is what gets read at a desk a week later.
STALE="$OUT6/03-context-notanumber-status.txt"
printf '200' > "$STALE"
PROBE_CONTEXT_LADDER='notanumber' bash "$PROBE" "$OUT6" >/dev/null 2>&1
assert_ok 'a step that sends nothing clears a stale status from an earlier run' \
  test ! -e "$STALE"

# --- the exit status tells probe failure from endpoint failure -------------
# Exit 1 means "the endpoint never answered"; a probe that could not build the
# request never asked. A directory where the body file belongs fails the write
# the way a full disk would.
OUT7="$WORK/out7"
mkdir -p "$OUT7/01b-chat-req.json"
bash "$PROBE" "$OUT7" >/dev/null 2>&1
assert_eq 'a probe that never asked does not exit as if the endpoint failed' \
  '3' "$?"

# --- step 4 actually runs -------------------------------------------------
# It was once a `cat` of instructions needing software the WSL2 VM does not
# have, and two office visits produced no answer. These assertions exist so it
# cannot quietly become documentation again.
OUT8="$WORK/out8"
kill "$STUB_PID" 2>/dev/null
rm -f "$PORT_FILE"
PROBE_STUB_SCRIPT=tests/probe-stub/multi-turn-script.json \
  python3 tests/probe-stub/server.py "$PORT_FILE" "$REQ_LOG" &
STUB_PID=$!
for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
PORT="$(cat "$PORT_FILE")"
export PROBE_BASE_URL="http://127.0.0.1:$PORT/v1"

PROBE_CONTEXT_LADDER='2000' PROBE_MAX_TURNS=6 bash "$PROBE" "$OUT8" >/dev/null 2>&1

assert_ok 'step 4 issues real requests rather than printing instructions' \
  test -s "$OUT8/04-turn-01-meta.txt"

# Turn three is where flattened history breaks. A step that stops before it
# cannot see the thing the visit exists to see.
assert_ok 'the conversation reaches turn four' \
  test -s "$OUT8/04-turn-04-meta.txt"

# The measurement itself: three scripted replies carry calls, the fourth does
# not. Scoring the fourth as a call would report a derail as a success.
assert_ok 'it counts exactly the replies that carried a tool call' \
  grep -q '4 turns, 3 carried a parseable tool call' "$OUT8/00-probe-log.txt"

assert_ok 'it names the first reply with no call' \
  grep -q 'First reply with no call: turn 4' "$OUT8/00-probe-log.txt"

# History has to accumulate, or every turn is turn one and the thing being
# measured never happens. Two messages seeded, then two per turn.
history=$(python3 - "$OUT8/04-conversation.json" <<'PY'
import json
import sys

print(len(json.load(open(sys.argv[1]))["messages"]))
PY
)
assert_eq 'the conversation carries its history forward' '9' "$history"

# --- step 4 attributes every ending to the right layer ---------------------
# THE invariant: the summary may claim "Every reply carried a call" only when
# every attempted turn returned 2xx AND parsed a call. Every other ending
# names the probe or the transport -- reported as model behaviour instead, a
# failed office run reads as a clean pass a month later.
#
# Combinatorial, not by-example: example tests let this cluster through once.
start_stub() {
  kill "$STUB_PID" 2>/dev/null
  rm -f "$PORT_FILE"
  env "$@" PROBE_STUB_SCRIPT=tests/probe-stub/multi-turn-script.json \
    python3 tests/probe-stub/server.py "$PORT_FILE" "$REQ_LOG" &
  STUB_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$PORT_FILE" ] && break
    sleep 0.1
  done
  PORT="$(cat "$PORT_FILE" 2>/dev/null)"
  export PROBE_BASE_URL="http://127.0.0.1:$PORT/v1"
}

run_step4() {
  PROBE_CONTEXT_LADDER='2000' PROBE_MAX_TURNS=6 bash "$PROBE" "$1" >/dev/null 2>&1
}

case_n=0
for spec in \
  'PROBE_STUB_FAIL_TURN=2|failed on the wire or was refused' \
  'PROBE_STUB_BAD_BODY_TURN=2|could not be read' \
  'PROBE_STUB_TRUNCATE_TURN=2|hit max_tokens'
do
  case_n=$((case_n + 1))
  knob="${spec%%|*}"
  marker="${spec#*|}"
  out="$WORK/attr$case_n"

  start_stub "$knob"
  run_step4 "$out"

  assert_ok "$knob names the real cause" \
    grep -q "$marker" "$out/00-probe-log.txt"

  assert_not_ok "$knob is not reported as a clean pass" \
    grep -q 'Every reply carried a call' "$out/00-probe-log.txt"
done

# The fourth mode: the probe cannot build the turn's body, so nothing is sent.
# A directory where the request file belongs fails the write the way a full
# disk or a bad path would.
out="$WORK/attr-notsent"
start_stub 'PROBE_STUB_UNUSED=1'
mkdir -p "$out/04-turn-02-req.json"
run_step4 "$out"

assert_ok 'a turn that could not be built says nothing was sent' \
  grep -q 'was never sent' "$out/00-probe-log.txt"

assert_not_ok 'a turn that was never sent is not reported as a clean pass' \
  grep -q 'Every reply carried a call' "$out/00-probe-log.txt"

assert_not_ok 'a turn that was never sent is not blamed on the model' \
  grep -q 'First reply with no call' "$out/00-probe-log.txt"

# The true positive. Without this the assertions above are satisfied by a probe
# that simply never prints the line.
out="$WORK/attr-ceiling"
start_stub 'PROBE_STUB_UNUSED=1'
PROBE_CONTEXT_LADDER='2000' PROBE_MAX_TURNS=2 bash "$PROBE" "$out" >/dev/null 2>&1

assert_ok 'a run that really did call every turn says so' \
  grep -q 'Every reply carried a call' "$out/00-probe-log.txt"

assert_ok 'and names the ceiling as what stopped it, not the model' \
  grep -q 'stopped at the 2-turn' "$out/00-probe-log.txt"

# A write must not be answered with the file's contents. `cat > f` matching the
# read branch told the model its read-back had already succeeded, ending the
# conversation two turns before the turn the step exists to reach.
observation=$(python3 - <<'PY'
import re

def observation_for(command):
    last = re.split(r"&&|\|\||;", command)[-1].strip()
    if ">" in last:
        return ""
    head = (last.split() or [""])[0]
    if head in ("cat", "head", "tail"):
        return "hello"
    if head == "ls":
        return "LISTING"
    return ""

print("|".join([
    observation_for("cat > /workspace/hello.txt <<'EOF'\nhello\nEOF"),
    observation_for("cat /workspace/hello.txt"),
    observation_for("false"),
    observation_for("ls -la /workspace"),
]))
PY
)
assert_eq 'a write is not answered as though the file had been read back' \
  '|hello||LISTING' "$observation"

# --- the probe runs where only curl and python3 exist ----------------------
# jq is on this machine, on CI, and on the Linux build host, and absent from
# the office Windows machines and the WSL2 VM the probe runs in. So a jq
# dependency added here passes every check we have and fails at the office --
# a month later, on the one run that mattered.
PROBE_CODE="$WORK/probe-code.sh"
grep -vE '^[[:space:]]*#' "$PROBE" > "$PROBE_CODE"

# Word-boundary match at a command position rather than a bare substring: the
# header explains at length that jq is NOT used, and that sentence must not
# fail its own test.
assert_not_ok 'probe.sh never invokes jq' \
  grep -qE '(^|[|&;(`]|[[:space:]])jq([[:space:]]|$)' "$PROBE_CODE"

# The declared prerequisites, which is the other half: a dependency the probe
# checks for is one the operator is told about before the request goes out,
# and one that grows silently is how the first half gets defeated.
declared=$(sed -n 's/^for tool in \(.*\); do$/\1/p' "$PROBE")
assert_eq 'probe.sh requires only curl and python3' 'curl python3' "$declared"

finish
