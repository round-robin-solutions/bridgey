# Checks a Bridgey by Round Robin release APK (sourced by build-android.sh and sign-android.sh, not executed).
# check_release_apk <apk> <signed|unsigned>: the Connect anywhere core for both ABIs, the package, versionCode and
# versionName (BRIDGEY_BUILD_NUMBER, BRIDGEY_VERSION_NAME), native libraries aligned to 16 KB pages, and for a signed
# APK every signer being the Round Robin release key. Sets BUILD_TOOLS and BADGING.

android_build_tools() {
  SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}
  # The newest build-tools that has every tool needed (CI images carry several versions, some partial).
  BUILD_TOOLS=""
  for dir in $(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V -r); do
    [ -x "$dir/apksigner" ] && [ -x "$dir/aapt2" ] && [ -x "$dir/zipalign" ] && { BUILD_TOOLS=$dir; break; }
  done
  [ -n "$BUILD_TOOLS" ] || die "no build-tools with apksigner, aapt2 and zipalign under $SDK"
}

check_release_apk() {
  apk=$1
  android_build_tools
  if [ "$2" = signed ]; then
    EXPECTED_CERT=$(edition_value ANDROID_CERT_SHA256 | tr -d ':' | tr 'A-F' 'a-f')
    CERTS=$("$BUILD_TOOLS/apksigner" verify --print-certs "$apk") || die "apksigner could not verify the APK"
    # Every signer's certificate, whatever apksigner calls it: build-tools 36 prints "Signer #1 certificate
    # SHA-256 digest:", 37 prints "V2 Signer: certificate SHA-256 digest:". All of them must be ours.
    ACTUAL_CERT=$(printf '%s\n' "$CERTS" | sed -n '/^Source Stamp/d; s/^.*[Ss]igner.* certificate SHA-256 digest: //p' | tr -d ':' | tr 'A-F' 'a-f' | sort -u | tr '\n' ' ' | sed 's/ $//')
    # Certificate fingerprints are public, so a mismatch names both.
    [ "$ACTUAL_CERT" = "$EXPECTED_CERT" ] || die "APK is not signed with the Round Robin release key (signed with ${ACTUAL_CERT:-nothing}, expected $EXPECTED_CERT; $(basename "$BUILD_TOOLS") apksigner)"
  fi
  for abi in arm64-v8a x86_64; do
    unzip -l "$apk" "lib/$abi/libbridgey_connect.so" >/dev/null 2>&1 || die "the APK has no Connect anywhere core for $abi (lib/$abi/libbridgey_connect.so)"
  done
  "$BUILD_TOOLS/zipalign" -c -P 16 4 "$apk" >/dev/null 2>&1 || die "the APK's native libraries are not aligned to 16 KB pages"
  BADGING=$("$BUILD_TOOLS/aapt2" dump badging "$apk" | head -n 1)
  echo "$BADGING" | grep -q "name='$(edition_value EDITION_APP_ID)'" || die "unexpected package: $BADGING"
  echo "$BADGING" | grep -q "versionCode='$BRIDGEY_BUILD_NUMBER'" || die "unexpected versionCode: $BADGING"
  echo "$BADGING" | grep -q "versionName='$BRIDGEY_VERSION_NAME'" || die "unexpected versionName: $BADGING"
}
