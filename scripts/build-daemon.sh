#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../daemon"

echo "Building macbethd (universal binary)..."
swift build -c release --arch arm64 --arch x86_64

BINARY=".build/apple/Products/Release/macbethd"
if [ ! -f "$BINARY" ]; then
    # Fallback for single-arch builds
    BINARY=".build/release/macbethd"
fi

DEST="../client/bin/macbethd"
cp "$BINARY" "$DEST"
chmod +x "$DEST"

echo "Built: $DEST ($(du -h "$DEST" | cut -f1))"
