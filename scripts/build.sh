#!/bin/bash
# Builds the brain and the app and assembles build/Steward.app.
#   scripts/build.sh [--debug] [--skip-brain]
# Signing: uses the "Steward Local" identity when the login keychain has it (create it once with
# scripts/make-signing-identity.sh), so macOS keeps Accessibility and Screen Recording grants across
# rebuilds. Without it the bundle is ad-hoc signed and those grants reset on every build.
# Override the identity name with STEWARD_SIGN_IDENTITY.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=release
SKIP_BRAIN=
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --skip-brain) SKIP_BRAIN=1 ;;
    *) echo "usage: scripts/build.sh [--debug] [--skip-brain]" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }

# The source tree as it is being built (tracked changes and untracked files, through a throwaway index so the
# branch and staging area are untouched). Recorded as refs/steward/built once the build succeeds: the app's own
# agent may only rebuild a diff from that record after its safety gate has looked at it.
BUILT_TREE=""
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  INDEX="$(mktemp -u "${TMPDIR:-/tmp}/steward-index.XXXXXX")"
  BUILT_TREE="$(GIT_INDEX_FILE="$INDEX" git -C "$ROOT" add -A >/dev/null 2>&1 && GIT_INDEX_FILE="$INDEX" git -C "$ROOT" write-tree 2>/dev/null || true)"
  rm -f "$INDEX" "$INDEX.lock"
  if [ -n "${STEWARD_GATED_TREE:-}" ]; then
    # Started by the app: build only the tree its gate looked at.
    if [ "$STEWARD_GATED_TREE" != "$BUILT_TREE" ]; then
      echo "the source changed after the rebuild was checked; not building" >&2
      exit 1
    fi
  elif git -C "$ROOT" rev-parse -q --verify refs/steward/built >/dev/null 2>&1 && [ -n "$BUILT_TREE" ]; then
    # Started by hand: say what this build takes in, since nothing else will have shown it to you.
    CHANGED="$(git -C "$ROOT" diff --stat --no-color refs/steward/built "$BUILT_TREE" | tail -n 40)"
    if [ -n "$CHANGED" ]; then
      step "source changed since the last build (yours and the agent's):"
      printf '%s\n' "$CHANGED"
    fi
  fi
fi

if [ -f "$ROOT/brain/package.json" ] && [ -z "$SKIP_BRAIN" ]; then
  step "brain"
  command -v pnpm >/dev/null || { echo "pnpm not found on PATH (needed to build brain/)" >&2; exit 1; }
  (cd "$ROOT/brain" && { pnpm install --frozen-lockfile || pnpm install; } && pnpm build)
fi

step "app ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT/app" --product Steward
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT/app" --show-bin-path)/Steward"

step "bundle"
BUILD="$ROOT/build"
APP="$BUILD/Steward.app"
PREV="$BUILD/Steward.prev.app"
STAGE="$BUILD/.stage/Steward.app"
rm -rf "$BUILD/.stage"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Steward"

VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || date +%Y.%m.%d)"
PLIST="$STAGE/Contents/Info.plist"
cp "$ROOT/app/Resources/Info.plist" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M%S)" "$PLIST"
# The app finds brain/dist/main.js through this; STEWARD_REPO overrides it at run time.
plutil -replace StewardRepoPath -string "$ROOT" "$PLIST"

ICNS="$BUILD/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICNS" ]; then
  step "icon"
  ICONSET="$BUILD/.stage/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift "$ROOT/scripts/make-icon.swift" "$BUILD/.stage/icon-1024.png"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$BUILD/.stage/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$BUILD/.stage/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$STAGE/Contents/Resources/AppIcon.icns"

step "sign"
IDENTITY="${STEWARD_SIGN_IDENTITY:-Steward Local}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\"" \
   && codesign --force --sign "$IDENTITY" --identifier app.steward.mac "$STAGE"; then
  echo "signed with \"$IDENTITY\""
else
  codesign --force --sign - --identifier app.steward.mac "$STAGE"
  echo "ad-hoc signed (privacy grants reset on each rebuild; run scripts/make-signing-identity.sh once to avoid that)"
fi
codesign --verify --strict "$STAGE"

# Keep the last bundle: the app falls back to it if a self-rebuilt one fails to launch.
if [ -d "$APP" ]; then
  rm -rf "$PREV"
  mv "$APP" "$PREV"
fi
mv "$STAGE" "$APP"
rm -rf "$BUILD/.stage"

if [ -n "$BUILT_TREE" ]; then
  COMMIT="$(GIT_AUTHOR_NAME=Steward GIT_AUTHOR_EMAIL=steward@localhost GIT_COMMITTER_NAME=Steward GIT_COMMITTER_EMAIL=steward@localhost \
    git -C "$ROOT" commit-tree "$BUILT_TREE" -m "steward build")"
  git -C "$ROOT" update-ref refs/steward/built "$COMMIT"
fi

step "done: $APP ($VERSION)"
