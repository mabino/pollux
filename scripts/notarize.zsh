#!/bin/zsh

source "${0:A:h}/common.zsh"

: "${POLLUX_TEAM_ID:?Set POLLUX_TEAM_ID to your Apple Developer team ID.}"
: "${POLLUX_DEVELOPER_ID_APP:?Set POLLUX_DEVELOPER_ID_APP to your Developer ID Application certificate name.}"

ARCHIVE_PATH=${ARCHIVE_PATH:-$PROJECT_ROOT/.build/Pollux.xcarchive}
ARTIFACTS_DIR=${ARTIFACTS_DIR:-$PROJECT_ROOT/.build/notarize}
ZIP_PATH="$ARTIFACTS_DIR/Pollux.zip"

if [[ -z "${POLLUX_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  : "${POLLUX_APPLE_ID:?Set POLLUX_APPLE_ID or use POLLUX_NOTARY_KEYCHAIN_PROFILE.}"
  : "${POLLUX_APPLE_APP_PASSWORD:?Set POLLUX_APPLE_APP_PASSWORD or use POLLUX_NOTARY_KEYCHAIN_PROFILE.}"
fi

generate_project
xcodebuild_args

rm -rf "$ARCHIVE_PATH" "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"

xcodebuild "${reply[@]}" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$POLLUX_TEAM_ID" \
  CODE_SIGN_IDENTITY="$POLLUX_DEVELOPER_ID_APP" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive -quiet

APP_PATH="$ARCHIVE_PATH/Products/Applications/Pollux.app"

# Re-sign Sparkle's nested helper code with the Developer ID cert, hardened runtime, and a secure
# timestamp. `xcodebuild archive` signs the app and the framework's top level but leaves these nested
# bundles with Sparkle's own signature, which notarization rejects. Sign inside-out, then re-seal the
# framework and the app.
SPARKLE_VERSION_DIR="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SPARKLE_VERSION_DIR" ]]; then
  for nested in \
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION_DIR/Updater.app" \
    "$SPARKLE_VERSION_DIR/Autoupdate"; do
    [[ -e "$nested" ]] && codesign --force --options runtime --timestamp \
      --sign "$POLLUX_DEVELOPER_ID_APP" "$nested"
  done
  codesign --force --options runtime --timestamp \
    --sign "$POLLUX_DEVELOPER_ID_APP" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp \
    --sign "$POLLUX_DEVELOPER_ID_APP" "$APP_PATH"
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ -n "${POLLUX_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$POLLUX_NOTARY_KEYCHAIN_PROFILE" --wait
else
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$POLLUX_APPLE_ID" \
    --password "$POLLUX_APPLE_APP_PASSWORD" \
    --team-id "$POLLUX_TEAM_ID" \
    --wait
fi

xcrun stapler staple "$APP_PATH" >/dev/null

print -- "Notarized app available at $APP_PATH"
