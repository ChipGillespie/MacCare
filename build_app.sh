#!/bin/zsh
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$PROJECT_DIR/build/MacCare.app"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

swiftc -O -target arm64-apple-macosx14.0 \
  "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/SystemScanner.swift" \
  "$PROJECT_DIR/Sources/AppUninstaller.swift" \
  "$PROJECT_DIR/Sources/FileHunter.swift" \
  "$PROJECT_DIR/Sources/AppUpdater.swift" \
  "$PROJECT_DIR/Sources/MalwareScanner.swift" \
  "$PROJECT_DIR/Sources/ContentView.swift" \
  "$PROJECT_DIR/Sources/MacCareApp.swift" \
  -o "$APP_BUNDLE/Contents/MacOS/MacCare"

swift "$PROJECT_DIR/make_icon.swift" "$PROJECT_DIR"
iconutil -c icns "$PROJECT_DIR/build/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP_BUNDLE"
echo "Built $APP_BUNDLE successfully."
echo "To install to /Applications, run:"
echo "  ditto \"$APP_BUNDLE\" /Applications/MacCare.app"
