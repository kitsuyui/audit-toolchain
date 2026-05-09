# syntax=docker/dockerfile:1.7
#
# audit-toolchain — language-agnostic audit-time tools as a single image.
# See README.md for usage and tool selection policy.

ARG DEBIAN_VERSION=bookworm
ARG UV_VERSION=0.5.11
ARG BUN_VERSION=1.1.42
ARG RUST_VERSION=1.90.0
ARG GO_VERSION=1.23.4

# Pull uv binary from the official image.
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-source

# Pull bun binary from the official image.
FROM oven/bun:${BUN_VERSION} AS bun-source

FROM debian:${DEBIAN_VERSION}-slim AS base

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/root/.local/bin:/root/.bun/bin:/root/.cargo/bin:/usr/local/go/bin:/root/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    # Opt out of telemetry and update checks. Defense in depth on top of
    # the recommended `--network=none` for local-only audits.
    DO_NOT_TRACK=1 \
    NO_UPDATE_NOTIFIER=true \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    CI=true

# Universal packages from apt.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        fd-find \
        git \
        jq \
        less \
        libssl-dev \
        pkg-config \
        ripgrep \
        shellcheck \
        shfmt \
        tree \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd

# uv (Python) — copy single binary from official image.
COPY --from=uv-source /uv /usr/local/bin/uv

# bun (JS/TS) — copy single binary from official image.
# Symlink as `node` so npm CLIs whose shebang is `#!/usr/bin/env node`
# resolve to bun. Bun is a near-drop-in node replacement for tooling use.
COPY --from=bun-source /usr/local/bin/bun /usr/local/bin/bun
RUN ln -s /usr/local/bin/bun /usr/local/bin/node

# Rust toolchain via rustup.
ARG RUST_VERSION
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain "${RUST_VERSION}" --profile minimal --no-modify-path \
    && rustup component add rustfmt clippy

# Go toolchain.
ARG GO_VERSION
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) arch=amd64 ;; \
        arm64) arch=arm64 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" \
        | tar -C /usr/local -xz

# --- audit tools ---

# Python tools (uv tool install creates per-tool venvs in /root/.local).
RUN uv tool install ruff \
    && uv tool install mypy \
    && uv tool install vulture \
    && uv tool install pip-audit

# JS / TS tools (bun global install).
RUN bun add -g \
        typescript \
        @biomejs/biome \
        knip \
        madge \
        markdownlint-cli2

# Rust audit tools (cargo install --locked, compiled from source).
RUN cargo install --locked cargo-audit cargo-deny lychee

# Go audit tools.
RUN go install honnef.co/go/tools/cmd/staticcheck@latest \
    && go install golang.org/x/vuln/cmd/govulncheck@latest \
    && rm -rf /root/.cache/go-build

WORKDIR /workspace

# Default to an interactive shell so operators can run any tool.
CMD ["bash"]
