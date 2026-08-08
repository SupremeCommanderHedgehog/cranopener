#!/usr/bin/env bash
# The office trip, in order. One visit, and nothing may need a second one.
#
# The provider-A endpoint is reachable only from the office, at roughly one
# visit a month. So every step here is ordered to be worth running even if the
# next one fails, and every raw body is written to the output directory
# whatever happens -- a failed trip has to be diagnosable at a desk, because
# the next chance to look is a month away.
#
# Endpoint-agnostic by necessity: this repository is public, so the target
# comes entirely from the environment and nothing about it is recorded here.
#
#   PROBE_BASE_URL   the gateway's OpenAI-compatible base, ending in /v1
#   PROBE_MODEL      the model identifier as the gateway names it -- the same
#                    string you would pass to `cranopener -Model`
#   PROBE_API_KEY    bearer token for the gateway
#
# Optional:
#   PROBE_TIMEOUT          per-request seconds, default 120. The oversized
#                          context probe uploads megabytes over a corporate
#                          link; raise this rather than concluding "hung".
#   PROBE_CONTEXT_LADDER   token sizes to try, largest first, default
#                          "200000 32000 8000".
#
# Usage: bash spike/office/probe.sh [output-directory]
#        (default output directory: spike/office/out, which is gitignored)
#
# Exit status:
#   0  the run completed and the endpoint answered a plain request
#   1  the endpoint never answered a plain request -- see 01b-* in the output
#   2  configuration missing
#   3  the probe could not build a request body, so it never asked. A failure
#      of this script, not a finding about the endpoint -- the two are kept
#      apart here because 1 is read as a verdict on the provider.
#
# Requires curl and python3, both of which are present on the machine this
# runs from. It deliberately does NOT use jq: jq is absent on the authoring
# and office Windows machines and present only on the Linux build host, and a
# probe that cannot run at the office is worth nothing.
set -uo pipefail

# --- configuration ---------------------------------------------------------
# Checked before anything else touches the network or the filesystem. All
# three are reported at once: finding out about them one run at a time is a
# waste of a visit that only happens monthly.
missing=()
for var in PROBE_BASE_URL PROBE_MODEL PROBE_API_KEY; do
  if [ -z "${!var:-}" ]; then
    missing+=("$var")
  fi
done

if [ "${#missing[@]}" -ne 0 ]; then
  {
    echo "probe.sh: not configured. Missing: ${missing[*]}"
    echo
    echo "  This repository is public, so the probe carries no endpoint of its"
    echo "  own. Set all three and re-run:"
    echo
    echo "    export PROBE_BASE_URL=...   # the gateway, ending in /v1"
    echo "    export PROBE_MODEL=...      # the model id as the gateway names it"
    echo "    export PROBE_API_KEY=...    # bearer token for the gateway"
    echo
    echo "    bash spike/office/probe.sh [output-directory]"
  } >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${PROBE_BASE_URL%/}"
OUT="${1:-$HERE/out}"
TIMEOUT="${PROBE_TIMEOUT:-120}"
CONTEXT_LADDER="${PROBE_CONTEXT_LADDER:-200000 32000 8000}"

for tool in curl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "probe.sh: no $tool on PATH" >&2
    exit 2
  }
done

mkdir -p "$OUT" || exit 2

# Everything this script says goes to the output directory as well as to the
# terminal. In August a step failed before it reached curl, and the account of
# why went to a terminal at the office and is gone -- leaving a captured
# response that read like a provider finding and no record of the probe's own
# behaviour. The kit's promise is that a failed trip is diagnosable at a desk,
# and that promise does not survive the operator having to remember to pipe
# through tee.
#
# Re-exec through a pipe rather than `exec > >(tee ...)`: process substitution
# leaves tee racing the script's exit for the last lines written, and the last
# lines are the ones that matter when something dies. PIPESTATUS preserves the
# documented exit codes, which a bare pipe would replace with tee's.
if [ "${PROBE_TEE_ACTIVE:-}" != '1' ]; then
  export PROBE_TEE_ACTIVE=1
  bash "$0" "$@" 2>&1 | tee "$OUT/00-probe-log.txt"
  exit "${PIPESTATUS[0]}"
fi

# The key goes in a 0600 curl config file rather than on a command line.
# /proc/<pid>/cmdline is world-readable and the office machine is not the
# authoring machine; on Windows the same argument is visible to any process
# that can read the process list. Nothing under $OUT ever contains it.
AUTH="$(mktemp)"
chmod 600 "$AUTH" 2>/dev/null
printf 'header = "Authorization: Bearer %s"\n' "$PROBE_API_KEY" > "$AUTH"
trap 'rm -f "$AUTH"' EXIT

# No -v anywhere: verbose curl echoes the request headers, and the
# Authorization header with them, into a file this script would then leave on
# disk. The -w fields below cover the same diagnostics -- TLS verification,
# which host answered, how long it took -- without the credential.
# size_upload and http_version are here because of what the August run could
# not answer. Three requests reached the upstream with empty bodies and nothing
# recorded said whether curl had put the bytes on the wire -- and "curl never
# sent it" and "something between curl and the app dropped it" have opposite
# fixes. size_upload settles that in one field. http_version is recorded
# alongside it because the failures were HTTP/2 through a CONNECT tunnel while
# every success was small enough to be uninteresting, and the version is the
# first thing to compare when the retry below behaves differently.
WFMT='http_code=%{http_code}
ssl_verify_result=%{ssl_verify_result}
remote_ip=%{remote_ip}
content_type=%{content_type}
size_upload=%{size_upload}
size_download=%{size_download}
http_version=%{http_version}
time_total=%{time_total}
url_effective=%{url_effective}
'

say() { printf '\n=== %s ===\n' "$*"; }

# Prints a short, safe extract of a captured body. The raw file is the record;
# this is so the operator can tell at the office whether to keep going.
summarize() {
  python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    raw = open(path, "rb").read()
except OSError as exc:
    print("  (could not read %s: %s)" % (path, exc))
    sys.exit(0)

if not raw.strip():
    print("  (empty body -- see the -curl-stderr.txt file beside it)")
    sys.exit(0)

try:
    body = json.loads(raw)
except ValueError:
    print("  (not JSON) " + raw[:400].decode("utf-8", "replace"))
    sys.exit(0)

if isinstance(body, dict) and "error" in body:
    err = body["error"]
    if isinstance(err, dict):
        for key in ("type", "code", "param", "message"):
            if err.get(key) is not None:
                print("  error.%s: %s" % (key, str(err[key])[:600]))
    else:
        print("  error: %s" % str(err)[:600])
    sys.exit(0)

choices = body.get("choices") if isinstance(body, dict) else None
if choices:
    msg = choices[0].get("message", {})
    content = msg.get("content")
    if content:
        print("  content: %s" % str(content)[:300].replace("\n", " "))
    # The one thing this endpoint has never yet done. Its absence is not proof
    # of much on its own -- a 200 with no tool_calls is what discarding the
    # schema looks like -- but its PRESENCE would end the second harness.
    if msg.get("tool_calls"):
        print("  tool_calls: PRESENT -- %d" % len(msg["tool_calls"]))
    if body.get("usage"):
        print("  usage: %s" % json.dumps(body["usage"]))
    sys.exit(0)

print("  " + json.dumps(body)[:400])
PY
}

# One request, captured completely. Body, response headers, curl's own stderr,
# and the transfer metadata each get their own file, and the body file is
# created up front so that "no file" is never ambiguous with "empty reply".
#
# Echoes the HTTP status on stdout; returns 0 only for 2xx.
request() {
  local label="$1" method="$2" path="$3" reqfile="${4:-}" extra="${5:-}"
  local meta rc code reqbytes=''
  local body="$OUT/$label-body.json"
  # An array rather than an unquoted string so shellcheck stays happy and an
  # option carrying a space cannot split. Expanded with the +alternate form
  # because `set -u` treats "${empty[@]}" as unbound on bash before 4.4, and
  # the machine this runs on at the office is not the machine it is written on.
  local -a xopt=()
  [ -n "$extra" ] && xopt=("$extra")

  : > "$body"
  # A reused output directory is normal at the office. Clear this label's
  # earlier artifacts up front, so a step that ends up sending nothing cannot
  # leave the previous run's HTTP status sitting beside a meta file saying
  # nothing was sent -- and that status is what gets read at a desk a week
  # later.
  rm -f "$OUT/$label-status.txt" "$OUT/$label-headers.txt"

  if [ "$method" = "POST" ]; then
    # Never post a body this script cannot vouch for. In August the request
    # bodies for step 3 were not built, curl posted the empty files without
    # complaint, and the endpoint's "Invalid JSON ... EOF at line 1 column 0"
    # was captured as though it were a finding about the endpoint. It was a
    # finding about the probe. A missing body is a probe failure and has to be
    # reported as one, because the alternative is a plausible HTTP status that
    # answers a question nobody asked.
    # -f as well as -s: `-s` alone is true for a directory on Linux, where a
    # directory has a nonzero size, and false on Windows, where it does not.
    # A path that is not a regular file is exactly the shape an environment
    # failure leaves behind, and curl would be handed it either way.
    if [ ! -f "$reqfile" ] || [ ! -s "$reqfile" ]; then
      printf '  !! could not build the request body: %s\n' "$reqfile"
      printf '     Nothing was sent, and there is no HTTP status for this step.\n'
      printf '     This is a probe failure, not an endpoint finding -- read\n'
      printf '     %s-generator-stderr.txt for why the body was not built.\n' "$label"
      printf 'request_bytes=0\nnot_sent=body-missing-or-empty\n' > "$OUT/$label-meta.txt"
      # 3, not 1: callers propagate this to the exit status, and 1 is
      # documented as "the endpoint never answered". A request that was never
      # built was never asked, and saying otherwise moves the very conflation
      # this guard exists to prevent somewhere a script would read it.
      return 3
    fi
    reqbytes=$(wc -c < "$reqfile" | tr -d ' ')
    meta=$(curl -sS -K "$AUTH" \
                -X POST \
                -H 'Content-Type: application/json' \
                -H 'Accept: application/json' \
                --max-time "$TIMEOUT" \
                -o "$body" \
                -D "$OUT/$label-headers.txt" \
                -w "$WFMT" \
                ${xopt[@]+"${xopt[@]}"} \
                --data-binary @"$reqfile" \
                "$BASE$path" 2>"$OUT/$label-curl-stderr.txt")
    rc=$?
  else
    meta=$(curl -sS -K "$AUTH" \
                -H 'Accept: application/json' \
                --max-time "$TIMEOUT" \
                -o "$body" \
                -D "$OUT/$label-headers.txt" \
                -w "$WFMT" \
                "$BASE$path" 2>"$OUT/$label-curl-stderr.txt")
    rc=$?
  fi

  printf '%s\ncurl_exit=%s\n' "$meta" "$rc" > "$OUT/$label-meta.txt"
  # What the probe meant to send, next to curl's own size_upload above. They
  # agree or something between this script and the wire is wrong, and that
  # comparison is the one August could not make.
  [ -n "$reqbytes" ] && printf 'request_bytes=%s\n' "$reqbytes" >> "$OUT/$label-meta.txt"
  code=$(printf '%s\n' "$meta" | sed -n 's/^http_code=//p')
  [ -n "$code" ] || code=000

  printf '  HTTP %s  (curl exit %s)  -> %s\n' "$code" "$rc" "$OUT/$label-body.json"
  if [ "$rc" -ne 0 ]; then
    # A transport failure -- DNS, TLS trust, proxy, timeout -- leaves no body
    # to read, so curl's own message is the whole finding.
    printf '  %s\n' "$(cat "$OUT/$label-curl-stderr.txt")"
  fi
  summarize "$body"

  printf '%s' "$code" > "$OUT/$label-status.txt"
  case "$code" in
    2*) return 0 ;;
    *)  return 1 ;;
  esac
}

# True when the captured body is the endpoint complaining about a body it never
# received -- a parse failure at the very first byte. That is the August
# signature, and it is worth exactly one retry. A refusal about size, auth, or
# model naming is a real answer and must not drag a retry in behind it.
empty_body_complaint() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    body = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)

err = body.get("error") if isinstance(body, dict) else None
if isinstance(err, dict):
    message = str(err.get("message") or "")
else:
    message = str(err or "")
message = message.lower()
sys.exit(0 if ("eof while parsing" in message or "line 1 column 0" in message) else 1)
PY
}

echo "probe.sh: writing every raw body to $OUT"
echo "  model:   $PROBE_MODEL"
echo "  base:    $BASE"

# --- 1a. Does the gateway answer at all, and by what name? -----------------
# The cheapest decisive request in the kit: no tokens, no generation, and it
# settles auth, TLS trust, and the exact spelling of the model in one call.
# Proxied mode has never been exercised against a real provider -- every run so
# far used placeholder endpoints -- so all three are unproven, and a model name
# that is one character out fails later in a way that reads like an outage.
say '1a. gateway reachable, and what it calls the model'
request 01a-models GET /models
models_rc=$?

# --- 1b. Does a plain completion get through? ------------------------------
# A model list can be served by the gateway without it ever having spoken to
# the provider. This is the first request that actually reaches through. If
# this fails, nothing below it means anything -- but the steps below still run,
# because their captured bodies are what get diagnosed at home.
say '1b. one plain completion, end to end'
python3 - "$OUT/01b-chat-req.json" "$PROBE_MODEL" \
  2>"$OUT/01b-chat-generator-stderr.txt" <<'PY'
import json
import sys

out, model = sys.argv[1], sys.argv[2]
json.dump({
    "model": model,
    "messages": [{"role": "user", "content": "reply with the single word: ok"}],
    "max_tokens": 16,
}, open(out, "w"))
PY
request 01b-chat POST /chat/completions "$OUT/01b-chat-req.json"
reach_rc=$?

if [ "$reach_rc" -eq 3 ]; then
  echo
  echo '  !! The request body could not be built, so reachability was never'
  echo '     tested. This is a failure of the probe, and nothing below it says'
  echo '     anything about the endpoint either way.'
elif [ "$reach_rc" -ne 0 ]; then
  echo
  echo '  !! Reachability failed. Everything below is still captured, but read'
  echo '     it as diagnostics rather than as findings: whatever step 2 does'
  echo '     with the tools parameter, a gateway that never reached the'
  echo '     provider proves nothing about it.'
fi

# --- 2. Is the premise true? -----------------------------------------------
# The entire two-harness design rests on this endpoint not doing tool calling.
# Answered on 2026-08-07: it accepts `tools`, returns prose with no tool_calls,
# and bills the same prompt_tokens as a request carrying no schema, so the
# definitions are discarded before the model sees them. Re-run it anyway -- it
# is two minutes, the endpoint could change under us, and it is the one step
# that can end the project in the best possible way: if tools start working,
# opencode drives this provider directly and the second harness is unnecessary.
say '2. the tools premise'
python3 - "$OUT/02-tools-req.json" "$PROBE_MODEL" \
  2>"$OUT/02-tools-generator-stderr.txt" <<'PY'
import json
import sys

out, model = sys.argv[1], sys.argv[2]
json.dump({
    "model": model,
    "messages": [{"role": "user", "content": "list the files in the current directory"}],
    "max_tokens": 64,
    "tools": [{
        "type": "function",
        "function": {
            "name": "bash",
            "description": "Run a shell command and return its output",
            "parameters": {
                "type": "object",
                "properties": {"command": {"type": "string"}},
                "required": ["command"],
            },
        },
    }],
}, open(out, "w"))
PY
request 02-tools POST /chat/completions "$OUT/02-tools-req.json"
tools_rc=$?

if [ "$tools_rc" -eq 0 ]; then
  echo
  echo '  Accepted the request. Read 02-tools-body.json before celebrating:'
  echo '  "accepted" splits into two very different findings -- a reply that'
  echo '  carries tool_calls means tools genuinely work and this design can be'
  echo '  deleted, while a reply with no tool_calls means the parameter was'
  echo '  silently ignored, which is the harder half of the premise.'
fi

# --- 3. How big is the context window? -------------------------------------
# Measured 2026-08-08 at ~160,000 tokens: an 800KB body was accepted at the top
# rung and billed as prompt_tokens=160001. That puts ~5,200 tokens of tool
# schema per turn at about 3% of the window -- see the table in
# spike/RESULTS.md, which is gitignored and local. Re-run it anyway; it is one
# request in the good case and the endpoint can change under us.
#
# Largest first, stopping at the first size the endpoint accepts. That order is
# what makes this cheap in the good case: if the largest size is accepted the
# window is enormous, one request settles it, and the schemas are a rounding
# error. Only a rejection costs another request, and a rejected request is
# rejected before generation, so it is billed for nothing.
say '3. context window'
echo "  ladder (tokens, largest first): $CONTEXT_LADDER"
accepted_at=''
rejected_at=''
# Rungs that actually reached the wire. Without this, a ladder whose bodies all
# failed to build reports that every size was refused -- a statement about the
# endpoint, from a step that never spoke to it.
attempted=0
for tokens in $CONTEXT_LADDER; do
  label="03-context-$tokens"
  python3 - "$OUT/$label-req.json" "$PROBE_MODEL" "$tokens" \
    2>"$OUT/$label-generator-stderr.txt" <<'PY'
import json
import sys

out, model, tokens = sys.argv[1], sys.argv[2], int(sys.argv[3])
# Four characters per token, the same estimate the rest of the spike tooling
# uses. The question is "is this 5% or 40% of the window", which an estimate
# settles; a real tokenizer would be a dependency for no extra answer.
filler = "word " * max(1, (tokens * 4) // 5)
json.dump({
    "model": model,
    "messages": [{"role": "user", "content": filler}],
    # Nothing is wanted back. If the request is accepted it is billed as
    # input, and there is no reason to pay for output on top of that.
    "max_tokens": 1,
}, open(out, "w"))
PY
  printf '\n  -- ~%s tokens --\n' "$tokens"
  request "$label" POST /chat/completions "$OUT/$label-req.json"
  ladder_rc=$?
  if [ "$ladder_rc" -eq 0 ]; then
    attempted=$((attempted + 1))
    accepted_at="$tokens"
    break
  fi
  # Nothing reached the wire, so this rung refused nothing. Counting it as a
  # rejection would put a bound on the window that no request ever tested.
  if [ "$ladder_rc" -eq 3 ]; then
    continue
  fi
  attempted=$((attempted + 1))

  # August: three rungs rejected for a body the upstream never received, and
  # the visit ended with no measurement and no mechanism. size_upload above now
  # says whether curl sent the bytes; this says whether anything can be done
  # about it. One extra request, rejected before generation and so billed for
  # nothing, against another month of not knowing.
  if empty_body_complaint "$OUT/$label-body.json"; then
    echo
    echo '  The endpoint is reporting a body it never received. That is not a'
    echo '  finding about the window -- retrying over HTTP/1.1, because every'
    echo '  failure of this shape so far was HTTP/2 through a CONNECT tunnel.'
    if request "$label-retry-http11" POST /chat/completions \
               "$OUT/$label-req.json" --http1.1; then
      echo
      echo "  !! The retry SUCCEEDED. The window is at least ~$tokens tokens, and"
      echo '     the earlier rejection was about the protocol, not the size.'
      echo '     Compare size_upload in the two meta files and record BOTH --'
      echo '     this also means large requests need --http1.1 to get through.'
      accepted_at="$tokens"
      break
    fi
    echo
    echo '     The retry failed the same way. Compare size_upload across both'
    echo '     meta files: nonzero means the bytes left this machine and'
    echo '     something upstream dropped them; zero means curl never sent'
    echo '     them and the problem is on this side.'
  fi

  # Set only once the rung has genuinely been refused, retry included. Clearing
  # it on a successful retry would be wrong: the retry says this rung was never
  # really refused, and says nothing about a larger rung that was. Largest
  # first means this ends up holding the smallest size actually refused, which
  # is the tight upper bound for the bracket below.
  rejected_at="$tokens"
done

echo
if [ "$attempted" -eq 0 ]; then
  echo "  No size was tried: none of the request bodies could be built, so"
  echo "  nothing was sent and nothing was refused. This says nothing about the"
  echo "  window or the endpoint -- read the generator-stderr files."
elif [ -n "$accepted_at" ] && [ -n "$rejected_at" ]; then
  echo "  Window is between ~$accepted_at and ~$rejected_at tokens."
elif [ -n "$accepted_at" ]; then
  echo "  Accepted ~$accepted_at tokens, the largest size tried: the window is"
  echo "  at least that, and the tool schemas are a rounding error."
else
  echo "  Every size was refused, including the smallest. That is three things"
  echo "  at once -- a window under the smallest rung, a refusal that is not"
  echo "  about size, or no connection at all -- and the captured bodies and"
  echo "  curl-stderr files tell them apart. Do not conclude from the bracket."
fi
echo "  Providers usually name their own limit in the rejection. Read it out of"
echo "  the captured body rather than inferring it from the bracket."

# --- 4. Does a harness survive a real multi-turn task? ---------------------
# The trip. Everything above is minutes; this is the question the visit exists
# to answer, and it needs a real repository and a human watching, so it is run
# by hand rather than from here.
say '4. the multi-turn run (run this by hand)'
cat <<EOF
  In a scratch repository, with the gateway up:

    cranopener -Model $PROBE_MODEL "add a failing test, then make it pass" \\
      2>&1 | tee $OUT/04-run.log

  Then, still at the office and before leaving:

    - record the turn count, whether it finished, and where it derailed
    - if it derails, raise CRANOPENER_MAX_ITERATIONS and run it once more --
      the default is a bound, not a budget, and a run stopped by the cap looks
      a lot like a run that gave up
    - keep 04-run.log whatever happens. It is the only record of this step,
      and it is the step that cannot be repeated for a month.
EOF

say 'done'
echo "Raw bodies, headers, and transfer metadata: $OUT"
echo "Fill in a copy of $HERE/RESULTS-template.md before leaving the building."
if [ "$models_rc" -ne 0 ]; then
  echo "Note: the model list (1a) did not return 2xx."
fi

exit "$reach_rc"
