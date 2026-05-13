# syntax=docker/dockerfile:1.7
#
# audit-toolchain — language-agnostic audit-time tools as a single image.
# See README.md for usage and tool selection policy.

# --- base layer versions ---
ARG DEBIAN_VERSION=bookworm
ARG DEBIAN_DIGEST=sha256:67b30a61dc87758f0caf819646104f29ecbda97d920aaf5edc834128ac8493d3
ARG UV_VERSION=0.5.11
ARG UV_DIGEST=sha256:0ac957607303916420297a4c9c213bb33fbd3c888f9cd7f4f7273596ebf42b85
ARG BUN_VERSION=1.1.42
ARG BUN_DIGEST=sha256:9a45ebd9a1e5403177064592e1564791443b1a459356c905d1112e32758dd454
ARG RUST_VERSION=1.90.0
ARG GO_VERSION=1.23.4

# --- audit tool versions ---
#
# Tool versions are pinned so the same Dockerfile build produces the
# same tool set regardless of build date. The image's deterministic-
# audit guarantee depends on this: a finding produced on one date must
# be reproducible from the same source on a later date, which requires
# the audit tool layer to be reproducible too.
#
# Bump policy: each ARG is independently bumpable. Renovate / dependabot
# can target individual ARGs once configured (out of scope for the pin
# itself).

# Rust audit tools (cargo install).
ARG CARGO_AUDIT_VERSION=0.22.1
ARG CARGO_DENY_VERSION=0.19.6
ARG LYCHEE_VERSION=0.24.2
# Python audit tools (uv tool install).
ARG RUFF_VERSION=0.15.12
ARG MYPY_VERSION=1.14.1
ARG VULTURE_VERSION=2.16
ARG PIP_AUDIT_VERSION=2.10.0
# JS / TS audit tools (bun add -g).
ARG TYPESCRIPT_VERSION=5.9.3
ARG BIOME_VERSION=2.4.15
ARG KNIP_VERSION=6.12.2
ARG MADGE_VERSION=8.0.0
ARG MARKDOWNLINT_CLI2_VERSION=0.22.1
# Go audit tools (go install). Tag format follows each project's
# convention: staticcheck uses YYYY.N (no v prefix), govulncheck uses
# vX.Y.Z (with v prefix).
ARG STATICCHECK_VERSION=2026.1
ARG GOVULNCHECK_VERSION=v1.1.4

# Pull uv binary from the official image.
FROM ghcr.io/astral-sh/uv:${UV_VERSION}@${UV_DIGEST} AS uv-source

# Pull bun binary from the official image.
FROM oven/bun:${BUN_VERSION}@${BUN_DIGEST} AS bun-source

FROM debian:${DEBIAN_VERSION}-slim@${DEBIAN_DIGEST} AS base

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
# Debian ships the fd CLI as `fdfind` to avoid a package-name
# collision. Expose the upstream `fd` command name used by the README
# and common audit command examples.
#
# APT_PACKAGES_DATE pins the cache epoch for this layer. Bump it (or set
# --build-arg APT_PACKAGES_DATE=$(date +%Y-%m-%d)) whenever apt packages
# need refreshing. The GHA layer cache key includes this ARG value, so
# changing it forces a clean apt-get install and picks up Debian updates.
ARG APT_PACKAGES_DATE=2026-05-13
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

# Rust toolchain via rustup (sha256-verified binary; avoids curl|sh).
ARG RUST_VERSION
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) rustup_target=x86_64-unknown-linux-gnu ;; \
        arm64) rustup_target=aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    base="https://static.rust-lang.org/rustup/dist/${rustup_target}"; \
    curl -fsSL "${base}/rustup-init"        -o /tmp/rustup-init; \
    curl -fsSL "${base}/rustup-init.sha256" -o /tmp/rustup-init.sha256; \
    cd /tmp && sha256sum -c rustup-init.sha256; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --default-toolchain "${RUST_VERSION}" --profile minimal --no-modify-path; \
    rm /tmp/rustup-init /tmp/rustup-init.sha256; \
    rustup component add rustfmt clippy

# Go toolchain (sha256-verified tarball).
ARG GO_VERSION
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) arch=amd64 ;; \
        arm64) arch=arm64 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    filename="go${GO_VERSION}.linux-${arch}.tar.gz"; \
    curl -fsSL "https://go.dev/dl/${filename}" -o /tmp/go.tar.gz; \
    curl -fsSL "https://go.dev/dl/?mode=json&include=all" -o /tmp/go-versions.json; \
    expected=$(jq -r --arg v "go${GO_VERSION}" --arg f "${filename}" \
        '.[] | select(.version == $v) | .files[] | select(.filename == $f) | .sha256' \
        /tmp/go-versions.json); \
    rm /tmp/go-versions.json; \
    [ -n "$expected" ] || { echo "go SHA256 not found in go.dev API for go${GO_VERSION}/${filename}" >&2; exit 1; }; \
    actual=$(sha256sum /tmp/go.tar.gz | awk '{print $1}'); \
    [ "$actual" = "$expected" ] || { echo "go tarball SHA256 mismatch: expected=${expected} actual=${actual}" >&2; exit 1; }; \
    tar -C /usr/local -xzf /tmp/go.tar.gz; \
    rm /tmp/go.tar.gz

# --- audit tools ---
#
# Layer order is chosen for build cache stability:
#   - The heaviest layer that compiles from source (cargo install) sits
#     directly after the Rust toolchain layer, so the lighter and more
#     volatile tool installs below cannot invalidate it on edits.
#   - Cargo's per-source registry cache is dropped after install since
#     the resulting binaries do not need it at runtime.

# Rust audit tools (cargo install --locked, compiled from source).
ARG CARGO_AUDIT_VERSION
ARG CARGO_DENY_VERSION
ARG LYCHEE_VERSION
RUN cargo install --locked \
        cargo-audit@${CARGO_AUDIT_VERSION} \
        cargo-deny@${CARGO_DENY_VERSION} \
        lychee@${LYCHEE_VERSION} \
    && rm -rf /root/.cargo/registry /root/.cargo/git

# Python tools (uv tool install creates per-tool venvs in /root/.local).
ARG RUFF_VERSION
ARG MYPY_VERSION
ARG VULTURE_VERSION
ARG PIP_AUDIT_VERSION
RUN uv tool install ruff==${RUFF_VERSION} \
    && uv tool install mypy==${MYPY_VERSION} \
    && uv tool install vulture==${VULTURE_VERSION} \
    && uv tool install pip-audit==${PIP_AUDIT_VERSION}

# JS / TS tools (bun global install).
ARG TYPESCRIPT_VERSION
ARG BIOME_VERSION
ARG KNIP_VERSION
ARG MADGE_VERSION
ARG MARKDOWNLINT_CLI2_VERSION
RUN bun add -g \
        typescript@${TYPESCRIPT_VERSION} \
        @biomejs/biome@${BIOME_VERSION} \
        knip@${KNIP_VERSION} \
        madge@${MADGE_VERSION} \
        markdownlint-cli2@${MARKDOWNLINT_CLI2_VERSION}

# Go audit tools.
ARG STATICCHECK_VERSION
ARG GOVULNCHECK_VERSION
RUN go install honnef.co/go/tools/cmd/staticcheck@${STATICCHECK_VERSION} \
    && go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION} \
    && rm -rf /root/.cache/go-build

# --- toolkit-level CLI entry ---
#
# A small shim provides image-level `--help`, `--version`, and
# `--list-tools` so the image can identify itself without operators
# having to read README + Dockerfile out of band. The shim execs any
# other argv through to the underlying tool, so existing usage like
# `docker run audit-toolchain:<tag> ruff check .` continues to work.
# `--entrypoint ""` remains available as an escape hatch.

# Toolkit version — overridden at build time (e.g. by CI from the git
# revision). Kept as a build ARG instead of a fixed value so a single
# Dockerfile build can be tagged from any commit without source edits.
ARG AUDIT_TOOLCHAIN_VERSION=dev
ARG AUDIT_TOOLCHAIN_SOURCE=https://github.com/kitsuyui/audit-toolchain
ENV AUDIT_TOOLCHAIN_VERSION="${AUDIT_TOOLCHAIN_VERSION}"

# Re-declare every tool version ARG so they expand in this layer.
ARG CARGO_AUDIT_VERSION
ARG CARGO_DENY_VERSION
ARG LYCHEE_VERSION
ARG RUFF_VERSION
ARG MYPY_VERSION
ARG VULTURE_VERSION
ARG PIP_AUDIT_VERSION
ARG TYPESCRIPT_VERSION
ARG BIOME_VERSION
ARG KNIP_VERSION
ARG MADGE_VERSION
ARG MARKDOWNLINT_CLI2_VERSION
ARG STATICCHECK_VERSION
ARG GOVULNCHECK_VERSION
ARG UV_VERSION
ARG BUN_VERSION
ARG RUST_VERSION
ARG GO_VERSION
ARG DEBIAN_VERSION

COPY entrypoint/audit-toolchain /usr/local/bin/audit-toolchain
RUN chmod +x /usr/local/bin/audit-toolchain \
    && mkdir -p /usr/local/share/audit-toolchain \
    && { \
        printf 'audit-toolchain %s\n' "${AUDIT_TOOLCHAIN_VERSION}"; \
        printf 'source: %s\n' "${AUDIT_TOOLCHAIN_SOURCE}"; \
        printf 'base: debian:%s-slim\n' "${DEBIAN_VERSION}"; \
    } > /usr/local/share/audit-toolchain/metadata.txt \
    && { \
        printf 'cargo-audit\t%s\trust\n' "${CARGO_AUDIT_VERSION}"; \
        printf 'cargo-deny\t%s\trust\n' "${CARGO_DENY_VERSION}"; \
        printf 'lychee\t%s\trust\n' "${LYCHEE_VERSION}"; \
        printf 'ruff\t%s\tpython\n' "${RUFF_VERSION}"; \
        printf 'mypy\t%s\tpython\n' "${MYPY_VERSION}"; \
        printf 'vulture\t%s\tpython\n' "${VULTURE_VERSION}"; \
        printf 'pip-audit\t%s\tpython\n' "${PIP_AUDIT_VERSION}"; \
        printf 'typescript\t%s\tjs\n' "${TYPESCRIPT_VERSION}"; \
        printf 'biome\t%s\tjs\n' "${BIOME_VERSION}"; \
        printf 'knip\t%s\tjs\n' "${KNIP_VERSION}"; \
        printf 'madge\t%s\tjs\n' "${MADGE_VERSION}"; \
        printf 'markdownlint-cli2\t%s\tmarkdown\n' "${MARKDOWNLINT_CLI2_VERSION}"; \
        printf 'staticcheck\t%s\tgo\n' "${STATICCHECK_VERSION}"; \
        printf 'govulncheck\t%s\tgo\n' "${GOVULNCHECK_VERSION}"; \
        printf 'uv\t%s\tlanguage-runtime\n' "${UV_VERSION}"; \
        printf 'bun\t%s\tlanguage-runtime\n' "${BUN_VERSION}"; \
        printf 'rustup-toolchain\t%s\tlanguage-runtime\n' "${RUST_VERSION}"; \
        printf 'go\t%s\tlanguage-runtime\n' "${GO_VERSION}"; \
    } > /usr/local/share/audit-toolchain/tools.tsv

# OCI image labels so `docker inspect` carries toolkit metadata even
# when callers cannot or do not invoke the image's own CLI.
LABEL org.opencontainers.image.title="audit-toolchain" \
      org.opencontainers.image.description="Language-agnostic, audit-time tools packaged as a single Docker image." \
      org.opencontainers.image.source="${AUDIT_TOOLCHAIN_SOURCE}" \
      org.opencontainers.image.version="${AUDIT_TOOLCHAIN_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0"

WORKDIR /workspace

# Route every invocation through the toolkit shim. With no arguments
# (CMD []), the shim drops into an interactive bash; with arguments, it
# either handles them as toolkit subcommands or execs them so the
# existing `docker run audit-toolchain:<tag> <tool> <args>` usage keeps
# working.
ENTRYPOINT ["audit-toolchain"]
CMD []
