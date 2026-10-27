#!/bin/sh
# Builds the signed release APK (run on rr-dev-1 or any Linux host with the Android SDK).
# Usage: BRIDGEY_VERSION_NAME=... BRIDGEY_BUILD_NUMBER=... scripts/rr/build-android.sh <output.apk>
# Signing: keystore BRIDGEY_RR_KEYSTORE (default ~/.config/bridgey-rr/rr-bridgey.jks) and the
# ANDROID_* passwords from BRIDGEY_RR_SIGNING_ENV (default ~/.config/bridgey-rr/android-signing.env).
# Secrets are loaded only into the Gradle process environment and never printed.
set -eu
. "$(dirname -- "$0")/common.sh"

OUTPUT=${1:?usage: build-android.sh <output.apk>}
: "${BRIDGEY_VERSION_NAME:?set BRIDGEY_VERSION_NAME}"
: "${BRIDGEY_BUILD_NUMBER:?set BRIDGEY_BUILD_NUMBER}"
KEYSTORE=${BRIDGEY_RR_KEYSTORE:-$HOME/.config/bridgey-rr/rr-bridgey.jks}
SIGNING_ENV=${BRIDGEY_RR_SIGNING_ENV:-$HOME/.config/bridgey-rr/android-signing.env}
[ -f "$KEYSTORE" ] || die "keystore not found at $KEYSTORE"
[ -f "$SIGNING_ENV" ] || die "signing env not found at $SIGNING_ENV"

SLOT=""
command -v iieon-slot >/dev/null 2>&1 && SLOT=iieon-slot

(
  cd "$RR_ROOT/android"
  set -a
  . "$SIGNING_ENV"
  set +a
  BRIDGEY_ANDROID_KEYSTORE="$KEYSTORE" BRIDGEY_VERSION_NAME="$BRIDGEY_VERSION_NAME" BRIDGEY_BUILD_NUMBER="$BRIDGEY_BUILD_NUMBER" \
    env -u GH_TOKEN -u GITHUB_TOKEN $SLOT ./gradlew --console=plain :app:testDebugUnitTest :app:assembleRelease
)

APK="$RR_ROOT/android/app/build/outputs/apk/release/app-release.apk"
[ -f "$APK" ] || die "release APK was not produced"

SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}
# The newest build-tools that has both tools (CI images carry several versions, some partial).
BUILD_TOOLS=""
for dir in $(ls -d "$SDK"/build-tools/* | sort -V -r); do
  [ -x "$dir/apksigner" ] && [ -x "$dir/aapt2" ] && { BUILD_TOOLS=$dir; break; }
done
[ -n "$BUILD_TOOLS" ] || die "no build-tools with apksigner and aapt2 under $SDK"
EXPECTED_CERT=$(edition_value ANDROID_CERT_SHA256 | tr -d ':' | tr 'A-F' 'a-f')
CERTS=$("$BUILD_TOOLS/apksigner" verify --print-certs "$APK") || die "apksigner could not verify the APK"
ACTUAL_CERT=$(printf '%s\n' "$CERTS" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | tr -d ':' | tr 'A-F' 'a-f')
# Certificate fingerprints are public, so a mismatch names both.
[ "$ACTUAL_CERT" = "$EXPECTED_CERT" ] || die "APK is not signed with the Round Robin release key (signed with ${ACTUAL_CERT:-nothing}, expected $EXPECTED_CERT; $(basename "$BUILD_TOOLS") apksigner)"
BADGING=$("$BUILD_TOOLS/aapt2" dump badging "$APK" | head -n 1)
echo "$BADGING" | grep -q "name='$(edition_value EDITION_APP_ID)'" || die "unexpected package: $BADGING"
echo "$BADGING" | grep -q "versionCode='$BRIDGEY_BUILD_NUMBER'" || die "unexpected versionCode: $BADGING"
echo "$BADGING" | grep -q "versionName='$BRIDGEY_VERSION_NAME'" || die "unexpected versionName: $BADGING"

mkdir -p "$(dirname -- "$OUTPUT")"
cp "$APK" "$OUTPUT"
# Where and with what this was built, for the release provenance (rrrelease.py reads it next to the APK).
{
  echo "host=$(hostname)"
  echo "os=$(uname -sr)"
  echo "java=$("${JAVA_HOME:+$JAVA_HOME/bin/}java" -version 2>&1 | head -n 1)"
} > "$OUTPUT.build-info" || true
echo "Android: $OUTPUT ($BADGING)"
