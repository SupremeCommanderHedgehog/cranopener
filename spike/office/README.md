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

## Where to run it

WSL2 on the office machine is the right host — it has curl, python3, the CA
trust, and the proxy. But **give it an output directory on the VM's own
filesystem, not under `/mnt/c`**:

```bash
bash probe.sh ~/probe-out                  # ext4 inside the VM
cp -r ~/probe-out /mnt/c/<wherever>/out    # once, at the end
```

`/mnt/c` is drvfs, the bridge to Windows NTFS, and it is slow and semantically
odd for exactly the thing step 3 does: write an 800 KB file and immediately
hand its path to curl. This is hygiene, not a fix for a known cause — an 800 KB
write to `/mnt/c` has since succeeded, so drvfs does not explain the 2026-08-07
failure. It costs nothing to keep the time-sensitive work on the VM and make
the one crossing to Windows a bulk copy after the network work is done, so do
that; just do not treat it as the answer.

Leave `TMPDIR` alone while you are at it. The probe writes the API key to a
`mktemp` file and `chmod 600`s it so the credential never reaches a command
line, and that only holds because WSL2's `/tmp` is ext4. Point `TMPDIR` at
`/mnt/c` and the `chmod` silently does nothing.

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

**3 — the context window.** **Measured 2026-08-08: at least ~160,000 tokens.**
An 800 KB body was accepted at the top rung — `HTTP 200`, `finish_reason:
stop`, `prompt_tokens: 160001` — so ~5,200 tokens of tool schema per turn is
about 3% of the window and the schemas are a rounding error. `spike/RESULTS.md`,
local and gitignored, holds the table this number turns into an answer.

Re-run it anyway. It is one request in the good case, the endpoint can change
under us, and the ladder walks largest first and stops at the first size
accepted — so a smaller answer next time costs one extra request, and a request
rejected for size is rejected before generation and billed for nothing.

The step was lost once, on 2026-08-07, and it is worth knowing how. All three
rungs came back `400 Invalid JSON in request body: EOF while parsing a value at
line 1 column 0` — the endpoint complaining about a body it never received —
while the only two requests in that run under 1 KB both succeeded.

**It has not reproduced since, and the mechanism is unexplained.** Two later
runs sent the identical 800 KB body over the same HTTP/2 CONNECT tunnel to the
same address and got 200, with `size_upload` confirming all 800,099 bytes left
the machine. What is ruled out: curl's `Expect: 100-continue`, which curl does
not send at those sizes and never would over HTTP/2. What is *not* established
is the filesystem theory, tempting as the file-size correlation is — one of the
two successful runs also wrote to `/mnt/c`, so drvfs does not by itself explain
it. If it recurs, `size_upload` next to `request_bytes` says in one line which
side of the wire lost the body, and a rejection of that exact shape costs one
retry over `--http1.1`.

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
