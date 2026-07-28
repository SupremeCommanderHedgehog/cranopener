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
