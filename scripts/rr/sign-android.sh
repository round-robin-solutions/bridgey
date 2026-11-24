#!/bin/sh
# Signs an unsigned Bridgey by Round Robin release APK with the Round Robin release key (on rr-dev-1).
# Usage: BRIDGEY_VERSION_NAME=... BRIDGEY_BUILD_NUMBER=... scripts/rr/sign-android.sh <unsigned.apk> <output.apk>
# The APK comes from RR CI's hosted Android job (scripts/rr/build-android-unsigned.sh). Signing matches what Gradle
# does for the release build: APK Signature Scheme v2 only (minSdk 26), native libraries kept aligned to 16 KB pages.
# Then the same checks as a local build (scripts/rr/android-apk-check.sh). Keystore BRIDGEY_RR_KEYSTORE and the
# ANDROID_* passwords from BRIDGEY_RR_SIGNING_ENV, as for build-android.sh; they reach only apksigner's environment
# and are never printed.
set -eu
. "$(dirname -- "$0")/common.sh"
. "$RR_ROOT/scripts/rr/android-apk-check.sh"

INPUT=${1:?usage: sign-android.sh <unsigned.apk> <output.apk>}
OUTPUT=${2:?usage: sign-android.sh <unsigned.apk> <output.apk>}
: "${BRIDGEY_VERSION_NAME:?set BRIDGEY_VERSION_NAME}"
: "${BRIDGEY_BUILD_NUMBER:?set BRIDGEY_BUILD_NUMBER}"
KEYSTORE=${BRIDGEY_RR_KEYSTORE:-$HOME/.config/bridgey-rr/rr-bridgey.jks}
SIGNING_ENV=${BRIDGEY_RR_SIGNING_ENV:-$HOME/.config/bridgey-rr/android-signing.env}
[ -f "$INPUT" ] || die "no APK at $INPUT"
[ -f "$KEYSTORE" ] || die "keystore not found at $KEYSTORE"
[ -f "$SIGNING_ENV" ] || die "signing env not found at $SIGNING_ENV"

# What arrives must already be the release we expect (package, version, both cores), before any key is used.
check_release_apk "$INPUT" unsigned
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ALIGNED="$WORK/aligned.apk"
if "$BUILD_TOOLS/zipalign" -c -P 16 4 "$INPUT" >/dev/null 2>&1; then
  cp "$INPUT" "$ALIGNED"
else
  "$BUILD_TOOLS/zipalign" -f -P 16 4 "$INPUT" "$ALIGNED"
fi
(
  set -a
  . "$SIGNING_ENV"
  set +a
  [ -n "${ANDROID_KEY_ALIAS:-}" ] && [ -n "${ANDROID_STORE_PASSWORD:-}" ] && [ -n "${ANDROID_KEY_PASSWORD:-}" ] ||
    die "the signing env must set ANDROID_KEY_ALIAS, ANDROID_STORE_PASSWORD and ANDROID_KEY_PASSWORD"
  "$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-key-alias "$ANDROID_KEY_ALIAS" \
    --ks-pass env:ANDROID_STORE_PASSWORD --key-pass env:ANDROID_KEY_PASSWORD \
    --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled false --v4-signing-enabled false \
    --out "$WORK/signed.apk" "$ALIGNED"
)
check_release_apk "$WORK/signed.apk" signed

mkdir -p "$(dirname -- "$OUTPUT")"
cp "$WORK/signed.apk" "$OUTPUT"
# The build's own provenance travels with it; the signing step adds where it was signed.
{
  [ ! -f "$INPUT.build-info" ] || cat "$INPUT.build-info"
  echo "signed_on=$(hostname)"
} > "$OUTPUT.build-info" || true
echo "Android signed: $OUTPUT ($BADGING)"
