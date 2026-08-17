#!/bin/zsh

# Generates and publishes the Sparkle appcast for a notarized Pollux DMG.
#
# Prerequisites:
#   - A notarized, stapled DMG (produced by ./scripts/notarize.zsh && ./scripts/package-dmg.zsh <ver>).
#   - The Sparkle EdDSA private key in the login Keychain (created once via Sparkle's `generate_keys`;
#     the matching public key is baked into the app's Info.plist as SUPublicEDKey).
#   - GitHub Pages serving `docs/` on the default branch, so the feed is reachable at the SUFeedURL
#     configured in project.yml (https://mabino.github.io/pollux/appcast.xml).
#
# Usage: ./scripts/release-appcast.zsh <version> [dmg-path]
#   e.g. ./scripts/release-appcast.zsh v0.2.0 .build/Pollux-v0.2.0.dmg

source "${0:A:h}/common.zsh"

VERSION=${1:?Usage: release-appcast.zsh <version> [dmg-path]}
DMG_PATH=${2:-"$PROJECT_ROOT/.build/Pollux-${VERSION}.dmg"}

[[ -f "$DMG_PATH" ]] || { print -u2 -- "DMG not found at $DMG_PATH — build & notarize it first."; exit 1; }

# Locate Sparkle's generate_appcast tool from the resolved SwiftPM artifacts.
SPARKLE_BIN=$(find "$PROJECT_ROOT/build" "$PROJECT_ROOT/.build" -type f -name generate_appcast -path "*artifacts*" 2>/dev/null | head -1)
[[ -n "$SPARKLE_BIN" ]] || { print -u2 -- "generate_appcast not found; build the Pollux scheme once so SwiftPM resolves Sparkle."; exit 1; }

WORK="$PROJECT_ROOT/.build/appcast-work"
rm -rf "$WORK"; mkdir -p "$WORK" "$PROJECT_ROOT/docs"
cp "$DMG_PATH" "$WORK/"

print -- "==> Generating appcast (EdDSA signature from login Keychain)"
"$SPARKLE_BIN" \
  --download-url-prefix "https://github.com/mabino/pollux/releases/download/${VERSION}/" \
  -o "$PROJECT_ROOT/docs/appcast.xml" \
  "$WORK"

print -- "==> Wrote $PROJECT_ROOT/docs/appcast.xml"
print -- "    Commit docs/appcast.xml and push; GitHub Pages will serve it at the SUFeedURL."
