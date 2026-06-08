#!/usr/bin/env sh

set -eu

image="${1:-audit-toolchain:ci}"
max_image_size_bytes="${AUDIT_TOOLCHAIN_MAX_IMAGE_SIZE_BYTES:-2500000000}"
expected_tool_count="${AUDIT_TOOLCHAIN_EXPECTED_TOOL_COUNT:-26}"

is_unsigned_integer() {
	case "$1" in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

image_size_bytes="$(docker image inspect "$image" --format '{{.Size}}')"
if ! is_unsigned_integer "$image_size_bytes"; then
	printf 'error: image size is not an integer: %s\n' "$image_size_bytes" >&2
	exit 1
fi

if ! is_unsigned_integer "$max_image_size_bytes"; then
	printf 'error: max image size is not an integer: %s\n' "$max_image_size_bytes" >&2
	exit 1
fi

if [ "$image_size_bytes" -gt "$max_image_size_bytes" ]; then
	printf 'error: image size %s exceeds max %s bytes\n' \
		"$image_size_bytes" "$max_image_size_bytes" >&2
	exit 1
fi

tool_count="$(docker run --rm "$image" --list-tools | awk 'NF { count++ } END { print count + 0 }')"
if ! is_unsigned_integer "$tool_count"; then
	printf 'error: tool count is not an integer: %s\n' "$tool_count" >&2
	exit 1
fi

if ! is_unsigned_integer "$expected_tool_count"; then
	printf 'error: expected tool count is not an integer: %s\n' "$expected_tool_count" >&2
	exit 1
fi

if [ "$tool_count" -ne "$expected_tool_count" ]; then
	printf 'error: tool count %s differs from expected %s\n' \
		"$tool_count" "$expected_tool_count" >&2
	exit 1
fi

printf 'image_size_bytes=%s max_image_size_bytes=%s\n' \
	"$image_size_bytes" "$max_image_size_bytes"
printf 'tool_count=%s expected_tool_count=%s\n' \
	"$tool_count" "$expected_tool_count"
