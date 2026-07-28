# Security Policy

## Reporting a vulnerability

Please report security issues through
[GitHub private vulnerability reporting](https://github.com/SupremeCommanderHedgehog/cranopener/security/advisories/new)
rather than opening a public issue.

This is a personal project maintained on a best-effort basis. Expect an initial
response within a couple of weeks, not within hours.

## What this project is

`cranopener` is a Dockerfile and a set of build scripts. It publishes a
container image that bundles [opencode](https://opencode.ai) with language
toolchains from Debian and from each language's upstream distributor.

Almost all code in the published image comes from those upstreams, not from
this repository. A vulnerability in Debian, Go, Rust, .NET, Julia, R, Node.js,
or opencode itself should be reported to that project. Report it here only if
this repository's own packaging is what introduces or worsens the exposure.

## Supported versions

Only the current `latest` image receives fixes. Older tags are immutable
historical artifacts and are never patched in place — a fix means a new build
with a new digest.

## Design notes relevant to security

- **No credentials are baked in.** API keys are supplied at runtime as
  environment variables. Nothing secret is committed or built into a layer.
- **The image runs as an unprivileged user** (uid 1000), not root.
- **Versions are resolved at build time, not pinned.** This is deliberate: it
  means the monthly rebuild picks up upstream security patches without anyone
  having to notice they exist. The tradeoff is that builds are not
  byte-reproducible, so a compromised upstream release would be pulled in
  automatically. OCI labels record exactly what each image contains.
- **The Julia download is checksum-verified** against the digest its publisher
  ships. Other downloads rely on HTTPS and the publisher's apt signing keys.
- **Images carry signed provenance attestations**, so you can verify an image
  was built by this repository's workflow:

  ```bash
  gh attestation verify \
    oci://ghcr.io/supremecommanderhedgehog/cranopener:latest \
    --owner SupremeCommanderHedgehog
  ```

## Scope

The image is a development sandbox containing compilers, package managers, and
an AI agent that executes code. It is not a hardened runtime and should not be
treated as a security boundary. Run untrusted workloads in a VM or another
isolation layer you actually trust.
