# Contributing

## Development setup

Install [lefthook](https://github.com/evilmartians/lefthook) once after cloning:

```sh
lefthook install
```

This registers fast local checks (shellcheck on shell scripts) before commit and push.

## Adding a new tool

Tools are added to the Docker image when:

1. **Maintenance status is clear** — the tool is actively maintained with a public issue tracker.
2. **Scope is audit-time only** — the tool belongs in an audit image, not in application dev-deps.
3. **Category fits** — static analysis, dead code detection, vulnerability scanning, module graph extraction, or a universal utility.

If a tool overlaps with an existing one (e.g. another Python linter), explain why both are needed.

### Version pinning

Every tool must be pinned by version in the `Dockerfile`. Use the corresponding install ARG:

| Ecosystem | Install method | ARG pattern |
| --------- | -------------- | ----------- |
| Python | `uv tool install <tool>==<version>` | `ARG <TOOL>_VERSION=<version>` |
| JS/TS | `bun add -g <tool>@<version>` | `ARG <TOOL>_VERSION=<version>` |
| Rust | `cargo install <tool> --version <version>` | `ARG <TOOL>_VERSION=<version>` |
| Go | `go install <module>@v<version>` | `ARG <TOOL>_VERSION=v<version>` |

No `@latest`, no unpinned package names.

### Updating the tool count baseline

When a tool is added or removed, update the count in `scripts/check-image-metrics.sh` in the same PR. The CI gate enforces the exact count.

### Network classification

Add the new tool to the `Local-only` or `Network-required` section in `README.md` based on whether it reads only from the filesystem or requires external network access.

## Running checks locally

```sh
# Build the image
docker build \
  --build-arg AUDIT_TOOLCHAIN_VERSION="$(git rev-parse --short HEAD)" \
  -t audit-toolchain:dev .

# Run CI metric gate locally
docker build \
  --build-arg AUDIT_TOOLCHAIN_VERSION="$(git rev-parse HEAD)" \
  -t audit-toolchain:ci .
scripts/check-image-metrics.sh audit-toolchain:ci
```

The full `docker build` is intentionally left to CI (it compiles Rust packages from source and pulls multi-GB base images). Fast local checks (shellcheck) run via lefthook hooks.

## Commit style

Use [Conventional Commits](https://www.conventionalcommits.org/) with English messages:

```text
fix: <message>
feat: <message>
ci: <message>
docs: <message>
```

## Pull requests

- One topic per PR when practical.
- Include a brief description of the change and why it is needed.
- CI runs `docker build` and the image metric gate on every PR; ensure both pass.

## License

By contributing you agree that your contributions will be licensed under [Apache-2.0](LICENSE).
