# audit-toolchain

Language-agnostic, audit-time tools packaged as a single Docker image.

## Purpose

Tools used only at code-audit time (linters that catch dead code, module
graph extractors, vulnerability scanners) often have no place in an
application's runtime or test dependencies. Installing them into each
project's dev-deps inflates lockfiles, attracts renovate / dependabot
noise, and slows CI installs.

This repository ships those tools as a single Docker image, so an
operator (human or agent) can run them against any source tree without
modifying the project under audit.

## Usage

```sh
# Build
docker build -t audit-toolchain:dev .

# Run a local-only tool against the current directory.
# Use --network=none to enforce that the audit reads only the mount.
docker run --rm --network=none -v "$PWD:/workspace" audit-toolchain:dev ruff check .
docker run --rm --network=none -v "$PWD:/workspace" audit-toolchain:dev madge --circular src

# Run a network-required tool (vulnerability scanners, link checkers).
docker run --rm -v "$PWD:/workspace" audit-toolchain:dev pip-audit
docker run --rm -v "$PWD:/workspace" audit-toolchain:dev cargo audit

# Drop into a shell with all tools available.
docker run --rm -it --network=none -v "$PWD:/workspace" audit-toolchain:dev
```

The container's working directory is `/workspace`. Mount the project
under audit there.

## Network access

Audit results should depend only on the mounted source tree, not on
remote state. The image classifies tools by whether their job requires
network access.

### Local-only (run with `--network=none`)

These tools read only from the mounted filesystem and were verified
to complete without network:

`ruff`, `mypy`, `vulture`, `tsc`, `biome`, `knip`, `madge`,
`markdownlint-cli2`, `shellcheck`, `shfmt`, `staticcheck`,
`ripgrep`, `fd`, `tree`, `jq`, `git` (read-only).

Always run these with `--network=none` so a regression in a future
version cannot silently introduce a remote call.

### Network-required (network is the tool's purpose)

These tools query remote advisory databases or external URLs as their
core function. Running them with `--network=none` makes them useless.

| Tool | Why network is needed |
| --- | --- |
| `pip-audit` | queries PyPI advisory DB (pypi.org) |
| `cargo audit` | fetches RustSec advisory DB (github.com/RustSec) |
| `cargo deny check advisories` | same advisory DB |
| `govulncheck` | queries Go vulnerability DB (vuln.go.dev) |
| `lychee` (without `--offline`) | checks external URLs in markdown |

Run these with the default network. `lychee --offline` works inside
`--network=none` and only validates internal links.

### Telemetry / update-check opt-out

The image sets these environment variables to disable telemetry and
update notifiers where the tool respects the convention:

- `DO_NOT_TRACK=1` — widely adopted opt-out env var convention
- `NO_UPDATE_NOTIFIER=true` — disables `update-notifier` (used by many
  npm tools)
- `NPM_CONFIG_UPDATE_NOTIFIER=false` — npm's own update check
- `NPM_CONFIG_FUND=false` — silences "found N vulnerabilities" funding
  prompts
- `CI=true` — many CLIs disable progress bars and telemetry under CI

This is **defense in depth**: the primary guarantee is `--network=none`.
The env vars cover any local on-disk state changes (configstores,
update tracking files) the tools might still attempt.

## Included tools

### Python (installed via `uv tool`)

- `ruff` — linter / formatter (Astral)
- `mypy` — static type checker
- `vulture` — dead code detector
- `pip-audit` — vulnerability check (PyPA)

### JavaScript / TypeScript (installed via `bun add -g`)

- `typescript` (`tsc`) — type checker
- `@biomejs/biome` — linter / formatter
- `knip` — unused exports / files / dependencies
- `madge` — module graph / cycle detector

### Markdown

- `markdownlint-cli2` (via `bun add -g`)
- `lychee` — link checker (via `cargo install`)

### Shell

- `shellcheck` — static analysis
- `shfmt` — formatter

### Rust

- `rustfmt`, `clippy`, `cargo tree` — toolchain built-ins
- `cargo-audit` — vulnerability check (RustSec)
- `cargo-deny` — license / advisory / source check

### Go

- `gofmt`, `go vet` — toolchain built-ins
- `staticcheck` — static analysis (honnef.co/go/tools)
- `govulncheck` — vulnerability check (golang.org/x/vuln)

### Universal

- `ripgrep` (`rg`), `fd`, `tree`, `jq`, `git`, `curl`

## Tool selection policy

Tools are added only when their maintenance status is clear.
Deprecated, stale, or unclear-maintenance tools are deferred.

Currently deferred (revisit when maintenance status is clearer or when
a concrete audit run requires them):

- `ts-prune` — deprecated; `knip` covers the scope
- `pydeps`, `pyan`, `import-linter` — Python module graph; need
  evaluation
- `dependency-cruiser` — TS; rule-based, may add later
- `markdown-link-check` — `lychee` covers the scope
- `cargo-modules`, `cargo-deps` — Rust; smaller community
- `golangci-lint` — Go; meta-wrapper, may add later

## License

Apache-2.0 (see `LICENSE`).
