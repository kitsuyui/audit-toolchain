# Changelog

This project does not yet have a versioned release process.
There are no Git tags or GitHub Releases at this time.

## How to reference a specific version

Since there are no versioned releases, pin by commit SHA:

```sh
git clone https://github.com/kitsuyui/audit-toolchain.git
cd audit-toolchain
git checkout <commit-sha>
docker build \
  --build-arg AUDIT_TOOLCHAIN_VERSION="<commit-sha>" \
  -t audit-toolchain:<commit-sha> .
```

The `AUDIT_TOOLCHAIN_VERSION` build argument is embedded in the image via OCI labels
and in `/usr/local/share/audit-toolchain/metadata.txt`, so `docker run --rm audit-toolchain:<tag> --version`
identifies the exact source revision.

See [Determinism](./README.md#determinism) in README for the reproducibility guarantee.

## Historical summary

The project was established to provide a single Docker image with language-agnostic
audit tools (ruff, mypy, vulture, biome, knip, madge, shellcheck, staticcheck,
cargo audit, govulncheck, lychee, etc.). See the
[commit history](https://github.com/kitsuyui/audit-toolchain/commits/main) for a
complete record of all changes.
