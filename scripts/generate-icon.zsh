#!/bin/zsh
#
# Generates the Pollux app icon programmatically and assembles the macOS asset catalog + .icns.
# Run: ./scripts/generate-icon.zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
BUILD_DIR="$PROJECT_ROOT/.build/icon"
ICONSET_DIR="$PROJECT_ROOT/Assets.xcassets/AppIcon.appiconset"
MASTER="$BUILD_DIR/icon_1024.png"

mkdir -p "$BUILD_DIR"
mkdir -p "$ICONSET_DIR"

print -- "Rendering master icon (1024×1024)…"
swift "$SCRIPT_DIR/PolluxIconGenerator.swift" "$MASTER"

# Downscale the master to every size the macOS app-icon set needs.
typeset -a sizes
sizes=(16 32 64 128 256 512 1024)
for px in $sizes; do
  if [[ "$px" == "1024" ]]; then
    cp "$MASTER" "$ICONSET_DIR/icon_${px}.png"
  else
    sips -z "$px" "$px" "$MASTER" --out "$ICONSET_DIR/icon_${px}.png" >/dev/null
  fi
done

print -- "Writing AppIcon Contents.json…"
cat > "$ICONSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# Also emit a standalone .icns (handy for packaging / notarization).
print -- "Building Pollux.icns…"
TMP_ICONSET="$BUILD_DIR/Pollux.iconset"
rm -rf "$TMP_ICONSET"
mkdir -p "$TMP_ICONSET"
sips -z 16 16     "$MASTER" --out "$TMP_ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$MASTER" --out "$TMP_ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$MASTER" --out "$TMP_ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$MASTER" --out "$TMP_ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$MASTER" --out "$TMP_ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$MASTER" --out "$TMP_ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$MASTER" --out "$TMP_ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$MASTER" --out "$TMP_ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$MASTER" --out "$TMP_ICONSET/icon_512x512.png"    >/dev/null
cp "$MASTER" "$TMP_ICONSET/icon_512x512@2x.png"
iconutil -c icns "$TMP_ICONSET" -o "$BUILD_DIR/Pollux.icns"

print -- "Done. Asset catalog: $ICONSET_DIR"
print -- "        Standalone icns: $BUILD_DIR/Pollux.icns"
