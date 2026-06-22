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
  grep -Fq 'event=tool_finish tool="bad tool\nlevel=info event=forged" exit_code=127' "$stderr_file"
  ! grep -Eq '^audit-toolchain: level=info event=forged' "$stderr_file"
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
