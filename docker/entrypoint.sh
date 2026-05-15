#!/usr/bin/env bash
set -euo pipefail

CONFIG_DEST="/root/.config/opencode/opencode.jsonc"

if [ -f /workspace/opencode.jsonc ]; then
  mkdir -p "$(dirname "$CONFIG_DEST")"
  cp -f /workspace/opencode.jsonc "$CONFIG_DEST"
  echo "Using workspace opencode.jsonc: /workspace/opencode.jsonc -> $CONFIG_DEST" >&2
elif [ -f /workspace/docker/opencode.jsonc ]; then
  mkdir -p "$(dirname "$CONFIG_DEST")"
  cp -f /workspace/docker/opencode.jsonc "$CONFIG_DEST"
  echo "Using project default opencode.jsonc: /workspace/docker/opencode.jsonc -> $CONFIG_DEST" >&2
else
  # Image may already contain a default opencode.jsonc copied at build time.
  if [ -f "$CONFIG_DEST" ]; then
    echo "No workspace config found; using image-bundled opencode.jsonc at $CONFIG_DEST" >&2
  else
    echo "No opencode.jsonc found in workspace or image; using OpenCode defaults" >&2
  fi
fi

exec "$@"
