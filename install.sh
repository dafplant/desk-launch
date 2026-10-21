#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="$HOME/.config/desk-launch"
CONFIG="$CONFIG_DIR/config.json"

echo "Building desk-launch (release)…"
swift build -c release

mkdir -p "$BIN_DIR"
ln -sf "$PWD/.build/release/desk-launch" "$BIN_DIR/desk-launch"

if [ -f "$CONFIG" ]; then
  echo "Keeping existing config: $CONFIG"
else
  mkdir -p "$CONFIG_DIR"
  cp config.example.json "$CONFIG"
  echo "Created config: $CONFIG"
fi

echo
echo "Installed: $BIN_DIR/desk-launch"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH. Use the full path, or add it:" ;;
esac

echo
echo "Add an alias (zsh), e.g.:"
echo "  echo \"alias desk='$BIN_DIR/desk-launch'\" >> ~/.zshrc"
echo
echo "Then:"
echo "  desk --doctor"
echo "  desk --dry-run"
echo "  desk"
