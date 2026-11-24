#!/bin/sh
# Builds the release APK (run on rr-dev-1, a GitHub-hosted runner or any Linux host with the Android SDK).
# Usage: BRIDGEY_VERSION_NAME=... BRIDGEY_BUILD_NUMBER=... scripts/rr/build-android.sh [--unsigned] <output.apk>
# Signed (default): keystore BRIDGEY_RR_KEYSTORE (default ~/.config/bridgey-rr/rr-bridgey.jks) and the
# ANDROID_* passwords from BRIDGEY_RR_SIGNING_ENV (default ~/.config/bridgey-rr/android-signing.env).
# Secrets are loaded only into the Gradle process environment and never printed.
# --unsigned: no keys at all (the hosted release job); scripts/rr/sign-android.sh signs the APK on rr-dev-1.
set -eu
. "$(dirname -- "$0")/common.sh"
. "$RR_ROOT/scripts/rr/rust-env.sh"
. "$RR_ROOT/scripts/rr/android-apk-check.sh"

UNSIGNED=0
[ "${1:-}" = --unsigned ] && { UNSIGNED=1; shift; }
OUTPUT=${1:?usage: build-android.sh [--unsigned] <output.apk>}
: "${BRIDGEY_VERSION_NAME:?set BRIDGEY_VERSION_NAME}"
: "${BRIDGEY_BUILD_NUMBER:?set BRIDGEY_BUILD_NUMBER}"
KEYSTORE=${BRIDGEY_RR_KEYSTORE:-$HOME/.config/bridgey-rr/rr-bridgey.jks}
SIGNING_ENV=${BRIDGEY_RR_SIGNING_ENV:-$HOME/.config/bridgey-rr/android-signing.env}
if [ $UNSIGNED = 0 ]; then
  [ -f "$KEYSTORE" ] || die "keystore not found at $KEYSTORE"
  [ -f "$SIGNING_ENV" ] || die "signing env not found at $SIGNING_ENV"
fi

# The Connect anywhere core is part of every APK (Gradle builds it with cargo-ndk).
sh "$(dirname -- "$0")/rust-toolchain.sh" android
PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
export PATH

SLOT=""
command -v iieon-slot >/dev/null 2>&1 && SLOT=iieon-slot

if [ $UNSIGNED = 1 ]; then
  # No signing config at all, so Gradle writes app-release-unsigned.apk; nothing from the environment can sign it.
  (
    cd "$RR_ROOT/android"
    BRIDGEY_VERSION_NAME="$BRIDGEY_VERSION_NAME" BRIDGEY_BUILD_NUMBER="$BRIDGEY_BUILD_NUMBER" \
      env -u GH_TOKEN -u GITHUB_TOKEN -u BRIDGEY_ANDROID_KEYSTORE -u BRIDGEY_ANDROID_STORE_PASSWORD \
      -u BRIDGEY_ANDROID_KEY_ALIAS -u BRIDGEY_ANDROID_KEY_PASSWORD -u ANDROID_STORE_PASSWORD -u ANDROID_KEY_ALIAS \
      -u ANDROID_KEY_PASSWORD $SLOT ./gradlew --console=plain :app:testDebugUnitTest :app:assembleRelease
  )
  APK="$RR_ROOT/android/app/build/outputs/apk/release/app-release-unsigned.apk"
else
  (
    cd "$RR_ROOT/android"
    set -a
    . "$SIGNING_ENV"
    set +a
    BRIDGEY_ANDROID_KEYSTORE="$KEYSTORE" BRIDGEY_VERSION_NAME="$BRIDGEY_VERSION_NAME" BRIDGEY_BUILD_NUMBER="$BRIDGEY_BUILD_NUMBER" \
      env -u GH_TOKEN -u GITHUB_TOKEN $SLOT ./gradlew --console=plain :app:testDebugUnitTest :app:assembleRelease
  )
  APK="$RR_ROOT/android/app/build/outputs/apk/release/app-release.apk"
fi
[ -f "$APK" ] || die "release APK was not produced"

if [ $UNSIGNED = 1 ]; then check_release_apk "$APK" unsigned; else check_release_apk "$APK" signed; fi

mkdir -p "$(dirname -- "$OUTPUT")"
cp "$APK" "$OUTPUT"
# Where and with what this was built, for the release provenance (rrrelease.py reads it next to the APK).
{
  echo "host=$(hostname)"
  echo "os=$(uname -sr)"
  echo "java=$("${JAVA_HOME:+$JAVA_HOME/bin/}java" -version 2>&1 | head -n 1)"
} > "$OUTPUT.build-info" || true
echo "Android: $OUTPUT ($BADGING)"
