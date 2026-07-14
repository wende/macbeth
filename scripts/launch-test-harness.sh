#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_PATH="$($ROOT_DIR/scripts/build-test-harness.sh)"

open -g -n "$BUNDLE_PATH"
