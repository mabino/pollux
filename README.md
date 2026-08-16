# Pollux

Pollux is a native macOS GUI application for media stream extraction and playback. It reimplements and builds upon the concepts of [Castor](https://github.com/stupside/castor) as a modern macOS SwiftUI app with direct `AVPlayer` video integration and an embedded CLI tool.

## Features

- **Automated Stream Extraction**: Uses headless Chromium via Chrome DevTools Protocol (CDP) to navigate web pages and capture live HLS media streams.
- **Local HLS Proxying**: Runs an embedded lightweight HTTP proxy server on `127.0.0.1` to rewrite playlists and strip obfuscated segment headers (such as image signatures).
- **Native macOS Player**: Plays extracted video streams using native macOS `AVPlayer` / `AVPlayerView`.
- **Stealth & Bot-Mitigation Options**: Configurable anti-automation levels to bypass script challenges and quiet CDP fingerprints.
- **Command-Line Interface**: Includes `pollux-cli` for terminal-based stream extraction and URL resolution.
- **Recent Streams History**: Store and manage recently extracted streams with deduplication and quick playback options.

## Purpose and Disclaimer

Pollux is a general-purpose stream extraction and playback utility. It is not affiliated with or tied to any specific website or content provider. Pollux does not host, index, store, or bundle any video content, catalogs, or media sources.

- **Functionality**: Pollux processes only the page URLs and media sources supplied directly by the user.
- **DRM Policy**: Pollux does not decrypt, bypass, or circumvent Digital Rights Management (DRM). It cannot play DRM-protected content.
- **User Responsibility**: Users are solely responsible for ensuring that their use of Pollux complies with applicable terms of service and local laws.
- **Copyright Notice**: Pollux must not be used to infringe upon copyrights or unauthorized content distribution.

## Requirements

- macOS 14.0 or later
- Xcode 15+ / Swift 5.10+
- Google Chrome or Chromium installed

## Building & Running

Generate the Xcode project and build Pollux using the provided scripts:

```bash
# Generate Xcode project (requires xcodegen)
./scripts/generate.zsh

# Build Pollux app
./scripts/build.zsh

# Package macOS DMG installer
./scripts/package-dmg.zsh

# Run Pollux with a target page URL
./scripts/run.zsh "https://example.com/watch/stream"
```

## Testing

Run unit tests via Xcode or command line:

```bash
xcodebuild test -scheme Pollux -destination 'platform=macOS'
```

## Releasing (signed & notarized)

Cutting a distributable build requires an Apple **Developer ID Application** certificate and
notarization credentials. Configure a reusable notarytool keychain profile once (App Store Connect
API key recommended):

```bash
xcrun notarytool store-credentials "Pollux" \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> \
  --issuer <ISSUER-UUID>
```

Then export the release identity and run the two scripts:

```bash
export POLLUX_TEAM_ID="<TEAMID>"
export POLLUX_DEVELOPER_ID_APP="Developer ID Application: <Name> (<TEAMID>)"
export POLLUX_NOTARY_KEYCHAIN_PROFILE="Pollux"   # or POLLUX_APPLE_ID + POLLUX_APPLE_APP_PASSWORD

# Archive (Release, hardened runtime, --timestamp), notarize the app, and staple it
./scripts/notarize.zsh

# Package the stapled app into a DMG, then notarize and staple the DMG
./scripts/package-dmg.zsh v0.2.0
```

Both scripts fall back to `POLLUX_APPLE_ID` + `POLLUX_APPLE_APP_PASSWORD` if no keychain profile is
set. `package-dmg.zsh` still produces a signed DMG when no notary credentials are present (it just
skips the notarization step).

## License

This project is licensed under the MIT License - see [LICENSE.md](LICENSE.md) for details.
