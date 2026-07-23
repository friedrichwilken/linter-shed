#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/friedrichwilken/linter-shed.git"
LINTER_SHED_DIR="${LINTER_SHED_DIR:-$HOME/.linter-shed}"
REGISTRY_DIR="$LINTER_SHED_DIR/registry"
BIN_DIR="$LINTER_SHED_DIR/bin"
VERSIONS_DIR="$LINTER_SHED_DIR/versions"
LOGS_DIR="$LINTER_SHED_DIR/logs"

echo "==> Installing linter-shed to $LINTER_SHED_DIR"

# Create necessary directories
mkdir -p "$BIN_DIR" "$VERSIONS_DIR" "$LOGS_DIR"

# Clone or update registry
if [ -d "$REGISTRY_DIR/.git" ]; then
  echo "==> Updating existing registry..."
  git -C "$REGISTRY_DIR" fetch origin
  git -C "$REGISTRY_DIR" reset --hard origin/main
else
  echo "==> Cloning linter-shed registry..."
  git clone "$REPO_URL" "$REGISTRY_DIR"
fi

# Copy shed.sh to bin/shed
if [ ! -f "$REGISTRY_DIR/shed.sh" ]; then
  echo "ERROR: shed.sh not found in registry" >&2
  exit 1
fi

cp "$REGISTRY_DIR/shed.sh" "$BIN_DIR/shed"
chmod +x "$BIN_DIR/shed"

# Write last-checked timestamp as Unix epoch (integer) so shed.sh TTL math works
date +%s > "$LINTER_SHED_DIR/last-checked"

echo ""
echo "==> linter-shed installed successfully."
echo ""
echo "Next steps:"
echo ""
echo "  1. Add shed to your PATH. Add this line to your ~/.zshrc or ~/.bashrc:"
echo ""
echo "       export PATH=\"$BIN_DIR:\$PATH\""
echo ""
echo "  2. Reload your shell:"
echo ""
echo "       source ~/.zshrc"
echo ""
echo "  3. Add the linter-shed plugin to Claude Code:"
echo ""
echo "       /plugin marketplace add https://github.com/friedrichwilken/linter-shed"
echo ""
echo "  Run 'shed --help' to get started."
