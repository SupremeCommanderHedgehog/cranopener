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

## Phase 1 end-to-end (Task 11) — verified 2026-08-05, Windows

Run on the authoring machine, which does have podman after all.

| | |
|---|---|
| podman | 5.8.2, WSL2 machine running |
| `podman compose` provider | **docker-compose v5.1.4** (external) |
| Rootless | **false** — rootful *inside* the WSL VM |
| Direct mode | pass |
| Gateway health | pass |
| Proxied mode, cold start | pass, 13s |
| opencode to gateway over the compose network | pass, HTTP 200 |
| Project isolation | pass, distinct names and workspaces |
| `-Down` | pass, containers and network removed |

**Bind mounts need no UID mapping on Windows.** The WSL mount presents
everything as `opencode`-owned `drwxrwxrwx`; the container writes and the file
appears on the Windows side. The `keep-id` problem that blocked the Linux build
host does not exist here, which is why it was right not to patch it blind.

**Rootless is false.** The machine runs rootful inside its own WSL VM. No
Windows administrator rights are needed at runtime, but it is not literally
"rootless podman" as the requirement stated. Worth confirming this satisfies
whatever the requirement was protecting.

**Workspace bind-mount performance was not measured** on a large repository.
This repo is small. If builds crawl on a real project, the escape hatch is a
named volume.

### Three bugs this found, all now fixed

**The litellm image ships no `curl`.** Both the compose healthcheck and the
launcher's readiness poll used it. A healthcheck referencing a missing binary
never reports healthy, so the symptom was a 60s timeout in front of a running,
perfectly functional gateway. Both now use the image's `python3`.

**Windows Defender blocks a `python3 -c` readiness probe as malware.** The
launcher polled the gateway with

```
podman compose exec -T litellm python3 -c "import urllib.request; urllib.request.urlopen(...)"
```

which `podman compose` runs through `docker-compose.exe` as a *Windows*
process. Defender's command-line heuristic scores inline Python that opens a
URL as a downloader and kills it — `Trojan:Win32/Commando.A!ml`, logged as
`CmdLine:_...` rather than a file, once per poll iteration. The visible
symptom is `fork/exec ... Access is denied`, which looks exactly like an
argument-quoting bug and was initially misdiagnosed as one.

The launcher no longer execs anything. It reads the compose healthcheck via
`podman inspect`, which defines readiness in one place and never constructs a
Windows command line that resembles a stager. The healthcheck itself runs the
same Python *inside* the container, where Defender does not see it.

Worth remembering as a general rule for this project: **any probe the launcher
runs is a Windows command line and is subject to AV heuristics**, however
innocuous it is on Linux.

**Config seeding warned on every launch.** Bind-mounting files into
`/home/opencode/.config/opencode/` makes podman create the parent root-owned,
so `seed-config.sh` fails and the entrypoint prints a warning every time --
noise that reads like a fault. Both stacks now set
`CRANOPENER_SEED_SRC=/nonexistent`, since config comes from the mounts and
there is nothing to seed.

### Independent confirmation of the budget finding

`/health/readiness` returns `{"status":"healthy","db":"Not connected"}`.
That is the code review's finding confirmed from the running system: with no
database, the spend cap is not enforced.

## Still pending

- Single-turn parse rate (office)
- Multi-turn parse rate (office) — the decisive one
- GenAI context window (office) — turns the table above into an answer
- Proxied mode against a **real** model. Everything above used placeholder
  endpoints, so the gateway was never asked to reach a provider. The first
  real call may still surface auth, TLS, or model-name problems.
- Workspace performance on a large repository.
