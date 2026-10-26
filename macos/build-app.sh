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
# Codes from messages: the relay (services/otp-proxy). Empty means the switch says "not available".
CODE_RELAY_URL=$(sed -n "s/^OTP_PROXY_URL=//p" ../rr-edition.properties | tail -n 1)
if [ -n "$CODE_RELAY_URL" ]; then
  "$PLIST_BUDDY" -c "Add :BridgeyCodeRelayURL string $CODE_RELAY_URL" "$APP_PATH/Contents/Info.plist"
fi
# Codes from messages > On this Mac: the model manifest (updates without an app update), and the
# only place model files may come from.
CODE_MODEL_MANIFEST_URL=$(edition_value OTP_MODEL_MANIFEST_URL)
ASSET_URL_PREFIX=$(edition_value UPDATE_ASSET_URL_PREFIX)
"$PLIST_BUDDY" -c "Add :BridgeyCodeModelManifestURL string $CODE_MODEL_MANIFEST_URL" "$APP_PATH/Contents/Info.plist"
"$PLIST_BUDDY" -c "Add :BridgeyAssetURLPrefix string $ASSET_URL_PREFIX" "$APP_PATH/Contents/Info.plist"
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
# llama.cpp (MIT) for the on-device code model, also a SwiftPM binary framework. The release
# framework is universal; keep only the architectures the app itself was built for.
LLAMA_FRAMEWORK=".build/$CONFIGURATION/llama.framework"
if [ ! -d "$LLAMA_FRAMEWORK" ]; then
  LLAMA_FRAMEWORK=$(find .build/artifacts -path "*macos*/llama.framework" -type d -prune | head -n 1)
fi
[ -d "$LLAMA_FRAMEWORK" ] || { echo "llama.framework not found; run swift build first" >&2; exit 1; }
ditto "$LLAMA_FRAMEWORK" "$APP_PATH/Contents/Frameworks/llama.framework"
LLAMA_BINARY="$APP_PATH/Contents/Frameworks/llama.framework/Versions/A/llama"
APP_ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/BridgeyMac")
if [ "$(lipo -archs "$LLAMA_BINARY")" != "$APP_ARCHS" ]; then
  set --
  for arch in $APP_ARCHS; do set -- "$@" -extract "$arch"; done
  lipo "$LLAMA_BINARY" "$@" -output "$LLAMA_BINARY.thin"
  mv "$LLAMA_BINARY.thin" "$LLAMA_BINARY"
fi
# The bundled model manifest, the licences (About > Licences) and the Gemma notice.
cp Resources/otp-model.json "$APP_PATH/Contents/Resources/otp-model.json"
mkdir -p "$APP_PATH/Contents/Resources/Licences"
cp ../NOTICE "$APP_PATH/Contents/Resources/Licences/NOTICE.txt"
cp ../LICENSE "$APP_PATH/Contents/Resources/Licences/LICENSE.txt"
cp ../licences/*.txt "$APP_PATH/Contents/Resources/Licences/"
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
#
# Three modes:
#   MACOS_SIGNING_IDENTITY  an Apple-issued identity (Developer ID); timestamped.
#   RR_SIGNING_IDENTITY     SHA-1 of the Round Robin self-signed identity, already in a keychain on
#                           the search list (scripts/rr/build-macos.sh sets this up). The designated
#                           requirement pins the bundle ID and that certificate.
#   neither                 ad-hoc, for local development builds.
SPARKLE_VERSIONED="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -n "${MACOS_SIGNING_IDENTITY:-}" ]; then
  SIGN_MODE=apple
  APP_REQUIREMENT=""
elif [ -n "${RR_SIGNING_IDENTITY:-}" ]; then
  SIGN_MODE=rr
  RR_LEAF=$(printf '%s' "$RR_SIGNING_IDENTITY" | tr 'A-F' 'a-f')
  printf '%s' "$RR_LEAF" | grep -Eq '^[0-9a-f]{40}$' || { echo "RR_SIGNING_IDENTITY must be a SHA-1 fingerprint" >&2; exit 1; }
  APP_REQUIREMENT="=designated => identifier \"$EDITION_APP_ID\" and certificate leaf = H\"$RR_LEAF\""
else
  SIGN_MODE=adhoc
  # Keep an explicit, stable designated requirement for ad-hoc builds. System
  # services such as Notification Center and Local Network privacy otherwise
  # see only a changing code hash after each update and can lose bundle metadata.
  APP_REQUIREMENT="=designated => identifier \"$EDITION_APP_ID\""
fi
sign_code() {
  case "$SIGN_MODE" in
    apple) codesign --force --options runtime --timestamp --sign "$MACOS_SIGNING_IDENTITY" "$@" ;;
    # Apple's timestamp service only serves Apple-issued certificates.
    rr) codesign --force --options runtime --timestamp=none --sign "$RR_LEAF" "$@" ;;
    *) codesign --force --sign - "$@" ;;
  esac
}
for xpc in "$SPARKLE_VERSIONED"/XPCServices/*.xpc; do
  [ -d "$xpc" ] || continue
  sign_code --preserve-metadata=entitlements "$xpc"
done
sign_code "$SPARKLE_VERSIONED/Autoupdate"
sign_code "$SPARKLE_VERSIONED/Updater.app"
sign_code "$APP_PATH/Contents/Frameworks/Sparkle.framework"
sign_code "$APP_PATH/Contents/Frameworks/llama.framework"
if [ -n "$APP_REQUIREMENT" ]; then
  sign_code --entitlements Resources/Bridgey.entitlements --requirements "$APP_REQUIREMENT" "$APP_PATH"
else
  sign_code --entitlements Resources/Bridgey.entitlements "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"

echo "$APP_PATH"
