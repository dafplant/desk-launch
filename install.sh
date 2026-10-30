#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="$HOME/.config/desk-launch"
CONFIG="$CONFIG_DIR/config.json"
APP_NAME="Desk Launch"
APP_DIR="${APP_DIR:-$HOME/Applications/$APP_NAME.app}"

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
echo "Building the editor app…"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# Dock icon. Prebuilt from Resources/AppIcon.svg (see Resources/README.md) so
# installing does not need an SVG renderer on the machine.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.dafplant.desk-launch</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Same binary, own bundle: launching the app with no arguments opens the editor,
# and it gets its own Accessibility grant instead of borrowing the terminal's.
cp .build/release/desk-launch "$APP_DIR/Contents/MacOS/$APP_NAME"

# Sign with a designated requirement pinned to the bundle identifier rather than
# the default cdhash. TCC stores the requirement when a grant is made, so a
# cdhash-bound grant stops matching after every rebuild (the toggle stays on in
# System Settings but the app is told it has no permission). The identifier-only
# requirement survives rebuilds. It is weaker than a Developer ID, which is fine
# for a locally built personal tool.
codesign --force --sign - \
  --identifier com.dafplant.desk-launch \
  -r='designated => identifier "com.dafplant.desk-launch"' \
  "$APP_DIR" >/dev/null 2>&1 \
  || echo "Note: could not sign the app bundle; the editor still runs."

echo
echo "Installed: $BIN_DIR/desk-launch"
echo "Installed: $APP_DIR"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH. Use the full path, or add it:" ;;
esac

echo
echo "Open the editor from Spotlight (\"$APP_NAME\"), or:"
echo "  open \"$APP_DIR\""
echo "or from the terminal:"
echo "  $BIN_DIR/desk-launch gui"
echo
echo "Add an alias (zsh), e.g.:"
echo "  echo \"alias desk='$BIN_DIR/desk-launch'\" >> ~/.zshrc"
echo
echo "Then:"
echo "  desk --doctor"
echo "  desk --dry-run"
echo "  desk"
