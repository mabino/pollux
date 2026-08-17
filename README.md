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

Pollux is a general-purpose stream extraction and playback utility rather than a service tied to any specific platform, website, or content provider.

- **It hosts nothing.** No bundled video, catalog, or sources. Pollux only processes the page URLs and media you supply and are authorized to use.
- **It does not touch DRM.** Pollux does not decrypt or circumvent DRM, and cannot play DRM-protected content.
- **Using it lawfully is your responsibility.** Whether a site's terms of use and your local law allow what you do with Pollux is on you. Do not use it to infringe copyright.

Pollux is provided as-is for lawful, personal, and educational use.

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
