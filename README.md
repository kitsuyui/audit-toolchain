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
docker build \
  --build-arg AUDIT_TOOLCHAIN_VERSION="$(git rev-parse --short HEAD)" \
  -t audit-toolchain:dev .

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

## Toolkit CLI

The image entrypoint is a thin shim (`/usr/local/bin/audit-toolchain`)
that provides image-level discoverability without changing how
individual tools are invoked.

```sh
# Print the toolkit's own help, version, and tool inventory.
docker run --rm audit-toolchain:dev --help
docker run --rm audit-toolchain:dev --version
docker run --rm audit-toolchain:dev --list-tools
```

`--list-tools` writes one tool per line as TSV
(`name<TAB>version<TAB>category`) so automation can verify the image
inventory without parsing this README or the `Dockerfile`. The same
data plus the build-time toolkit version is in
`/usr/local/share/audit-toolchain/{tools.tsv,metadata.txt}` for callers
that prefer to read the file directly. If `metadata.txt` is unavailable,
`--version` falls back to the runtime `AUDIT_TOOLCHAIN_VERSION`
environment variable promoted from the build argument.
CI builds pass the current commit SHA as `AUDIT_TOOLCHAIN_VERSION` so
`--version` and the OCI `org.opencontainers.image.version` label identify
the exact source revision used for the image build.

Anything that is not a toolkit subcommand is delegated to the requested
tool, so existing command lines keep working:

```sh
docker run --rm --network=none -v "$PWD:/workspace" audit-toolchain:dev ruff check .
docker run --rm -it audit-toolchain:dev bash
```

The shim preserves the delegated tool's exit status and forwards
termination signals, but it is not a byte-for-byte stderr passthrough.
It writes one trace line before the tool starts and one after it exits:

```text
audit-toolchain: level=info event=tool_start tool=<name> arg_count=<n> at=<UTC timestamp>
audit-toolchain: level=info event=tool_finish tool=<name> exit_code=0 at=<UTC timestamp>
audit-toolchain: level=error event=tool_finish tool=<name> exit_code=<non-zero> at=<UTC timestamp>
audit-toolchain: level=warn event=tool_killed tool=<name> exit_code=<signal> at=<UTC timestamp>
```

`event=tool_killed` is emitted when the tool exits due to a termination
signal (e.g. SIGINT or SIGTERM); all other non-zero exits use
`event=tool_finish`.

Automation that parses stderr should treat those `audit-toolchain:`
lines as toolkit trace metadata. Other stdout and stderr content comes
from the delegated tool.

To bypass the shim entirely (e.g. to run a binary literally named
`--help`), pass `--entrypoint ""` to `docker run`.

The image also publishes [OCI image labels][oci-annotations]
(`org.opencontainers.image.title`, `description`, `source`, `version`,
`licenses`) so `docker inspect audit-toolchain:<tag>` returns toolkit
metadata even without invoking the CLI.

[oci-annotations]: https://github.com/opencontainers/image-spec/blob/main/annotations.md

## CI metric baselines

The `Test docker build` workflow runs
[`scripts/check-image-metrics.sh`](scripts/check-image-metrics.sh)
against `audit-toolchain:ci` after the image is built. The check fails
when `docker image inspect ... --format '{{.Size}}'` reports an image
size above `2500000000` bytes or when `--list-tools` reports anything
other than `26` installed tools. The image-size baseline follows the CI
runner's Docker measurement rather than Docker Desktop's compressed
display size.

Run the same gate locally after building the CI image:

```sh
docker build \
  --build-arg AUDIT_TOOLCHAIN_VERSION="$(git rev-parse HEAD)" \
  -t audit-toolchain:ci .
scripts/check-image-metrics.sh audit-toolchain:ci
```

When a legitimate tool addition, removal, or layer change alters either
metric, update the script baseline in the same change so the growth is
intentional and visible in review.

## Determinism

Audit results should be reproducible: the same source code audited from
the same `Dockerfile` should produce the same result regardless of when
the image was built.

To support that, every audit tool installed in the image is
version-pinned at the `ARG` layer in [`Dockerfile`](Dockerfile). This
applies to the base toolchains (Debian image tag, uv, bun, rustup, Go)
and to the audit tools themselves: Rust `cargo install`, Python
`uv tool install`, JS/TS `bun add -g`, Go `go install`. No `@latest`,
no unpinned package name.

Bumping a single tool is a one-line change to the corresponding ARG.
Image consumers do not need to pin by digest as long as they build from
the same Dockerfile revision: the source itself is the version manifest.

The apt packages installed at the universal layer (`bash`, `git`, `jq`,
`shellcheck`, `shfmt`, etc.) are pinned to a specific
[snapshot.debian.org](https://snapshot.debian.org/) archive date
controlled by the `APT_PACKAGES_DATE` build argument. The Dockerfile
rewrites `/etc/apt/sources.list` to point to that snapshot before
running `apt-get install`, so rebuilding from the same `Dockerfile`
revision on any later date installs the same package versions. To pick
up newer Debian packages, bump `APT_PACKAGES_DATE` to the desired date
(format: `YYYY-MM-DD`); the GHA layer cache key includes this value so
a bump forces a fresh `apt-get install`.

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

## Development

[lefthook](https://github.com/evilmartians/lefthook) is used to run fast local
checks before commit and push. Install it once after cloning:

```sh
lefthook install
```

### Hooks

| Hook | Check | Command |
| --- | --- | --- |
| `pre-commit`, `pre-push` | `shellcheck` | `shellcheck entrypoint/audit-toolchain scripts/check-image-metrics.sh scripts/check-entrypoint-trace.sh` |

`shellcheck` performs static analysis on the shell scripts in this repository
(`entrypoint/audit-toolchain`, `scripts/check-image-metrics.sh`, and
`scripts/check-entrypoint-trace.sh`). It runs
in under a second and catches common shell scripting errors before they reach
CI.

The full `docker build` is intentionally left to CI: it requires the Docker
daemon, pulls multi-GB base images, and compiles Rust packages from source —
not suitable for a local pre-commit hook. The hooks add fast static checks that
surface issues earlier, complementing rather than replacing CI.

## License

Apache-2.0 (see `LICENSE`).
