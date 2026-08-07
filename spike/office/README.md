# Office verification kit

The provider-A endpoint is reachable only from the office, at roughly one visit
a month. This kit is built to be run once per visit and to leave nothing that
needs a second trip.

```bash
export PROBE_BASE_URL=...   # the gateway, ending in /v1
export PROBE_MODEL=...      # the model id as the gateway names it
export PROBE_API_KEY=...    # bearer token for the gateway

bash spike/office/probe.sh          # writes to spike/office/out
bash spike/office/probe.sh /some/where   # or somewhere else
```

Then copy `RESULTS-template.md`, fill it in **before leaving the building**,
and apply the decision table at the end of it.

Nothing in this directory names an endpoint, a model, or a credential — the
target comes entirely from the environment, because this repository is public.
Run the probe with nothing set and it says which variables are missing rather
than issuing a request against an empty URL.

## What it needs

`curl` and `python3`. Not `jq` — jq is absent on the Windows machines this is
run from and present only on the Linux build host, and a probe that cannot run
at the office is worth nothing. `PROBE_MODEL` is the model id the gateway
publishes, the same string you would pass to `cranopener -Model`.

## The order, and why it is that order

Steps 1 to 3 take minutes and answer questions outstanding since the first
phase. Step 4 is the trip.

**1a — the model list.** The cheapest decisive request available: no tokens, no
generation, and it settles auth, TLS trust, and the exact spelling of the model
in one call. Proxied mode has never been exercised against a real provider —
every run so far used placeholder endpoints — so all three are unproven, and a
model name one character out fails later in a way that reads like an outage.

**1b — one plain completion.** The gateway can list models without ever having
spoken to the provider. This is the first request that actually reaches
through. If it fails, nothing below it means anything — but the later steps
still run, because their captured bodies are what get diagnosed at home.

**2 — the tools premise.** This step can end the whole project in the best
possible way: if the endpoint turns out to accept `tools` after all, opencode
drives it directly and the second harness is unnecessary. Confirm the premise
before spending the visit on the thing built to work around it. Note that a 200
is two different findings — a reply carrying `tool_calls` means tools genuinely
work, while a 200 with no `tool_calls` means the parameter was silently
ignored, which still requires prompt-mode tool calling.

**3 — the context window.** Still unmeasured, and it decides whether ~5,200
tokens of tool schema per turn is 4% of the window or 64%. The probe walks a
ladder of oversized requests largest first and stops at the first one accepted,
so the good case costs a single request and only a rejection costs another —
and a request rejected for size is rejected before generation, so it is billed
for nothing. `spike/RESULTS.md`, which is local and gitignored, holds the table
this number turns into an answer.

This is the step the August run lost. All three rungs came back `400 Invalid
JSON in request body: EOF while parsing a value at line 1 column 0` — the
endpoint complaining about a body it never received — while both smaller
requests, the only two under 1 KB in the whole run, succeeded. The mechanism is
still unknown: curl sends no `Expect: 100-continue` at those sizes, and nothing
captured recorded whether the bytes ever left the machine. So a rejection of
that exact shape now costs one retry over HTTP/1.1, because every failure of it
so far was HTTP/2 through a CONNECT tunnel. If the retry succeeds, the window
is at least that rung and large requests need `--http1.1` to get through. If it
fails the same way, `size_upload` in the two meta files says which side of the
wire lost the body.

**4 — the multi-turn run.** Run by hand, in a scratch repository. Not "does it
parse once" — does it reach turn ten and finish something.

## Everything is captured, always

Every request and every response is written to the output directory whatever
the outcome: the request body, the raw response body, the response headers,
curl's own stderr, and the transfer metadata including the TLS verification
result. The body file is created before the request is made, so an empty file
never has to be told apart from a missing one.

The August run showed that this covered only half the wire. The response was
captured completely and the request barely at all, so a step that failed on the
way out left a captured 400 that read like a finding about the endpoint. Three
things close that gap. `size_upload` records what curl actually put on the
wire, next to `request_bytes` for what the probe meant to send — when those
disagree, or when both are nonzero and the endpoint still reports an empty
body, the answer is in the difference. The probe's own output is teed to
`00-probe-log.txt`, because the account of a step that dies before curl runs is
otherwise spoken only to a terminal in a building you are about to leave. And a
request body that could not be built is never sent: there is no HTTP status for
that step at all, only the generator's error in `<step>-generator-stderr.txt`,
because a plausible status code answering a question nobody asked is worse than
no answer.

That is the point of the kit. A failed trip has to be diagnosable at a desk
against captured bytes, because the next chance to look is a month away.

The output directory is gitignored — it contains prompts, responses, and the
endpoint's own identifying detail. The probe never writes the API key
anywhere: it goes into a mode-0600 curl config file rather than onto a command
line, and `curl -v`, which would echo the `Authorization` header into a
capture file, is deliberately not used.
