#!/usr/bin/env bash
# Build cmux and cmux-cli
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" && zig build "$@"
echo "Built cmux and cmux-cli in $SCRIPT_DIR/zig-out/bin/"
