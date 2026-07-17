#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_DIR="$ROOT_DIR/test/test-harness"
BUNDLE_PATH="$HARNESS_DIR/.build/MacbethTestApp.app"

swift build --package-path "$HARNESS_DIR" --configuration debug >/dev/null
BIN_DIR="$(swift build --package-path "$HARNESS_DIR" --configuration debug --show-bin-path)"

rm -rf "$BUNDLE_PATH"
mkdir -p "$BUNDLE_PATH/Contents/MacOS"
cp "$HARNESS_DIR/Resources/Info.plist" "$BUNDLE_PATH/Contents/Info.plist"
install -m 755 "$BIN_DIR/MacbethTestApp" "$BUNDLE_PATH/Contents/MacOS/MacbethTestApp"

echo "$BUNDLE_PATH"
