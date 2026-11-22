#!/bin/bash
# Builds if anything changed since the last bundle, then opens the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Steward.app"
BIN="$APP/Contents/MacOS/Steward"

stale() {
  [ -x "$BIN" ] || return 0
  local sources=("$ROOT/app/Sources" "$ROOT/app/Package.swift" "$ROOT/app/Resources" "$ROOT/scripts")
  [ -d "$ROOT/brain/src" ] && sources+=("$ROOT/brain/src" "$ROOT/brain/package.json")
  [ -n "$(find "${sources[@]}" -type f -newer "$BIN" -print -quit)" ]
}

if stale; then "$ROOT/scripts/build.sh"; fi
open "$APP"
