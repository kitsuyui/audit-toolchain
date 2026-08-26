#!/usr/bin/env bash

set -eu

image="${1:-audit-toolchain:ci}"

check_basic_trace() {
  local stderr_file
  local status

  stderr_file="$(mktemp)"
  trap 'rm -f "$stderr_file"' RETURN

  set +e
  docker run --rm "$image" sh -c 'exit 7' 2>"$stderr_file"
  status="$?"
  set -e

  test "$status" = "7"
  grep -Eq '^audit-toolchain: level=info event=tool_start tool=sh arg_count=2 at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$stderr_file"
  grep -Eq '^audit-toolchain: level=error event=tool_finish tool=sh exit_code=7 at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$stderr_file"
  ! grep -q 'exit 7' "$stderr_file"
}

check_quoted_tool_trace() {
  local stderr_file
  local status
  local tool

  stderr_file="$(mktemp)"
  trap 'rm -f "$stderr_file"' RETURN
  tool="$(printf 'bad tool\nlevel=info event=forged')"

  set +e
  docker run --rm "$image" "$tool" 2>"$stderr_file"
  status="$?"
  set -e

  test "$status" = "127"
  grep -Fq 'event=tool_start tool="bad tool\nlevel=info event=forged" arg_count=0' "$stderr_file"
  grep -Fq 'event=tool_not_found tool="bad tool\nlevel=info event=forged" exit_code=127' "$stderr_file"
  grep -Fq 'event=tool_finish tool="bad tool\nlevel=info event=forged" exit_code=127' "$stderr_file"
  if grep -Eq '^audit-toolchain: level=info event=forged' "$stderr_file"; then
    return 1
  fi
  if grep -Fq '/usr/local/bin/audit-toolchain' "$stderr_file"; then
    return 1
  fi
  if grep -Fq 'command not found' "$stderr_file"; then
    return 1
  fi
}

# Golden copy of print_help()'s output in entrypoint/audit-toolchain. Update
# this together with print_help() in the same commit — that pairing is the
# contract this test enforces.
expected_help_golden() {
  cat <<'USAGE'
audit-toolchain — language-agnostic, audit-time tools packaged as a single Docker image.

Usage:
  docker run --rm [--network=none] -v "$PWD:/workspace" audit-toolchain:<tag> [SUBCOMMAND | TOOL [ARG...]]

Toolkit subcommands:
  --help, -h, help             Print this message.
  --version, -V, version       Print toolkit metadata and image-build info.
  --list-tools, list-tools     List installed audit tools as TSV
                               (name<TAB>version<TAB>category), one per line.

Anything else is exec'd as a command in the image. With no arguments and a
TTY (-it), an interactive bash is started. With no arguments and no TTY, an
error is returned so automation does not silently treat a no-op as success.

Examples:
  docker run --rm audit-toolchain:dev --version
  docker run --rm audit-toolchain:dev --list-tools
  docker run --rm --network=none -v "$PWD:/workspace" audit-toolchain:dev ruff check .

See README.md (https://github.com/kitsuyui/audit-toolchain) for network
policy and the full tool catalogue.
USAGE
}

check_help_contract() {
  local alias
  local actual_file
  local status

  actual_file="$(mktemp)"
  trap 'rm -f "$actual_file"' RETURN

  for alias in --help -h help; do
    set +e
    docker run --rm "$image" "$alias" >"$actual_file"
    status="$?"
    set -e

    test "$status" = "0"
    if ! diff -u <(expected_help_golden) "$actual_file" >&2; then
      printf 'audit-toolchain: help output for %s does not match the golden contract\n' "$alias" >&2
      return 1
    fi
  done
}

check_version_contract() {
  local alias
  local actual
  local status
  local line_count

  for alias in --version -V version; do
    set +e
    actual="$(docker run --rm "$image" "$alias")"
    status="$?"
    set -e

    test "$status" = "0"
    line_count="$(printf '%s\n' "$actual" | wc -l | tr -d ' ')"
    test "$line_count" = "3"
    printf '%s\n' "$actual" | sed -n '1p' | grep -Eq '^audit-toolchain .+$'
    printf '%s\n' "$actual" | sed -n '2p' | grep -Fq 'source: https://github.com/kitsuyui/audit-toolchain'
    printf '%s\n' "$actual" | sed -n '3p' | grep -Eq '^base: debian:.+-slim$'
  done
}

check_no_args_non_tty_contract() {
  local actual_file
  local expected_file
  local status

  actual_file="$(mktemp)"
  expected_file="$(mktemp)"
  trap 'rm -f "$actual_file" "$expected_file"' RETURN

  {
    expected_help_golden
    printf 'audit-toolchain: level=error event=no_tool_specified reason=no_tty\n'
  } >"$expected_file"

  set +e
  docker run --rm -i "$image" </dev/null >/dev/null 2>"$actual_file"
  status="$?"
  set -e

  test "$status" = "1"
  if ! diff -u "$expected_file" "$actual_file" >&2; then
    printf 'audit-toolchain: no-argument/non-TTY output does not match the golden contract\n' >&2
    return 1
  fi
}

check_signal_forwarding() {
  local container_name="audit-toolchain-signal-test"
  local stderr_file
  local runner_pid
  local status

  stderr_file="$(mktemp)"
  trap 'rm -f "$stderr_file"; docker rm -f "$container_name" >/dev/null 2>&1 || true' RETURN

  docker rm -f "$container_name" >/dev/null 2>&1 || true

  set +e
  docker run --name "$container_name" --rm "$image" \
    bash -c 'trap "exit 42" TERM; while true; do read -r -t 1 _ || true; done' \
    2>"$stderr_file" &
  runner_pid="$!"

  for _ in $(seq 1 50); do
    docker inspect "$container_name" >/dev/null 2>&1 && break
    sleep 0.1
  done

  docker stop --time 2 "$container_name" >/dev/null
  wait "$runner_pid"
  status="$?"
  set -e

  test "$status" = "42"
  grep -Eq '^audit-toolchain: level=info event=tool_start tool=bash arg_count=2 at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$stderr_file"
  grep -Eq '^audit-toolchain: level=error event=tool_finish tool=bash exit_code=42 at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$stderr_file"
}

check_basic_trace
check_quoted_tool_trace
check_signal_forwarding
check_help_contract
check_version_contract
check_no_args_non_tty_contract
