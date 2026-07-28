# syntax=docker/dockerfile:1

########################  stage: fetch  ########################
FROM debian:trixie-slim AS fetch

ARG OPENCODE_VERSION

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    test -n "${OPENCODE_VERSION}"; \
    curl -fsSL -o /tmp/opencode.tar.gz \
      "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-x64.tar.gz"; \
    mkdir -p /out; \
    tar -xzf /tmp/opencode.tar.gz -C /out; \
    chmod +x /out/opencode; \
    /out/opencode --version

########################  stage: runtime  ########################
FROM debian:trixie-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# --- core toolchain ---
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg \
      git git-lfs openssh-client \
      jq ripgrep fd-find less unzip xz-utils procps \
      build-essential cmake pkg-config \
      python3 python3-pip python3-venv; \
    ln -s "$(command -v fdfind)" /usr/local/bin/fd; \
    rm -rf /var/lib/apt/lists/*

# --- opencode ---
COPY --from=fetch /out/opencode /usr/local/bin/opencode

# --- unprivileged user ---
RUN set -eux; \
    groupadd -g 1000 opencode; \
    useradd -u 1000 -g 1000 -m -s /bin/bash opencode; \
    mkdir -p /workspace; \
    chown opencode:opencode /workspace

# --- GitHub CLI ---
RUN set -eux; \
    mkdir -p -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*; \
    gh --version

# --- Node.js ---
ARG NODE_MAJOR=24
RUN set -eux; \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    npm install -g pnpm; \
    npm cache clean --force; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; pnpm --version

# --- uv ---
RUN set -eux; \
    curl -fsSL https://astral.sh/uv/install.sh -o /tmp/uv-install.sh; \
    UV_INSTALL_DIR=/usr/local/bin sh /tmp/uv-install.sh; \
    rm /tmp/uv-install.sh; \
    uv --version

# --- Go ---
ARG GO_VERSION
ENV PATH=/usr/local/go/bin:$PATH
RUN set -eux; \
    test -n "${GO_VERSION}"; \
    curl -fsSL -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"; \
    tar -C /usr/local -xzf /tmp/go.tar.gz; \
    rm /tmp/go.tar.gz; \
    go version

# --- Rust ---
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN set -eux; \
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh; \
    sh /tmp/rustup.sh -y --profile minimal --no-modify-path; \
    rm /tmp/rustup.sh; \
    chmod -R a+w "$RUSTUP_HOME" "$CARGO_HOME"; \
    rustc --version; cargo --version

# --- .NET SDK (C# and F#) ---
ARG DOTNET_CHANNEL=LTS
ENV DOTNET_ROOT=/usr/local/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    PATH=/usr/local/dotnet:$PATH
# libicu is required: trixie-slim ships no ICU, and .NET aborts at startup with
# "Couldn't find a valid ICU package installed" without it. The number in the
# package name tracks Debian's ICU soversion, so moving off trixie will require
# changing it — the dotnet assertion in the smoke test is what catches that.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libicu76; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh; \
    bash /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --install-dir "${DOTNET_ROOT}"; \
    rm /tmp/dotnet-install.sh; \
    chmod -R a+rX "${DOTNET_ROOT}"; \
    dotnet --version; dotnet fsi --version

# --- Julia ---
ARG JULIA_VERSION
ARG JULIA_URL
ARG JULIA_SHA256
ENV PATH=/opt/julia/bin:$PATH
RUN set -eux; \
    test -n "${JULIA_URL}"; \
    test -n "${JULIA_SHA256}"; \
    curl -fsSL -o /tmp/julia.tar.gz "${JULIA_URL}"; \
    echo "${JULIA_SHA256}  /tmp/julia.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/julia; \
    tar -xzf /tmp/julia.tar.gz -C /opt/julia --strip-components=1; \
    rm /tmp/julia.tar.gz; \
    julia --version

# --- R ---
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends r-base; \
    rm -rf /var/lib/apt/lists/*; \
    R --version

# --- config defaults and entrypoint (last: changes most often) ---
# COPY preserves source file modes; the build context is synced from a
# Windows host over tar/ssh and can land with owner-only (600/700) perms,
# which the non-root user below can't read. Normalize to world-readable.
COPY config/ /etc/opencode/
RUN chmod -R a+rX /etc/opencode
COPY scripts/seed-config.sh scripts/entrypoint.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/seed-config.sh /usr/local/bin/entrypoint.sh

USER opencode
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["opencode"]

# --- provenance labels (last: cheap layer, changes every build) ---
ARG OPENCODE_VERSION
ARG GO_VERSION
ARG JULIA_VERSION
ARG NODE_MAJOR
ARG DOTNET_CHANNEL
LABEL org.opencontainers.image.title="cranopener" \
      org.opencontainers.image.description="opencode with a polyglot toolchain" \
      org.opencontainers.image.source="https://github.com/SupremeCommanderHedgehog/cranopener" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/debian:trixie-slim" \
      org.opencontainers.image.version="${OPENCODE_VERSION}" \
      dev.cranopener.opencode.version="${OPENCODE_VERSION}" \
      dev.cranopener.go.version="${GO_VERSION}" \
      dev.cranopener.julia.version="${JULIA_VERSION}" \
      dev.cranopener.node.major="${NODE_MAJOR}" \
      dev.cranopener.dotnet.channel="${DOTNET_CHANNEL}"
