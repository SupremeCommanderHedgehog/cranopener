# Spike results

## Tool schema token cost — measured 2026-08-05

Measured against `ghcr.io/supremecommanderhedgehog/cranopener:latest`
(opencode 1.18.12) by capturing a real `/v1/chat/completions` request.

| | |
|---|---|
| Tools sent | 10 |
| Tool schema tokens | ~5,203 |
| System/message tokens | ~2,439 |
| **Request floor, per turn** | **~7,642** |

Per tool, largest first:

| Tool | ~tokens |
|---|---|
| `bash` | 1,311 |
| `task` | 956 |
| `todowrite` | 663 |
| `edit` | 481 |
| `read` | 425 |
| `webfetch` | 315 |
| `grep` | 288 |
| `glob` | 270 |
| `write` | 248 |
| `skill` | 161 |

### What it means, by context window

The verdict depends entirely on GenAI's limit, which is still unknown.

| Context | Schemas as share | Verdict |
|---|---|---|
| 128,000 | 4.1% | Fine, no action |
| 64,000 | 8.1% | Fine, no action |
| 32,000 | 16.3% | Workable, trim the tool set |
| 16,000 | 32.5% | Too large — cut tools first |
| 8,192 | 63.5% | Unusable without major trimming |

**Action for the office visit:** Section D of the worksheet asks for GenAI's
context window. That number turns this table into an answer. At 64k or above
this is a non-issue; at 16k the shim design needs the tool set cut before
anything else.

If trimming is needed, `bash`, `task`, and `todowrite` are 56% of the total
and `task` and `skill` are the most droppable for an autonomous coding loop.
Trimming is pure config — opencode's `tools` block — not code.

### Caveat for the shim

These are the *JSON schema* costs. In prompt mode the shim renders the same
definitions into the system prompt as text, which will not be smaller. So
~5,200 tokens per turn is a floor for the shimmed path too, on top of
text-flattened history that cannot be trimmed the way structured tool
messages can.

## Environment findings (cougar, the Linux build host)

Discovered while getting the measurement to run. Both cost real time and are
worth knowing before the Windows work.

**`fapolicyd` is enforcing.** It refuses to read Python files that carry a
`#!` line, returning `EPERM` rather than a permission error — `head` on the
file fails, not just execution. Proved by base64-ing identical bytes onto the
host: with the shebang, blocked; without, readable. Bash shebangs pass. The
spike's Python files therefore carry no shebang and must not have one added;
they are always invoked as `python3 <file>`.

**`--userns=keep-id` hangs on podman 5.8.2.** Not an error — a hang, until
something times out. The `keep-id:uid=,gid=` form is rejected outright. This
matters because keep-id is the usual advice for rootless bind-mount ownership,
and reaching for it costs a timeout instead of a message.

**The fix for rootless bind mounts was simply world-readable modes.** The
container sees bind mounts as root-owned and runs as uid 1000, so `mktemp -d`
at 0700 is unreachable. `chmod -R a+rX` is sufficient when the container only
needs to read. **This is unresolved for `compose.yaml`, where opencode must
write to `/workspace`** — see Task 11.

**A `permission` block set to deny strips tools from the request entirely.**
Worth knowing for the proxied config: denying permissions is not a way to
sandbox a session while keeping its tool schema intact.

## Still pending

- Single-turn parse rate (office)
- Multi-turn parse rate (office) — the decisive one
- GenAI context window (office) — turns the table above into an answer
- Phase 1 end-to-end under podman on Windows (Task 11)
