#!/bin/bash
# Builds "Live Outline.app" into mac/build/. Requires Xcode command line tools on macOS 14+.
#   BUILD_NUMBER   version number to stamp in (default 1); updates only install when it goes up
#   SIGN_IDENTITY  code-signing identity (default: ad-hoc "-"). A stable identity keeps
#                  microphone permission across updates.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

APP="build/Live Outline.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/LiveOutline" "$APP/Contents/MacOS/LiveOutline"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.$BUILD_NUMBER" "$APP/Contents/Info.plist"

# Embed Sparkle (the updater) and let the app find it.
SPARKLE="$(find .build -type d -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -print -quit)"
if [ -z "$SPARKLE" ]; then SPARKLE="$BIN_DIR/Sparkle.framework"; fi
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/LiveOutline" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/LiveOutline"
fi

# Turn the 1024px PNG into an .icns icon.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built: $(pwd)/$APP (version 1.$BUILD_NUMBER, signed with: $SIGN_IDENTITY)"
