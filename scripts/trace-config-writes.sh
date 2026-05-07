#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-$HOME/.koe/config.yaml}"
TARGET_DIR="$(dirname "$TARGET")"
TARGET_BASE="$(basename "$TARGET")"

if [[ ! -e "$TARGET" ]]; then
  printf 'Target does not exist yet: %s\n' "$TARGET" >&2
  exit 1
fi

cat <<EOF
Tracing writes related to:
  $TARGET

This uses fs_usage and prints processes touching the config path.
Press Ctrl-C to stop.

Tip: run it as:
  ! sudo "$(pwd)/scripts/trace-config-writes.sh"
EOF

sudo fs_usage -w -f filesystem 2>/dev/null | \
  grep --line-buffered -E "$TARGET_BASE|$TARGET_DIR" | \
  grep --line-buffered -E "open|create|rename|write|unlink|truncate|setattr|ftruncate|exchangedata"
