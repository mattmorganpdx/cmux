#!/usr/bin/env bash
# Install cmux and cmux-cli to /usr/local/bin
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/zig-out/bin"

if [[ ! -f "$BIN_DIR/cmux" || ! -f "$BIN_DIR/cmux-cli" ]]; then
    echo "Binaries not found. Building first..."
    cd "$SCRIPT_DIR" && zig build
fi

sudo cp "$BIN_DIR/cmux" "$BIN_DIR/cmux-cli" /usr/local/bin/
echo "Installed cmux and cmux-cli to /usr/local/bin/"
