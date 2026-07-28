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
