#!/bin/zsh

source "${0:A:h}/common.zsh"

VERSION=${1:-v0.1.0}
APP_PATH=${2:-"$PROJECT_ROOT/.build/Pollux.xcarchive/Products/Applications/Pollux.app"}

if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$DERIVED_DATA/Build/Products/Release/Pollux.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  print -u2 -- "Pollux.app not found at $APP_PATH. Please build/archive first."
  exit 1
fi

DMG_NAME="Pollux-${VERSION}.dmg"
DMG_PATH="$PROJECT_ROOT/.build/$DMG_NAME"
STAGING_DIR="$PROJECT_ROOT/.build/dmg_staging"

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

cp -R "$APP_PATH" "$STAGING_DIR/Pollux.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname "Pollux" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

if [[ -n "${POLLUX_DEVELOPER_ID_APP:-}" ]]; then
  codesign -s "$POLLUX_DEVELOPER_ID_APP" --timestamp "$DMG_PATH" >/dev/null 2>&1 || true
fi

rm -rf "$STAGING_DIR"

print -- "Created DMG at $DMG_PATH"
