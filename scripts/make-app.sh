#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Buffer"
OUTPUT_DIR="dist"
BUNDLE_ID="com.samhh.buffer"
VERSION="0.1.0"
INSTALL=false
INSTALL_DIR="/Applications"
ICON_PATH="assets/icon/Buffer.icns"

usage() {
  cat <<USAGE
Usage: scripts/make-app.sh [options]

Builds a signed macOS .app bundle at dist/Buffer.app.

Options:
  --output <dir>       Output directory for the app bundle (default: dist)
  --bundle-id <id>     CFBundleIdentifier value (default: com.samhh.buffer)
  --version <version>  App version (default: 0.1.0)
  --icon <path>        Path to .icns app icon (default: assets/icon/Buffer.icns)
  --install            Copy the built app to /Applications after bundling
  --install-dir <dir>  Install destination (default: /Applications)
  -h, --help           Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --icon)
      ICON_PATH="$2"
      shift 2
      ;;
    --install)
      INSTALL=true
      shift
      ;;
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

echo "Building $APP_NAME (release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Missing executable at: $BIN_PATH" >&2
  exit 1
fi

APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ -f "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$RESOURCES_DIR/$APP_NAME.icns"
fi

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>$APP_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  echo "Applying ad-hoc code signature..."
  codesign --force --deep --sign - "$APP_DIR"
  codesign --verify --deep --strict "$APP_DIR"
fi

echo "Built app bundle: $APP_DIR"

if [[ "$INSTALL" == true ]]; then
  echo "Installing to $INSTALL_DIR..."
  cp -R "$APP_DIR" "$INSTALL_DIR/"
  echo "Installed: $INSTALL_DIR/$APP_NAME.app"
fi
