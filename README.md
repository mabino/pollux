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

## License

This project is licensed under the MIT License - see [LICENSE.md](LICENSE.md) for details.
