#!/bin/sh
set -eu

SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
CACHE_ROOT="${TMPDIR:-/private/tmp}/bridgey-swift-build"
CONFIGURATION="${CONFIGURATION:-debug}"

# Round Robin edition settings live in rr-edition.properties at the repository root.
edition_value() {
  value=$(sed -n "s/^$1=//p" ../rr-edition.properties | tail -n 1)
  [ -n "$value" ] || { echo "rr-edition.properties is missing $1" >&2; exit 1; }
  printf '%s' "$value"
}
EDITION_APP_ID=$(edition_value EDITION_APP_ID)
APP_NAME=$(edition_value EDITION_MAC_APP_NAME)
FEED_BASE_URL=$(edition_value UPDATE_FEED_BASE_URL)
APP_PATH=".build/$CONFIGURATION/$APP_NAME.app"

env \
  SDKROOT="$SDK_PATH" \
  CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang" \
  SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/swift" \
  swift build -c "$CONFIGURATION"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
mkdir -p "$APP_PATH/Contents/Frameworks"
cp ".build/$CONFIGURATION/BridgeyMac" "$APP_PATH/Contents/MacOS/BridgeyMac"
cp "Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
PLIST_BUDDY=/usr/libexec/PlistBuddy
"$PLIST_BUDDY" -c "Add :SUFeedURL string $FEED_BASE_URL/appcast.xml" "$APP_PATH/Contents/Info.plist"
test "$("$PLIST_BUDDY" -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")" = "$EDITION_APP_ID"
# Release builds get their version from scripts/rr (see docs/rr-edition.md).
if [ -n "${BRIDGEY_VERSION_NAME:-}" ]; then
  "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $BRIDGEY_VERSION_NAME" "$APP_PATH/Contents/Info.plist"
fi
if [ -n "${BRIDGEY_BUILD_NUMBER:-}" ]; then
  "$PLIST_BUDDY" -c "Set :CFBundleVersion $BRIDGEY_BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"
fi

# Embed Sparkle (resolved by SwiftPM as a binary framework) and let the
# executable find it inside the bundle.
SPARKLE_FRAMEWORK=".build/$CONFIGURATION/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
  SPARKLE_FRAMEWORK=$(find .build/artifacts -path "*macos*/Sparkle.framework" -type d -prune | head -n 1)
fi
[ -d "$SPARKLE_FRAMEWORK" ] || { echo "Sparkle.framework not found; run swift build first" >&2; exit 1; }
ditto "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP_PATH/Contents/MacOS/BridgeyMac" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_PATH/Contents/MacOS/BridgeyMac"
fi
# Space Grotesk and Inter (SIL OFL), with their licences.
mkdir -p "$APP_PATH/Contents/Resources/Fonts"
cp Resources/Fonts/*.ttf Resources/Fonts/*-OFL.txt "$APP_PATH/Contents/Resources/Fonts/"
for localization in Resources/*.lproj; do
  [ -d "$localization" ] || continue
  cp -R "$localization" "$APP_PATH/Contents/Resources/"
done
python3 ./create-icns.py \
  "Resources/AppIcon.iconset" \
  "$APP_PATH/Contents/Resources/Bridgey.icns"

# macOS 26 prefers an app icon compiled into Assets.car, while older releases
# still use Bridgey.icns. Build both from the same reviewed source images.
if xcrun --find actool >/dev/null 2>&1; then
  ASSET_CATALOG="$CACHE_ROOT/BridgeyAssets.xcassets"
  APP_ICON_SET="$ASSET_CATALOG/AppIcon.appiconset"
  rm -rf "$ASSET_CATALOG"
  mkdir -p "$APP_ICON_SET"
  cp Resources/AppIcon.iconset/*.png "$APP_ICON_SET/"
  cp Resources/AppIconContents.json "$APP_ICON_SET/Contents.json"
  xcrun actool "$ASSET_CATALOG" \
    --compile "$APP_PATH/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$CACHE_ROOT/BridgeyAppIcon.plist"
  test -f "$APP_PATH/Contents/Resources/Assets.car"
else
  echo "warning: actool is unavailable; keeping the compatible Bridgey.icns icon only" >&2
fi
# Sign Sparkle's nested code inside-out (Sparkle's documented order), then the
# app itself. No --deep, so the app's entitlements never reach Sparkle's helpers.
SPARKLE_VERSIONED="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
sign_code() {
  if [ -n "${MACOS_SIGNING_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$MACOS_SIGNING_IDENTITY" "$@"
  else
    codesign --force --sign - "$@"
  fi
}
for xpc in "$SPARKLE_VERSIONED"/XPCServices/*.xpc; do
  [ -d "$xpc" ] || continue
  sign_code --preserve-metadata=entitlements "$xpc"
done
sign_code "$SPARKLE_VERSIONED/Autoupdate"
sign_code "$SPARKLE_VERSIONED/Updater.app"
sign_code "$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [ -n "${MACOS_SIGNING_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements Resources/Bridgey.entitlements --sign "$MACOS_SIGNING_IDENTITY" "$APP_PATH"
else
  # Keep an explicit, stable designated requirement for ad-hoc builds. System
  # services such as Notification Center and Local Network privacy otherwise
  # see only a changing code hash after each update and can lose bundle metadata.
  codesign --force --sign - \
    --entitlements Resources/Bridgey.entitlements \
    --requirements "=designated => identifier \"$EDITION_APP_ID\"" \
    "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"

echo "$APP_PATH"
