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

## Running under podman compose

For unattended runs behind an API gateway: model credentials isolated from the
container that executes commands, retries and a spend cap at the gateway, and
no permission prompts to stall a session nobody is watching.

```powershell
pwsh -File scripts\install.ps1   # copies templates to ~\.cranopener
# fill in ~\.cranopener\litellm\config.yaml, .env, and certs\
cranopener                       # against the current directory
cranopener -Direct               # bypass the gateway, use stock providers
cranopener -Down                 # stop this project's stack
```

Two things that bite if you skip them. `certs/dod-roots.pem` must be a
**complete** CA bundle — the gateway points `SSL_CERT_FILE` at it, which
replaces the default trust store rather than adding to it, so a roots-only or
empty file makes every upstream call fail looking like a provider outage. And
the spend cap in `config.yaml` is **not enforced**: LiteLLM tracks spend in
Postgres and this stack provisions none, so bound unattended runs some other
way.

The launcher exists because compose resolves relative volume paths against the
compose file rather than the shell, derives its project name from that same
directory, and gives `up` no terminal for the TUI. It sets the workspace path
and a per-directory project name, then runs opencode in the foreground.

Templates in `compose/` carry placeholder endpoints. Real hostnames, model
identifiers, and credentials belong only in `~\.cranopener`, which is never
committed. `install.ps1` never overwrites what is already there, and reports
which files have drifted from the shipped templates.

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
