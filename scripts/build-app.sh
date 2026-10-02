#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/build/Maimemo Companion.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$PROJECT_DIR"
swift build -c release --product MaimemoCompanion

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$PROJECT_DIR/.build/release/MaimemoCompanion" "$MACOS_DIR/MaimemoCompanion"
cp "$PROJECT_DIR/Resources/AppInfo.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/MaimemoCompanion"

/usr/bin/codesign --force --sign - "$APP_DIR"
echo "$APP_DIR"
