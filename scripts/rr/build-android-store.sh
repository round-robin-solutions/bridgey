#!/bin/sh
# Builds the two non-GitHub Android variants, each with its own key (never the GitHub release path):
#   play  Google Play AAB (no self-updater, no install or SMS permissions), signed with the Play UPLOAD key
#   qa    test/QA APK (minified like release), signed with the TEST key; never published
# Usage: BRIDGEY_VERSION_NAME=... BRIDGEY_BUILD_NUMBER=... scripts/rr/build-android-store.sh play|qa <output>
# Signing comes from a credentials JSON (default ~/.config/bridgey/signing/credentials.json, keys "upload"
# and "test"); values go only into the Gradle environment and are never printed.
set -eu
. "$(dirname -- "$0")/common.sh"

KIND=${1:?usage: build-android-store.sh play|qa <output>}
OUTPUT=${2:?usage: build-android-store.sh play|qa <output>}
: "${BRIDGEY_VERSION_NAME:?set BRIDGEY_VERSION_NAME}"
: "${BRIDGEY_BUILD_NUMBER:?set BRIDGEY_BUILD_NUMBER}"
CREDS=${BRIDGEY_SIGNING_CREDENTIALS:-$HOME/.config/bridgey/signing/credentials.json}
[ -f "$CREDS" ] || die "signing credentials not found at $CREDS"
RELEASE_CERT=$(edition_value ANDROID_CERT_SHA256 | tr -d ':' | tr 'A-F' 'a-f')
case "$KIND" in
  play) ROLE=upload PREFIX=BRIDGEY_PLAY_UPLOAD TASK=:app:bundlePlay EXPECTED=$(edition_value ANDROID_UPLOAD_CERT_SHA256)
        ARTIFACT="$RR_ROOT/android/app/build/outputs/bundle/play/app-play.aab" ;;
  qa)   ROLE=test PREFIX=BRIDGEY_TEST TASK=:app:assembleQa EXPECTED=$(edition_value ANDROID_TEST_CERT_SHA256)
        ARTIFACT="$RR_ROOT/android/app/build/outputs/apk/qa/app-qa.apk" ;;
  *) die "kind must be play or qa" ;;
esac
[ "$EXPECTED" != "$RELEASE_CERT" ] || die "the $ROLE certificate in rr-edition.properties is the release certificate"

sh "$(dirname -- "$0")/rust-toolchain.sh" android
PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
export PATH
SLOT=""
command -v iieon-slot >/dev/null 2>&1 && SLOT=iieon-slot

# Only this variant's key reaches Gradle: the release (ANDROID_*, BRIDGEY_ANDROID_*) names are removed.
ENVFILE=$(mktemp)
trap 'rm -f "$ENVFILE"' EXIT
python3 - "$CREDS" "$ROLE" "$PREFIX" > "$ENVFILE" <<'PY'
import json, shlex, sys
k = json.load(open(sys.argv[1]))['keys'][sys.argv[2]]
for name, value in (('KEYSTORE', k['store']), ('STORE_PASSWORD', k['password']), ('KEY_ALIAS', k['alias']), ('KEY_PASSWORD', k['keyPassword'])):
    print(f'export {sys.argv[3]}_{name}={shlex.quote(value)}')
PY
(
  cd "$RR_ROOT/android"
  unset ANDROID_STORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD BRIDGEY_ANDROID_KEYSTORE \
    BRIDGEY_ANDROID_STORE_PASSWORD BRIDGEY_ANDROID_KEY_ALIAS BRIDGEY_ANDROID_KEY_PASSWORD GH_TOKEN GITHUB_TOKEN
  . "$ENVFILE"
  rm -f "$ENVFILE"
  $SLOT ./gradlew --console=plain "$TASK"
)
[ -f "$ARTIFACT" ] || die "$ARTIFACT was not produced"

SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}
BUILD_TOOLS=""
for dir in $(ls -d "$SDK"/build-tools/* | sort -V -r); do
  [ -x "$dir/apksigner" ] && [ -x "$dir/aapt2" ] && { BUILD_TOOLS=$dir; break; }
done
[ -n "$BUILD_TOOLS" ] || die "no build-tools with apksigner and aapt2 under $SDK"
if [ "$KIND" = play ]; then
  # AABs are JAR-signed: compare the signer certificate's SHA-256.
  CERT=$(unzip -p "$ARTIFACT" 'META-INF/*.RSA' 2>/dev/null | openssl pkcs7 -inform DER -print_certs 2>/dev/null \
    | openssl x509 -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
  MANIFEST=$(unzip -p "$ARTIFACT" base/manifest/AndroidManifest.xml | strings -n 6)
  for perm in REQUEST_INSTALL_PACKAGES UPDATE_PACKAGES_WITHOUT_USER_ACTION READ_SMS SEND_SMS RECEIVE_SMS; do
    ! printf '%s' "$MANIFEST" | grep -q "android.permission.$perm" || die "the Play bundle still declares $perm"
  done
else
  CERT=$("$BUILD_TOOLS/apksigner" verify --print-certs "$ARTIFACT" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | tr -d ':')
  BADGING=$("$BUILD_TOOLS/aapt2" dump badging "$ARTIFACT" | head -n 1)
  echo "$BADGING" | grep -q "versionCode='$BRIDGEY_BUILD_NUMBER'" || die "unexpected versionCode: $BADGING"
fi
[ "$CERT" != "$RELEASE_CERT" ] || die "$KIND build is signed with the release key"
[ "$CERT" = "$EXPECTED" ] || die "$KIND build is not signed with the $ROLE key (got ${CERT:-nothing}, expected $EXPECTED)"
mkdir -p "$(dirname -- "$OUTPUT")"
cp "$ARTIFACT" "$OUTPUT"
echo "$KIND: $OUTPUT (signed with the $ROLE key $CERT)"
