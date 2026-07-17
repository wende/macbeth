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

SIGNING_IDENTITY="${MACBETH_CODESIGN_IDENTITY:--}"

for name in macbethd macbeth-glow; do
    BINARY="$PRODUCTS/$name"
    if [ ! -f "$BINARY" ]; then
        echo "Error: expected binary not found: $BINARY" >&2
        exit 1
    fi
    DEST="../client/bin/$name"
    # Build and sign beside the destination, then replace it atomically. This
    # prevents a concurrently starting MCP client from observing the brief
    # unsigned/partially-signed state between cp and codesign.
    TEMP_DEST="$(mktemp "$DEST.tmp.XXXXXX")"
    trap 'rm -f "$TEMP_DEST"' EXIT
    cp "$BINARY" "$TEMP_DEST"
    chmod +x "$TEMP_DEST"
    # SwiftPM combines the two linker-signed thin executables with lipo. That
    # invalidates their per-slice signatures, and current macOS releases kill
    # the resulting universal executable before main() with SIGKILL. Sign the
    # final fat binary, then fail the build if it is not launch-valid.
    IDENTIFIER="com.macbeth.$name"
    if [ "$SIGNING_IDENTITY" = "-" ]; then
        codesign \
            --force \
            --sign - \
            --identifier "$IDENTIFIER" \
            --timestamp=none \
            "$TEMP_DEST"
    else
        codesign \
            --force \
            --sign "$SIGNING_IDENTITY" \
            --identifier "$IDENTIFIER" \
            --options runtime \
            --timestamp \
            "$TEMP_DEST"
    fi
    codesign --verify --all-architectures --strict "$TEMP_DEST"
    mv -f "$TEMP_DEST" "$DEST"
    trap - EXIT
    codesign --verify --all-architectures --strict "$DEST"
    echo "Built: $DEST ($(du -h "$DEST" | cut -f1))"
done
