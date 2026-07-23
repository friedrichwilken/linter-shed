#!/usr/bin/env bash
# install.sh — bootstrap linter-shed into ~/.linter-shed
set -euo pipefail

SHED_DIR="${LINTER_SHED_DIR:-$HOME/.linter-shed}"
SHED_BIN="$SHED_DIR/bin"
REPO_URL="https://github.com/I549741/linter-shed.git"

echo "[linter-shed] installing to $SHED_DIR"
mkdir -p "$SHED_BIN"

# Clone or update registry
if [[ -d "$SHED_DIR/registry/.git" ]]; then
    echo "[linter-shed] updating registry..."
    git -C "$SHED_DIR/registry" pull --ff-only --quiet
else
    echo "[linter-shed] cloning registry..."
    git clone --depth=1 "$REPO_URL" "$SHED_DIR/registry"
fi

# Install shed.sh itself
cp "$SHED_DIR/registry/shed.sh" "$SHED_BIN/shed"
chmod +x "$SHED_BIN/shed"

date +%s > "$SHED_DIR/last-checked"

echo "[linter-shed] installed. Add to PATH: export PATH=\"$SHED_BIN:\$PATH\""
echo "[linter-shed] run 'shed list' to see available tools"
