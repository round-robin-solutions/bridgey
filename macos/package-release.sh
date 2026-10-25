#!/bin/sh
set -eu

CONFIGURATION=release ./build-app.sh

edition_value() {
  value=$(sed -n "s/^$1=//p" ../rr-edition.properties | tail -n 1)
  [ -n "$value" ] || { echo "rr-edition.properties is missing $1" >&2; exit 1; }
  printf '%s' "$value"
}
APP_NAME=$(edition_value EDITION_MAC_APP_NAME)
ASSET_PREFIX=$(edition_value EDITION_ASSET_PREFIX)
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
APP_PATH=".build/release/$APP_NAME.app"
DMG_ROOT="${TMPDIR:-/private/tmp}/bridgey-rr-dmg"
DMG_NAME="$ASSET_PREFIX-macOS.dmg"
ZIP_NAME="$ASSET_PREFIX-macOS.zip"

mkdir -p "$OUTPUT_DIR"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$OUTPUT_DIR/$DMG_NAME"

if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
  xcrun notarytool submit "$OUTPUT_DIR/$DMG_NAME" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait
  xcrun stapler staple "$OUTPUT_DIR/$DMG_NAME"
  xcrun stapler validate "$OUTPUT_DIR/$DMG_NAME"
fi

# The zip is also the Sparkle update archive.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/$ZIP_NAME"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS-macOS.txt
  shasum -a 256 -c SHA256SUMS-macOS.txt
)
