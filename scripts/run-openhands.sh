#!/usr/bin/env bash
# Runs INSIDE the image. The one stable interface in front of the OpenHands CLI.
#
# Runs one agent task headlessly and reports a verdict that means what it says.
# The OpenHands CLI exits 0 when the LLM fails, has no usable bound on an
# unattended run, and degrades quietly when its settings file does not
# validate; this script reads the --json event stream and takes its verdict
# from that instead. See docs/hazards.md for the measurements behind each.
#
# The launcher calls this and nothing else, so an upstream flag rename is a
# one-line change here rather than in a PowerShell script that cannot be
# tested without a container engine. Assume the CLI will move again: the V0
# layout most published examples describe has already been removed upstream.
#
# Usage: run-openhands.sh <model-id> <task...>
#
#   <model-id>   the model in litellm's dialect, INCLUDING a transport prefix
#                -- e.g. openai/provider-a/some-model. Refused without one.
#   <task...>    the whole remaining argument list, used verbatim as the task.
#                There is no interactive mode and no `run` verb.
#
# Environment:
#   CRANOPENER_LLM_BASE_URL   endpoint, default the gateway on the pod's shared
#                             network namespace. Never left unset: the SDK's
#                             own default is a vendor cloud endpoint, so an
#                             unset base URL means the harness phones home.
#   CRANOPENER_LLM_API_KEY    the key. Read from the environment and passed to
#                             the generator by NAME, never by value.
#   CRANOPENER_MAX_ITERATIONS cap on agent steps, default 50. Counted in
#                             stream events -- see ITERATION MARKER below.
#   CRANOPENER_TIMEOUT_SECONDS
#                             wall-clock bound, default 3600. Backstop for the
#                             one thing the event cap cannot see: a loop that
#                             emits no events at all.
#   CRANOPENER_OPENHANDS_KEEP_SETTINGS=1
#                             use the settings file already on disk instead of
#                             generating one. Still validated -- the check
#                             never relaxes, only the generation is skipped.
#   CRANOPENER_OPENHANDS_GENERATOR
#                             path to the settings generator inside the image.
#   CRANOPENER_OPENHANDS_PYTHON
#                             the interpreter that has the SDK installed.
#   OPENHANDS_PERSISTENCE_DIR where agent_settings.json lives, default
#                             $HOME/.openhands.
#   OPENHANDS_WORK_DIR        the workspace, default /workspace.
#
# Exit status:
#   0  the run completed with no conversation error
#   2  usage or configuration error
#   3  the settings file is missing, unloadable, or in native tool-calling mode
#   4  the run failed at the conversation: it reported an error (regardless of
#      the harness's status), or it exited cleanly having emitted nothing
#   5  a bound was reached -- the iteration cap or the wall clock -- and the
#      run was stopped
#   *  whatever the harness exited with, when it is non-zero
#
# Several of those conditions hold at once in ordinary failures, so which one
# is reported is decided by the order of the verdict block in section 3, and
# that order is part of this script's contract. See the comment there.
#
# Nothing here needs the container-engine socket, a spawned sandbox container,
# or any network destination other than the configured base URL. The CLI runs
# the agent in-process; this container is the sandbox.
set -uo pipefail

usage() {
  echo "usage: run-openhands.sh <model-id> <task...>" >&2
}

if [ "$#" -lt 2 ]; then
  usage
  exit 2
fi

MODEL="$1"; shift
TASK="$*"

BASE_URL="${CRANOPENER_LLM_BASE_URL:-http://localhost:4000/v1}"
MAX_ITERATIONS="${CRANOPENER_MAX_ITERATIONS:-50}"
TIMEOUT_SECONDS="${CRANOPENER_TIMEOUT_SECONDS:-3600}"
PERSISTENCE_DIR="${OPENHANDS_PERSISTENCE_DIR:-$HOME/.openhands}"
WORK_DIR="${OPENHANDS_WORK_DIR:-/workspace}"
SETTINGS="$PERSISTENCE_DIR/agent_settings.json"
GENERATOR="${CRANOPENER_OPENHANDS_GENERATOR:-/usr/local/lib/cranopener/make-openhands-settings.py}"
# The interpreter with the SDK installed. The generator builds a real
# openhands.sdk.Agent, so system python3 fails with a misleading ImportError.
PYTHON="${CRANOPENER_OPENHANDS_PYTHON:-/usr/local/bin/openhands-python}"

# The quietest failure in this path: without a prefix litellm gives up before
# opening a socket, so the run sends nothing and exits 0. Checked here too
# because the operator can invoke this directly.
case "$MODEL" in
  */*) : ;;
  *)
    echo "run-openhands.sh: model '$MODEL' has no litellm provider prefix." >&2
    echo "  litellm resolves the transport from the prefix; without one it" >&2
    echo "  gives up before opening a socket and the run exits 0 having sent" >&2
    echo "  nothing. Use e.g. openai/$MODEL and let --base-url do the routing." >&2
    exit 2
    ;;
esac

# A missing binary surfaces as a stream with no events, the same shape as the
# model-prefix failure above, so name it here instead.
if ! command -v openhands >/dev/null 2>&1; then
  echo "run-openhands.sh: no openhands on PATH" >&2
  exit 2
fi

case "$MAX_ITERATIONS" in
  '' | *[!0-9]*)
    echo "run-openhands.sh: CRANOPENER_MAX_ITERATIONS='$MAX_ITERATIONS' is not a number" >&2
    exit 2
    ;;
esac
if [ "$MAX_ITERATIONS" -lt 1 ]; then
  echo "run-openhands.sh: CRANOPENER_MAX_ITERATIONS must be at least 1" >&2
  exit 2
fi

case "$TIMEOUT_SECONDS" in
  '' | *[!0-9]*)
    echo "run-openhands.sh: CRANOPENER_TIMEOUT_SECONDS='$TIMEOUT_SECONDS' is not a number" >&2
    exit 2
    ;;
esac

export OPENHANDS_PERSISTENCE_DIR="$PERSISTENCE_DIR"
export OPENHANDS_WORK_DIR="$WORK_DIR"
# The banner shares stdout with the JSONL stream. Tidiness, not correctness --
# the reader ignores non-JSON -- but the stream is what a human reads after.
export OPENHANDS_SUPPRESS_BANNER=1

# litellm otherwise fetches its cost map from raw.githubusercontent.com at
# import: a delay on every run, behind a proxy, for a table nobody bills from.
export LITELLM_LOCAL_MODEL_COST_MAP=True

# The SDK clones its public skills repo on startup and cannot be told not to.
# Unreachable degrades to a logged error, which is fine; prompting for
# credentials would hang an unattended run forever, which is not.
export GIT_TERMINAL_PROMPT=0

# --- 1. the settings file --------------------------------------------------
if [ "${CRANOPENER_OPENHANDS_KEEP_SETTINGS:-0}" = "1" ]; then
  echo "run-openhands.sh: keeping the existing $SETTINGS" >&2
else
  if [ ! -x "$PYTHON" ]; then
    echo "run-openhands.sh: no SDK interpreter at $PYTHON" >&2
    exit 2
  fi
  if [ ! -f "$GENERATOR" ]; then
    echo "run-openhands.sh: no settings generator at $GENERATOR" >&2
    exit 2
  fi
  # --api-key-env, not --api-key: /proc/<pid>/cmdline is world-readable,
  # /proc/<pid>/environ is not.
  CRANOPENER_LLM_API_KEY="${CRANOPENER_LLM_API_KEY:-unused}" \
  "$PYTHON" "$GENERATOR" \
      --model "$MODEL" \
      --base-url "$BASE_URL" \
      --api-key-env CRANOPENER_LLM_API_KEY \
      --out "$SETTINGS" || {
    echo "run-openhands.sh: could not generate $SETTINGS" >&2
    exit 3
  }
fi

# Validated whether generated or supplied: generation proves what was written,
# this proves what is about to be read.
if [ ! -f "$SETTINGS" ]; then
  echo "run-openhands.sh: $SETTINGS does not exist. The CLI would not fail on" >&2
  echo "  that -- it would build a default agent with native_tool_calling=True" >&2
  echo "  and send a \`tools\` array to an endpoint that discards it silently," >&2
  echo "  which fails as a session that never calls a tool, not as an error." >&2
  exit 3
fi
"$PYTHON" "$GENERATOR" --check "$SETTINGS" || exit 3

# --- 2. run the harness, reading the event stream --------------------------
STREAM_DIR="$(mktemp -d)"
FIFO="$STREAM_DIR/events"
HARNESS_STDERR="$STREAM_DIR/stderr"
mkfifo "$FIFO"

HARNESS_PID=""

# Invoked by the `trap cleanup EXIT` below, which shellcheck does not follow.
# Both codes are needed -- different versions report different ones. See
# docs/hazards.md.
# shellcheck disable=SC2317,SC2329
cleanup() {
  if [ -n "$HARNESS_PID" ] && kill -0 "$HARNESS_PID" 2>/dev/null; then
    kill -TERM "$HARNESS_PID" 2>/dev/null
  fi
  rm -rf "$STREAM_DIR"
}
trap cleanup EXIT

stop_harness() {
  kill -0 "$HARNESS_PID" 2>/dev/null || return 0
  kill -TERM "$HARNESS_PID" 2>/dev/null
  # A harness blocked writing into a FIFO nobody reads will not notice a TERM
  # until write(2) returns, so the KILL is not optional.
  local waited=0
  while kill -0 "$HARNESS_PID" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -KILL "$HARNESS_PID" 2>/dev/null
  # The process, not the process group: a command the agent spawned can outlive
  # this. Survivable only because the container exits with this script.
}

# --json puts every event on stdout, interleaved with the CLI's own chatter --
# hence the `{` test below. stderr stays a separate stream: merging it would
# make the only machine-readable evidence of the run unparseable.
#
# `timeout` is the backstop the event cap cannot be: the cap fires only on
# something the harness prints, so a silent loop would run until the container did.
timeout "$TIMEOUT_SECONDS" openhands --headless --json -t "$TASK" \
  >"$FIFO" 2>"$HARNESS_STDERR" &
HARNESS_PID=$!

events=0
actions=0
errors=0
capped=0

while IFS= read -r line; do
  # Unmodified: the stream is the record, and summarizing it away leaves
  # nothing to diagnose from.
  printf '%s\n' "$line"

  case "$line" in '{'*) ;; *) continue ;; esac
  kind=$(printf '%s' "$line" | jq -r '.kind // empty' 2>/dev/null)

  # ITERATION MARKER: every event, not one chosen kind. Counting ActionEvent
  # would have missed 500 billed completions -- measured, see docs/hazards.md.
  # This bounds steps from above, so the cap is a bound and not a budget: set
  # it well above what the task needs.
  events=$((events + 1))

  case "$kind" in
    ConversationErrorEvent)
      errors=$((errors + 1))
      # Both code and detail: a wrapper that fails without saying why sends
      # the next person to the gateway.
      printf '%s' "$line" \
        | jq -r '"run-openhands.sh: conversation error: code=\(.code // "?") detail=\(.detail // "?")"' >&2
      ;;
    ActionEvent)
      actions=$((actions + 1))
      ;;
  esac

  if [ "$events" -ge "$MAX_ITERATIONS" ]; then
    capped=1
    stop_harness
    break
  fi
done < "$FIFO"

wait "$HARNESS_PID"
harness_rc=$?
HARNESS_PID=""

# --- 3. a verdict that means what it says ----------------------------------
#
# THE ORDER OF THIS BLOCK IS THE CONTRACT. Several conditions hold at once in
# ordinary failures, and whichever is tested first is the only thing the
# operator is told -- so: most specific first, and a condition that did not win
# is printed underneath the one that did rather than dropped. What a wrong
# order costs is a wrong instruction at a site reachable once a month; see
# docs/hazards.md. tests/test-run-openhands-verdict.sh pins the order.
stderr_tail() {
  if [ -s "$HARNESS_STDERR" ]; then
    echo "--- harness stderr (last 20 lines) ---" >&2
    tail -20 "$HARNESS_STDERR" >&2
  fi
}

# Printed under whichever verdict won. An errored run that also hit the cap is
# an errored run -- but without this its event count looks unexplained.
also_capped() {
  [ "$capped" = "1" ] || return 0
  echo "  This run also stopped at the iteration cap," >&2
  echo "  CRANOPENER_MAX_ITERATIONS=$MAX_ITERATIONS, after $events stream events." >&2
  echo "  That is context and not the cause: raising the cap buys more of the" >&2
  echo "  same failure." >&2
}

# 1. Conversation errors, ahead of everything else: anything else that was
#    also true is a consequence or a coincidence.
if [ "$errors" -gt 0 ]; then
  # Printed, not used. It is routinely 0 here -- the reason this script exists.
  echo "run-openhands.sh: $errors conversation error(s); the harness itself exited $harness_rc." >&2
  also_capped
  stderr_tail
  exit 4
fi

# 2. The iteration cap. We killed the harness to enforce it, so harness_rc
#    below is our own signal -- hence both status tests sit underneath this.
if [ "$capped" = "1" ]; then
  echo "run-openhands.sh: stopped at the iteration cap, with no conversation errors." >&2
  echo "  CRANOPENER_MAX_ITERATIONS=$MAX_ITERATIONS, reached after $events stream" >&2
  echo "  events ($actions agent action(s)). Nothing else would have stopped this:" >&2
  echo "  the CLI never passes max_iteration_per_run, so the SDK's own limit is" >&2
  echo "  500 completions, and the gateway's spend cap needs a Postgres this" >&2
  echo "  stack does not provision. Raise the cap deliberately, or shorten the" >&2
  echo "  task." >&2
  exit 5
fi

# 3. The wall clock, ahead of the zero-events check: a blackholed harness emits
#    nothing and is then killed, and the zero-events message would blame the
#    model prefix. 124 is `timeout`'s own status, so this condition self-reports.
if [ "$harness_rc" -eq 124 ]; then
  echo "run-openhands.sh: stopped at the wall-clock bound," >&2
  echo "  CRANOPENER_TIMEOUT_SECONDS=$TIMEOUT_SECONDS, after $events stream events." >&2
  if [ "$events" -eq 0 ]; then
    echo "  It emitted nothing at all before the bound fired, so it never reached" >&2
    echo "  a conversation: something on the path to $BASE_URL is taking the" >&2
    echo "  connection and not answering. That is a different fault from a" >&2
    echo "  harness that exits 0 having sent nothing -- see exit 4." >&2
  fi
  stderr_tail
  exit 5
fi

# 4. A harness that failed and said so, ahead of zero-events for the same
#    reason: a CLI that died during startup emits nothing either, and its own
#    status and stderr are a better lead. Zero-events below is specifically
#    about a harness that exited CLEANLY having sent nothing.
if [ "$harness_rc" -ne 0 ]; then
  echo "run-openhands.sh: harness exited $harness_rc after $events stream events" >&2
  stderr_tail
  exit "$harness_rc"
fi

# 5. Zero events from a harness that exited 0 -- what is left once every louder
#    failure is ruled out. Usually an unrecognised model prefix: the client
#    gives up before opening a socket, and this looks exactly like a clean run
#    that had nothing to say.
if [ "$events" -eq 0 ]; then
  echo "run-openhands.sh: the harness exited 0 having emitted no events at all --" >&2
  echo "  it did not get as far as a conversation. Check the model prefix and" >&2
  echo "  that $BASE_URL is the endpoint you meant." >&2
  stderr_tail
  exit 4
fi

echo "run-openhands.sh: completed: $events stream events, $actions agent action(s), no conversation errors" >&2
exit 0
