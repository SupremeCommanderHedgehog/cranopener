# cranopener

[opencode](https://opencode.ai) in a container, with a polyglot toolchain and
sensible defaults baked in.

```bash
docker run -it --rm \
  -v "$PWD:/workspace" \
  -e ANTHROPIC_API_KEY \
  ghcr.io/supremecommanderhedgehog/cranopener:latest
```

## What's inside

Debian trixie, running as an unprivileged user, with:

| | |
|---|---|
| **Languages** | C, C++, C#, F#, Go, Julia, Node.js, Python, R, Rust |
| **Package managers** | npm, pnpm, uv, pip, cargo, dotnet |
| **Tools** | git, git-lfs, gh, jq, ripgrep, fd, cmake, build-essential |

The image is about 3.9 GB on disk.

## Tags

| Tag | Meaning |
|---|---|
| `latest` | Most recent successful build |
| `<version>` | opencode version, e.g. `1.18.7` |
| `<version>-<sha>` | Immutable |
| `sha-<sha>` | Immutable, keyed to the commit |

## Credentials

API keys are passed at runtime and are never baked into the image:

```bash
docker run -it --rm -v "$PWD:/workspace" \
  -e ANTHROPIC_API_KEY -e OPENAI_API_KEY \
  ghcr.io/supremecommanderhedgehog/cranopener:latest
```

## Configuration

Defaults ship at `/etc/opencode` and are copied into `~/.config/opencode` at
startup **without overwriting anything already there**. Mount your own config
and it wins:

```bash
docker run -it --rm \
  -v "$PWD:/workspace" \
  -v "$HOME/.config/opencode:/home/opencode/.config/opencode" \
  ghcr.io/supremecommanderhedgehog/cranopener:latest
```

## Running under podman kube

For unattended runs behind an API gateway: model credentials isolated from the
container that executes commands, retries and a spend cap at the gateway, and
no permission prompts to stall a session nobody is watching.

```powershell
pwsh -File scripts\install.ps1   # copies templates to ~\.cranopener
# fill in ~\.cranopener\litellm\config.yaml and certs\, then export your keys
cranopener                       # against the current directory
cranopener -Direct               # bypass the gateway, use stock providers
cranopener -Down                 # stop the shared gateway
```

The gateway is a long-lived pod shared by every project; a session is a
foreground container that joins it with `--pod`. They use different mechanisms
because they are different kinds of thing — `podman kube play` describes a
service well and an interactive one-shot badly.

Three things that bite if you skip them. **Credentials come from the
environment**, never a file: export `PROVIDER_A_API_KEY` and friends before
launching, and the launcher pipes them to the gateway over stdin so they never
reach a command line. **`certs/extra-roots.pem` must be a complete CA bundle** —
the gateway points `SSL_CERT_FILE` at it, which replaces the default trust
store rather than adding to it, so a roots-only or empty file makes every
upstream call fail looking like a provider outage. And **the spend cap is not
enforced**: LiteLLM tracks spend in Postgres and this stack provisions none, so
bound unattended runs some other way.

`-Down` stops the gateway for every project, not just this one.

Templates in `kube/` carry placeholder endpoints. Real hostnames, model
identifiers, and credentials belong only in `~\.cranopener`, which is never
committed. `install.ps1` never overwrites what is already there, and reports
which files have drifted from the shipped templates.

## Two harnesses

Providers that support native tool calling run under opencode. One provider
does not accept the `tools` parameter at all, so it runs under OpenHands
instead, which renders the tool definitions into the prompt and parses the
calls back out of the reply. Nothing here translates between the two: a shim
that made a tool-refusing endpoint look tool-capable to opencode was designed,
costed, and cancelled, and the second harness exists so that this repository
never owns one.

```powershell
cranopener                                        # opencode, whatever its config names
cranopener -Model provider-b/a-model run "..."    # opencode, explicit model
cranopener -Model provider-a/a-model "fix the failing test"   # OpenHands, NO verb
```

Note the missing `run` on the last line. It is opencode's verb, and the
OpenHands path has none — the whole argument list is the task, so `run` would
become the first word of the prompt and the session would spend its entire
iteration budget on an instruction nobody wrote, then report success. The
launcher refuses that combination rather than absorbing it.

`-Model` takes the model id as the gateway names it, and the harness follows
from that id. There is no flag to pick one, because a flag can be set to
contradict the model: point opencode at a provider that refuses tools and it
fails on its first tool call, with an error that reads as a gateway outage
rather than a misconfiguration. That is expensive to diagnose and trivial to
prevent, so the combination is not expressible. The other known-bad pairing is
refused outright — `-Direct` with such a model is an error, since that provider
exists only behind the gateway and `-Direct` is what bypasses it.

Both harnesses are in the image, along with aider as a fallback. Nothing is
installed at run time: the target site is behind a proxy with its own CA
bundle, and a fallback that has to be downloaded on the day it is needed is not
a fallback.

**Bound every unattended run.** `CRANOPENER_MAX_ITERATIONS`, default 50, stops
the OpenHands path after that many events in the harness's own event stream.
It is a bound, not a budget: an event is not an agent step, so 50 events is
roughly 15 to 25 real steps, and it should be set well above what the task
needs rather than tuned down to it. It exists because nothing else would stop a
runaway loop — the harness's own limit is 500 completions and is not
configurable, and the spend cap at the gateway is the unenforced one described
above. `CRANOPENER_TIMEOUT_SECONDS`, default 3600, is the wall-clock backstop
for a loop that emits no events at all.

Exit status means what it says on this path. The underlying CLI exits 0 even
when every request to the provider failed — measured, on a run that took a hard
rejection on all 500 of them — so the verdict is taken from the event stream
instead: a conversation error, a run that never reached the provider, or a run
stopped by either bound all exit non-zero and print why.

## How it stays current

A scheduled build runs on the 1st of each month. It resolves the latest
opencode, Go, and Julia releases and picks up a month of Debian security
updates in one pass. Nothing needs pinning and nothing needs watching.

To pull a new opencode release without waiting, run the `build` workflow
manually — the `opencode_version` input accepts a specific version, or leave it
blank for latest.

Every image records what went into it:

```bash
docker inspect --format '{{json .Config.Labels}}' \
  ghcr.io/supremecommanderhedgehog/cranopener:latest | jq
```

## Development

There is no container engine on the authoring machine; images are built on a
Linux host over SSH.

```bash
cp .env.example .env               # point at your own Linux build host
bash tests/run-all.sh              # shell unit tests, offline
bash scripts/dev/remote-build.sh   # sync, build, and smoke test on the build host
```

`.env` is gitignored. Configuration can also be supplied purely through the
environment via `CRANOPENER_BUILD_HOST`, `CRANOPENER_BUILD_KEY`, and
`CRANOPENER_BUILD_DIR`.

## Known limits

- `linux/amd64` only. Apple Silicon runs it under emulation.
- The first pull is large.
- Builds are not byte-reproducible by design; labels record what shipped.

## Security

See [SECURITY.md](SECURITY.md) for reporting and for the security-relevant
design decisions. Images carry signed provenance, so you can verify one was
actually built by this repository:

```bash
gh attestation verify \
  oci://ghcr.io/supremecommanderhedgehog/cranopener:latest \
  --owner SupremeCommanderHedgehog
```

## Licensing

Two different things, licensed differently:

- **This repository** — the Dockerfile, scripts, and workflow — is [MIT](LICENSE).
- **The image it produces** is an aggregate of software from Debian and from
  each toolchain's upstream, under many licenses including GPL-2.0, GPL-3.0,
  Apache-2.0, BSD, MPL, and MIT. The image's
  `org.opencontainers.image.licenses` label is therefore `NOASSERTION` — the
  SPDX value meaning no single expression is being claimed. Bundling those
  together is mere aggregation; each component remains under its own license,
  and Debian publishes corresponding sources for everything it ships.

If you need a license inventory for compliance, generate one from the image
rather than trusting a summary:

```bash
docker run --rm ghcr.io/supremecommanderhedgehog/cranopener:latest \
  sh -c 'for d in /usr/share/doc/*/copyright; do echo "$d"; done' | head
```
