#!/bin/sh
# Builds the macOS app, DMG and ZIP (run on a Mac from a checkout or copy of the repository).
# Usage: BRIDGEY_VERSION_NAME=... BRIDGEY_BUILD_NUMBER=... scripts/rr/build-macos.sh <output-dir>
# Signing: with RR_MAC_P12_FILE and RR_MAC_P12_PASSWORD_FILE set, the Round Robin self-signed
# identity is imported into a throwaway keychain for this build only (the login keychain is not
# touched) and both files are deleted straight after the import. Otherwise the app is ad-hoc
# signed. Either way Sparkle trusts the EdDSA signature that rrrelease.py adds to the appcast.
set -eu
. "$(dirname -- "$0")/common.sh"

OUTPUT=${1:?usage: build-macos.sh <output-dir>}
: "${BRIDGEY_VERSION_NAME:?set BRIDGEY_VERSION_NAME}"
: "${BRIDGEY_BUILD_NUMBER:?set BRIDGEY_BUILD_NUMBER}"
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)

cd "$RR_ROOT/macos"

if [ -n "${RR_MAC_P12_FILE:-}" ]; then
  [ -f "$RR_MAC_P12_FILE" ] && [ -f "${RR_MAC_P12_PASSWORD_FILE:?set RR_MAC_P12_PASSWORD_FILE}" ] || die "signing files are missing"
  SIGN_KEYCHAIN=$(mktemp -d /tmp/bridgey-rr-sign.XXXXXX)/sign.keychain-db
  OLD_SEARCH_LIST=$(security list-keychains -d user | sed 's/^ *"//; s/"$//')
  cleanup_signing() {
    # Restore the user's search list (one entry per line, paths may contain spaces).
    printf '%s\n' "$OLD_SEARCH_LIST" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s
    security delete-keychain "$SIGN_KEYCHAIN" 2>/dev/null || true
    rm -rf "$(dirname -- "$SIGN_KEYCHAIN")"
    rm -f "$RR_MAC_P12_FILE" "$RR_MAC_P12_PASSWORD_FILE"
  }
  trap cleanup_signing EXIT INT TERM
  KEYCHAIN_PASSWORD=$(openssl rand -hex 24)
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN"
  security set-keychain-settings "$SIGN_KEYCHAIN"  # no auto-lock during the build
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN"
  security import "$RR_MAC_P12_FILE" -k "$SIGN_KEYCHAIN" -f pkcs12 -P "$(cat "$RR_MAC_P12_PASSWORD_FILE")" -T /usr/bin/codesign >/dev/null
  rm -f "$RR_MAC_P12_FILE" "$RR_MAC_P12_PASSWORD_FILE"
  # Lets codesign use the key without a GUI prompt (this works over ssh).
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN" >/dev/null
  printf '%s\n' "$SIGN_KEYCHAIN" "$OLD_SEARCH_LIST" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s
  RR_SIGNING_IDENTITY=$(security find-identity -p codesigning "$SIGN_KEYCHAIN" | awk '/"Bridgey by Round Robin Code Signing"/ { print $2; exit }')
  [ -n "$RR_SIGNING_IDENTITY" ] || die "the signing identity did not import"
  export RR_SIGNING_IDENTITY
fi
# The Connect anywhere core goes into Contents/Frameworks (build-app.sh builds it with cargo).
sh "$RR_ROOT/scripts/rr/rust-toolchain.sh" mac
PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
export PATH
swift test -c release --skip MacTrustRegistryTests
OUTPUT_DIR="$OUTPUT" ./package-release.sh

APP=".build/release/$(edition_value EDITION_MAC_APP_NAME).app"
PLIST="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "$(edition_value EDITION_APP_ID)" ] || die "wrong bundle id"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$BRIDGEY_BUILD_NUMBER" ] || die "wrong CFBundleVersion"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$BRIDGEY_VERSION_NAME" ] || die "wrong version"
[ -f "$APP/Contents/Frameworks/libbridgey_connect.dylib" ] || die "the app has no Connect anywhere core (Contents/Frameworks/libbridgey_connect.dylib)"
codesign --verify --deep --strict "$APP"
if [ -n "${RR_SIGNING_IDENTITY:-}" ]; then
  LEAF=$(printf '%s' "$RR_SIGNING_IDENTITY" | tr 'A-F' 'a-f')
  codesign -d -r - "$APP" 2>&1 | grep -q "certificate leaf = H\"$LEAF\"" || die "designated requirement does not pin the signing certificate"
fi
# Where and with what this was built, for the release provenance (rrrelease.py reads it with the DMG and ZIP).
{
  echo "host=$(hostname)"
  echo "os=$(sw_vers -productName) $(sw_vers -productVersion)"
  echo "swift=$(swift --version 2>&1 | head -n 1)"
  echo "xcode=$(xcodebuild -version 2>&1 | head -n 1)"
} > "$OUTPUT/mac.build-info" || true
echo "macOS: $OUTPUT"
ls -l "$OUTPUT"
