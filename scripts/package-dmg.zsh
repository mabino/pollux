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
rm -rf "$STAGING_DIR"

# Sign the DMG with the Developer ID Application certificate (the app inside is already signed and,
# after notarize.zsh, notarized + stapled).
if [[ -n "${POLLUX_DEVELOPER_ID_APP:-}" ]]; then
  codesign -s "$POLLUX_DEVELOPER_ID_APP" --timestamp "$DMG_PATH" >/dev/null 2>&1 || true
fi

# Notarize and staple the DMG itself so the download validates offline (no first-run network check).
# Uses the same auth as notarize.zsh: a stored notarytool keychain profile, or Apple ID + app password.
# Skipped automatically if no notary credentials are configured, so the script still produces a DMG.
if [[ -n "${POLLUX_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  print -- "Notarizing DMG via keychain profile '$POLLUX_NOTARY_KEYCHAIN_PROFILE'..."
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$POLLUX_NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH" >/dev/null
elif [[ -n "${POLLUX_APPLE_ID:-}" && -n "${POLLUX_APPLE_APP_PASSWORD:-}" && -n "${POLLUX_TEAM_ID:-}" ]]; then
  print -- "Notarizing DMG via Apple ID $POLLUX_APPLE_ID..."
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$POLLUX_APPLE_ID" \
    --password "$POLLUX_APPLE_APP_PASSWORD" \
    --team-id "$POLLUX_TEAM_ID" \
    --wait
  xcrun stapler staple "$DMG_PATH" >/dev/null
else
  print -u2 -- "Note: no notary credentials set (POLLUX_NOTARY_KEYCHAIN_PROFILE or POLLUX_APPLE_ID/…); DMG signed but not notarized."
fi

print -- "Created DMG at $DMG_PATH"
