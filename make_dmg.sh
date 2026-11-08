#!/bin/zsh
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$PROJECT_DIR/build/MacCare.app"
STAGING_DIR="$PROJECT_DIR/build/dmg_staging"
DMG_PATH="$PROJECT_DIR/build/MacCare-v2.2.dmg"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "Building MacCare.app first..."
  /bin/zsh "$PROJECT_DIR/build_app.sh"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy MacCare.app and create the /Applications drag-and-drop symlink
ditto "$APP_BUNDLE" "$STAGING_DIR/MacCare.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "MacCare 2.2" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"
echo "Created DMG installer at: $DMG_PATH"
