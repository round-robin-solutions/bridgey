#!/bin/sh
# Builds the macOS app, DMG and ZIP (run on a Mac from a checkout or copy of the repository).
# Usage: BRIDGEY_VERSION_NAME=... BRIDGEY_BUILD_NUMBER=... scripts/rr/build-macos.sh <output-dir>
# Without MACOS_SIGNING_IDENTITY the app is ad-hoc signed; Sparkle trusts the EdDSA signature
# that rrrelease.py adds to the appcast.
set -eu
. "$(dirname -- "$0")/common.sh"

OUTPUT=${1:?usage: build-macos.sh <output-dir>}
: "${BRIDGEY_VERSION_NAME:?set BRIDGEY_VERSION_NAME}"
: "${BRIDGEY_BUILD_NUMBER:?set BRIDGEY_BUILD_NUMBER}"
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)

cd "$RR_ROOT/macos"
swift test -c release --skip MacTrustRegistryTests
OUTPUT_DIR="$OUTPUT" ./package-release.sh

APP=".build/release/$(edition_value EDITION_MAC_APP_NAME).app"
PLIST="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "$(edition_value EDITION_APP_ID)" ] || die "wrong bundle id"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$BRIDGEY_BUILD_NUMBER" ] || die "wrong CFBundleVersion"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$BRIDGEY_VERSION_NAME" ] || die "wrong version"
codesign --verify --deep --strict "$APP"
echo "macOS: $OUTPUT"
ls -l "$OUTPUT"
