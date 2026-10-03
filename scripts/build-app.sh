#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/build/Maimemo Companion.app"
SIGNING_IDENTITY="${MAIMEMO_SIGNING_IDENTITY:-Maimemo Companion Local Development}"

export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.clang-module-cache"
export SWIFTPM_CACHE_PATH="$PROJECT_DIR/.swiftpm-cache"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]]; then
  # The local CLT compiler currently rejects the newer default 26.5 SDK.
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi

mkdir -p "$PROJECT_DIR/build"
STAGE_ROOT="$(mktemp -d "$PROJECT_DIR/build/.maimemo-stage.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGED_APP="$STAGE_ROOT/Maimemo Companion.app"
CONTENTS_DIR="$STAGED_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$PROJECT_DIR"
swift build --disable-sandbox -c release --product MaimemoCompanion

mkdir -p "$MACOS_DIR"
cp "$PROJECT_DIR/.build/release/MaimemoCompanion" "$MACOS_DIR/MaimemoCompanion"
cp "$PROJECT_DIR/Resources/AppInfo.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/MaimemoCompanion"

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

PREVIOUS_APP="$STAGE_ROOT/previous.app"
if [[ -d "$APP_DIR" ]]; then
  mv "$APP_DIR" "$PREVIOUS_APP"
fi
if ! mv "$STAGED_APP" "$APP_DIR"; then
  if [[ -d "$PREVIOUS_APP" ]]; then
    mv "$PREVIOUS_APP" "$APP_DIR"
  fi
  exit 1
fi
echo "$APP_DIR"
