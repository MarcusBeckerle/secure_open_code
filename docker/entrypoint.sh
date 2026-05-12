#!/usr/bin/env bash
set -euo pipefail

CONFIG_DEST="/root/.config/opencode/opencode.jsonc"

if [ -f /workspace/opencode.jsonc ]; then
  mkdir -p "$(dirname "$CONFIG_DEST")"
  cp -f /workspace/opencode.jsonc "$CONFIG_DEST"
  echo "Copied /workspace/opencode.jsonc to $CONFIG_DEST" >&2
elif [ -f /workspace/docker/opencode.jsonc ]; then
  mkdir -p "$(dirname "$CONFIG_DEST")"
  cp -f /workspace/docker/opencode.jsonc "$CONFIG_DEST"
  echo "Copied /workspace/docker/opencode.jsonc to $CONFIG_DEST" >&2
else
  echo "No runtime opencode.jsonc found; using image defaults" >&2
fi

exec "$@"
