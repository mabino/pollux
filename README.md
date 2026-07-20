# Pollux

Pollux is a macOS native GUI application for stream extraction and playback. It reimplements the functionality of Castor as a modern macOS SwiftUI app with direct AVPlayer video integration.

## Features

- **Automated Stream Extraction**: Uses headless Chromium via Chrome DevTools Protocol (CDP) to navigate stream pages, bypass Turnstile / bot protection, and capture live HLS streams.
- **Local HLS Proxying**: Runs an embedded lightweight HTTP proxy server on `127.0.0.1` to rewrite live playlists and strip obfuscated segment headers (such as image signatures).
- **Native macOS Player**: Plays extracted video streams using native macOS `AVPlayer` / `AVPlayerView`.
- **Live Stream Refresh**: Automatically fetches updated HLS media playlists live through Chrome's authenticated browser session.

## Requirements

- macOS 14.0 or later
- Xcode 15+ / Swift 5.9+
- Google Chrome or Chromium installed

## Building & Running

Generate the Xcode project and build/run Pollux using the provided scripts:

```bash
# Generate Xcode project (requires xcodegen)
./scripts/generate.zsh

# Build Pollux app
./scripts/build.zsh

# Run Pollux with a stream URL
./scripts/run.zsh "https://example.com/watch/example"
```

## Testing

Run unit tests via Xcode or command line:

```bash
xcodebuild test -project Pollux.xcodeproj -scheme Pollux -destination 'platform=macOS'
```
