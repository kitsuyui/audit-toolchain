# Security Policy

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report vulnerabilities privately via
[GitHub's private vulnerability reporting](https://github.com/kitsuyui/audit-toolchain/security/advisories/new).

Include:

- A description of the vulnerability and its potential impact.
- Steps to reproduce or a proof of concept.
- The version (or commit SHA) affected, if known.

## Scope

This repository ships audit tools as a Docker image. Areas relevant for
vulnerability tracking include:

- **Dockerfile**: build-time injection or supply-chain risks introduced
  through base images or package installs.
- **Bundled tools**: vulnerabilities in the linters, scanners, or
  language toolchains included in the image.
- **Entrypoint logic** (`entrypoint/`): shell scripts that delegate to
  bundled tools; path-traversal or argument-injection issues.

The image is designed to run with `--network=none` against a mounted
source tree. Any bypass of that isolation boundary is in scope.

## Response

Reports are acknowledged within 7 days. A fix timeline is provided within
30 days for confirmed vulnerabilities.
