#!/usr/bin/env bash
# Runs INSIDE the image. The one stable interface in front of the OpenHands CLI.
#
# The launcher calls this and nothing else, so an upstream flag rename is a
# one-line change here rather than a change to a PowerShell script that cannot
# be tested without a container engine. The V0 layout most published examples
# describe has already been removed upstream; assume this will move again.
#
# It exists for three reasons that are not about tidiness. Each one is a way an
# unattended run reports success while having achieved nothing, at a site that
# can only be visited monthly:
#
#   1. The CLI exits 0 when the LLM fails. Measured: a run that took a hard
#      HTTP 400 on every single turn still exited zero. Anything that trusts
#      `$?` will ship a broken configuration and report green, so the verdict
#      is taken from the `--json` event stream instead -- a ConversationErrorEvent
#      is a failed run no matter what the process status says.
#   2. There is no usable bound on an unattended run. `openhands_cli` never
#      passes `max_iteration_per_run`, so the SDK default of 500 always
#      applies, and the gateway's spend cap is inert because LiteLLM tracks
#      spend in Postgres and this stack provisions none. The cap below is the
#      only thing between an overnight run and an unbounded bill. Measured
#      against the fake upstream: one malformed tool call the model kept
#      repeating cost 500 real completions before the SDK's own limit fired,
#      and the process still exited 0.
#   3. A settings file that does not validate degrades into exactly the failure
#      it was written to prevent. `AgentStore.load_from_disk` swallows the
#      validation error, prints one line, returns None, and the CLI builds a
#      default agent whose native_tool_calling is True -- which sends `tools`
#      to an endpoint that refuses them. Nothing about that is loud, so the
#      file is validated here, immediately before the harness reads it.
#
# Usage: run-openhands.sh <model-id> <task...>
#
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
# The interpreter that has the SDK installed. The generator constructs a real
# openhands.sdk.Agent, so the system python3 fails with an ImportError that
# reads like a broken image rather than like a wrong path.
PYTHON="${CRANOPENER_OPENHANDS_PYTHON:-/usr/local/bin/openhands-python}"

# The launcher derives the harness from the model namespace, but the litellm
# prefix is a separate axis and getting it wrong is the quietest failure in
# this whole path: litellm gives up before opening a socket, so the run makes
# zero requests, reports no error, and exits 0. Checked here because the
# operator can also invoke this directly.
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

# Checked here rather than left to the run: a missing binary surfaces as a
# stream with no events in it, which is the same shape as the model prefix
# failure below and would send the reader to the wrong place.
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
# The startup banner goes to the same stdout as the JSONL event stream. The
# reader below ignores anything that is not a JSON object, so this is tidiness
# rather than correctness -- but the stream is also what a human reads after an
# unattended run, and a box-drawn advert at the top of it is noise.
export OPENHANDS_SUPPRESS_BANNER=1

# litellm fetches its model cost map from raw.githubusercontent.com at import.
# It falls back to a bundled copy, but the attempt is a network call to
# somewhere that is not the configured base URL, and behind the target site's
# proxy it is a delay on every single run for a table used only to price
# tokens nobody is billing here.
export LITELLM_LOCAL_MODEL_COST_MAP=True

# The SDK clones github.com/OpenHands/extensions for its public skills on
# startup. There is no environment variable to switch that off -- checked
# against the installed source -- and it degrades to a logged error when the
# host is unreachable, which is what happens here. What it must never do is
# stop and ask for credentials: an unattended run has nobody to answer, and
# git will wait forever.
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
  # --api-key-env, not --api-key: /proc/<pid>/cmdline is world-readable and
  # /proc/<pid>/environ is not, so passing the value here would publish it to
  # every other uid in the container for the lifetime of the call.
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

# Validated whether it was generated or supplied. Generation proves what was
# written; this proves what is about to be read, and those are the same file
# only until somebody mounts a different one.
if [ ! -f "$SETTINGS" ]; then
  echo "run-openhands.sh: $SETTINGS does not exist. The CLI would not fail on" >&2
  echo "  that -- it would build a default agent with native_tool_calling=True" >&2
  echo "  and send a \`tools\` array to an endpoint that refuses it." >&2
  exit 3
fi
"$PYTHON" "$GENERATOR" --check "$SETTINGS" || exit 3

# --- 2. run the harness, reading the event stream --------------------------
STREAM_DIR="$(mktemp -d)"
FIFO="$STREAM_DIR/events"
HARNESS_STDERR="$STREAM_DIR/stderr"
mkfifo "$FIFO"

HARNESS_PID=""

# Invoked by the `trap cleanup EXIT` four lines down, which shellcheck's
# reachability analysis does not follow. Both codes name the same false
# positive and both are needed: 0.11 reports SC2329 against the definition,
# 0.10 reports SC2317 against each statement in the body. Dropping either one
# leaves the suite red on one of the two machines that run it.
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
  # A harness blocked writing into a FIFO nobody is reading any more will not
  # notice a TERM until it returns from write(2), so the KILL is not optional.
  local waited=0
  while kill -0 "$HARNESS_PID" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -KILL "$HARNESS_PID" 2>/dev/null
  # Signals the process, not the process group. A command the agent had already
  # spawned can outlive this, which is survivable only because the harness runs
  # one task per container and the container exits with this script. If this
  # ever runs in something long-lived, that assumption has to be revisited
  # rather than inherited.
}

# --json makes every event a line of JSON on stdout -- interleaved with the
# CLI's own terminal chatter, which is why only lines that begin with `{` are
# parsed below. Its stderr is a separate stream on purpose: merging it would
# put log lines inside the JSONL and make the only machine-readable evidence of
# what happened unparseable.
#
# `timeout` is the backstop the event cap cannot be: the cap only fires on
# something the harness prints, so a loop that prints nothing would run until
# the container did.
timeout "$TIMEOUT_SECONDS" openhands --headless --json -t "$TASK" \
  >"$FIFO" 2>"$HARNESS_STDERR" &
HARNESS_PID=$!

events=0
actions=0
errors=0
capped=0

while IFS= read -r line; do
  # Passed through unmodified. The stream is the record of the run, and an
  # adapter that summarizes it away leaves nothing to diagnose from.
  printf '%s\n' "$line"

  case "$line" in '{'*) ;; *) continue ;; esac
  kind=$(printf '%s' "$line" | jq -r '.kind // empty' 2>/dev/null)

  # ITERATION MARKER: every event, not one chosen kind. Measured, not guessed.
  # A run whose tool calls all parsed emitted one ActionEvent per completion,
  # which makes ActionEvent look like the marker. It is not. A run where the
  # model repeated one malformed tool call emitted a *user* MessageEvent per
  # completion carrying the validation error, and kept going: 500 completions
  # billed, one single ActionEvent in the whole stream. Any cap counting
  # ActionEvent would have watched that happen and said nothing.
  #
  # No event kind is one-to-one with an agent step. But a step cannot advance
  # without emitting at least one event -- that is how the SDK reports what it
  # did -- so counting every event bounds steps from above, which is the
  # direction a safety bound has to err in. It over-counts a healthy run,
  # where an action and its observation are two events for one step, so the
  # cap is a bound and not a budget: set it well above what the task needs.
  events=$((events + 1))

  case "$kind" in
    ConversationErrorEvent)
      errors=$((errors + 1))
      # code and detail both printed: a wrapper that fails without saying why
      # is worse than none, because the next person assumes the endpoint is
      # down and goes to look at the gateway.
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
# THE ORDER OF THIS BLOCK IS THE CONTRACT, not an artefact of the sequence the
# checks happened to be written in. Several of these conditions hold at once in
# ordinary failures -- a run that errors on every turn also burns through the
# cap; a harness that blackholes emits no events AND is killed by the wall
# clock -- and whichever is tested first is the only thing the operator is
# told. So they are tested most specific first, and a condition that did not
# win is printed underneath the one that did rather than dropped.
#
# What getting this wrong costs is not a wrong exit status, which nothing
# reads. It is a wrong instruction, at a site reachable about once a month. The
# order this block used to have told a run that errored on every turn and then
# hit the cap to "raise the cap deliberately, or shorten the task" -- which
# invites spending more money on a configuration that cannot work -- and told a
# harness that blackholed and was killed by `timeout` to check its model
# prefix, which was not wrong with it. tests/test-run-openhands-verdict.sh
# drives every one of these and pins the order.
stderr_tail() {
  if [ -s "$HARNESS_STDERR" ]; then
    echo "--- harness stderr (last 20 lines) ---" >&2
    tail -20 "$HARNESS_STDERR" >&2
  fi
}

# Printed under whichever verdict won. The cap is the one that has to survive
# losing: an errored run that also hit the cap is an errored run, but without
# this the event count in front of the operator is unexplained and the run
# looks like it simply stopped.
also_capped() {
  [ "$capped" = "1" ] || return 0
  echo "  This run also stopped at the iteration cap," >&2
  echo "  CRANOPENER_MAX_ITERATIONS=$MAX_ITERATIONS, after $events stream events." >&2
  echo "  That is context and not the cause: raising the cap buys more of the" >&2
  echo "  same failure." >&2
}

# 1. Conversation errors, ahead of everything else. Whatever else was also true
#    of the run is either a consequence of the errors or a coincidence, and
#    naming it instead aims the next move at the wrong thing.
if [ "$errors" -gt 0 ]; then
  # The harness's own status is printed rather than used. It is routinely 0
  # here, which is the whole reason this script exists.
  echo "run-openhands.sh: $errors conversation error(s); the harness itself exited $harness_rc." >&2
  also_capped
  stderr_tail
  exit 4
fi

# 2. The iteration cap. This run killed the harness on purpose to enforce it,
#    so harness_rc from here down is the signal we sent rather than anything
#    the run did -- which is why both status tests sit underneath this one.
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

# 3. The wall clock, ahead of the zero-events check below rather than after it.
#    A harness that blackholes -- a dropped proxy connection, a DNS timeout on
#    the LLM path -- emits nothing and is then killed by `timeout`, and the
#    zero-events message would send the reader to the model prefix and the base
#    URL, neither of which is wrong with it. 124 is `timeout`'s own status for
#    "the bound fired", so this is the one condition that reports itself.
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

# 4. A harness that failed and said so, also ahead of the zero-events check and
#    for the same reason: a CLI that died during startup -- an unreadable
#    settings file, an import error out of a half-built image -- emits no
#    events either, and its own status with its stderr is a better lead than a
#    guess about the model prefix. The zero-events diagnosis below is
#    specifically about a harness that exited CLEANLY having sent nothing.
if [ "$harness_rc" -ne 0 ]; then
  echo "run-openhands.sh: harness exited $harness_rc after $events stream events" >&2
  stderr_tail
  exit "$harness_rc"
fi

# 5. Zero events from a harness that exited 0 -- what is left once every louder
#    failure above has been ruled out, and trap 1 in the shape it actually
#    takes: a model prefix litellm does not recognise makes the client give up
#    before opening a socket, and the CLI exits 0 having sent nothing. It looks
#    exactly like a clean run that had nothing to say, which is the most
#    expensive way to be wrong here.
if [ "$events" -eq 0 ]; then
  echo "run-openhands.sh: the harness exited 0 having emitted no events at all --" >&2
  echo "  it did not get as far as a conversation. Check the model prefix and" >&2
  echo "  that $BASE_URL is the endpoint you meant." >&2
  stderr_tail
  exit 4
fi

echo "run-openhands.sh: completed: $events stream events, $actions agent action(s), no conversation errors" >&2
exit 0
