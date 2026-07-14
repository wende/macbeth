#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../daemon"

echo "Building macbethd + macbeth-glow (universal binaries)..."
swift build -c release --arch arm64 --arch x86_64

PRODUCTS=".build/apple/Products/Release"
if [ ! -d "$PRODUCTS" ]; then
    # Fallback for single-arch builds
    PRODUCTS=".build/release"
fi

mkdir -p ../client/bin

for name in macbethd macbeth-glow; do
    BINARY="$PRODUCTS/$name"
    if [ ! -f "$BINARY" ]; then
        echo "Error: expected binary not found: $BINARY" >&2
        exit 1
    fi
    DEST="../client/bin/$name"
    cp "$BINARY" "$DEST"
    chmod +x "$DEST"
    echo "Built: $DEST ($(du -h "$DEST" | cut -f1))"
done
