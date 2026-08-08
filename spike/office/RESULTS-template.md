# Office trip — <date>

Copy this file, fill it in **before leaving the building**, and keep it
alongside the `out/` directory the probe wrote. Both are local: `out/` is
gitignored because it contains prompts, responses, and the endpoint's own
identifying detail.

Anything left blank is a question that waits another month.

---

## 1a. Gateway reachable, and what it calls the model

Files: `out/01a-models-*`

- HTTP status: `<n>`
- The model id the gateway lists, verbatim: `<id>`
- Does it match what was passed as `PROBE_MODEL`: `<yes | no — differs how>`
- Verdict: `<reached | auth rejected | TLS trust failed | proxy blocked | no route>`
- Notes:

## 1b. One plain completion, end to end

Files: `out/01b-chat-*`

- HTTP status: `<n>`
- Replied: `<yes | no>`
- Verdict: `<reached the provider | auth failed | TLS failed | model name rejected | gateway reached but provider did not>`
- Notes:

**If this failed, stop and read the decision table's first row.** The steps
below were still captured, but whatever step 2 does with `tools`, a gateway
that never reached the provider says nothing about the provider.

## 2. The tools premise

Files: `out/02-tools-*`

- HTTP status: `<n>`
- Behaviour: `<hard rejection | accepted and silently ignored | tools actually worked>`
- Did the reply carry `tool_calls`: `<yes | no>`
- Baseline to compare against — 2026-08-07 measured *accepted and silently
  ignored*: HTTP 200, no `tool_calls`, and `prompt_tokens` identical to the
  same request with no schema at all. Anything else here is a change worth
  writing up, in either direction.
- Verbatim error, if any:

```
<paste from out/02-tools-body.json>
```

**If tools actually worked, stop.** Delete the OpenHands path and point
opencode straight at this provider. That is the cheapest outcome available and
it invalidates the rest of this work by design. "Accepted" alone is not that
finding — a 200 with no `tool_calls` in the reply means the parameter was
ignored, and prompt-mode tool calling is still required.

## 3. Context window

Files: `out/03-context-*`

- Largest size accepted: `~<n>` tokens
- Smallest size rejected: `~<n>` tokens
- Limit stated in the rejection or the docs: `<n>`
- Tool schemas measured at ~5,203 tokens, so schemas alone are `<n>%` of the
  window

Apply the table in `spike/RESULTS.md` (local, gitignored — it holds the
per-tool measurement this percentage comes from):

| Schemas as a share of context | Verdict |
|---|---|
| under 10% | Fine. No action needed. |
| 10–25% | Workable, but trim the tool set for long autonomous runs. |
| over 25% | Too large. Cut the tool set before building on this. |

- Verdict: `<fine | trim the tool set | cut tools first>`

## 4. The multi-turn run

Files: `out/04-run.log`

- `CRANOPENER_MAX_ITERATIONS` used: `<n>`
- Turns reached: `<n>`
- Completed the task: `<yes | no>`
- Stopped by: `<finished | iteration cap | wall clock | conversation error | derailed>`
- Where it derailed:
- Did any tool call parse at all: `<yes | no>`
- Verdict: `<ship | tune config and retest | switch to aider | both failed>`

A run stopped at the iteration cap is not a failed run. The cap is a bound and
not a budget; if that is what ended it, raise it and go again while the
endpoint is still in reach.

---

## Decision

The rows below are the whole table — they are reproduced here rather than
referenced, because the design document they came from is kept out of this
public repository and a reader on the day would have nothing to follow.
Thresholds were set in advance so the call is not made by whatever feels
encouraging after a long drive.

| What the trip shows | Decision |
|---|---|
| The gateway cannot reach provider A | Not a harness finding. The trip yields a gateway fix list; the harness question stays open. |
| Tools actually work | **Stop. Delete this design.** Point opencode straight at provider A. Cheapest possible outcome. |
| OpenHands finishes a multi-turn task | Ship. This phase becomes configuration and documentation. |
| Parses, but derails mid-loop | Tune only what configuration can tune — iteration cap, prompt, tool subset, temperature. **Do not write a parser.** Re-test next trip. |
| Output does not parse at all | Switch to aider. Already installed; its edit format is a flag with an upstream per-model leaderboard behind it. |
| Both harnesses fail | Provider A cannot drive an agentic loop. Ship providers B and C only. |

The fourth row needs guarding hardest. "It almost works, I will just add a
small parser" is precisely how this project ends up owning a dialect tuned
blind against an endpoint that can be observed once a month.

**Decision:** `<gateway fix list | delete this design | ship | tune and retest | switch to aider | providers B and C only>`

**Rationale:**

**What the next trip must answer, if there is one:**
