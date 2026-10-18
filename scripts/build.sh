#!/bin/bash
# Build Wakelock.app (arm64, ad-hoc signed) into ./build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --arch arm64 --product Wakelock
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Wakelock"

APP="$ROOT/build/Wakelock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wakelock"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"
