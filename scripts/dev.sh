#!/bin/bash
# Development loop: the brain in watch mode plus the app straight from `swift run` (no bundle, so
# no permission prompts, notifications or relaunch). Ctrl-C stops both.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
trap 'kill 0' EXIT

if [ -f "$ROOT/brain/package.json" ]; then
  (cd "$ROOT/brain" && { [ -d node_modules ] || pnpm install; } && pnpm dev) &
fi

# The app adopts the brain started above instead of spawning its own.
STEWARD_NO_BRAIN=1 swift run --package-path "$ROOT/app" Steward
