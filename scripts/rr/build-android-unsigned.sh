#!/bin/sh
# RR CI entry point for the Android half of a Bridgey by Round Robin release or nightly, on a GitHub-hosted runner.
# Usage: scripts/rr/build-android-unsigned.sh nightly [output-dir]
#        scripts/rr/build-android-unsigned.sh tag [output-dir]     beta or stable from the tag in RR_CI_REF
# Builds the release APK without signing it (no secrets on the runner) and the dependency listing for its SBOM, for
# the version scripts/rr/ci-release.sh then signs (scripts/rr/sign-android.sh) and publishes from rr-dev-1.
# Output (default rrci-release-out/android in the repository; GitHub's artifact upload skips hidden folders), fixed
# names: app-release-unsigned.apk and its .build-info, android-dependencies.txt, release.env (LF lines: NOW, CHANNEL,
# VERSION_NAME, BUILD_NUMBER, TAG, REVISION). ci-release.sh derives the version again from NOW and refuses an APK
# whose revision or version differ. Needs JDK 17 and the Android SDK (platform 36, a build-tools with apksigner, aapt2
# and zipalign, NDK and CMake as android/app/build.gradle.kts names them); rust-toolchain.sh adds the Rust side.
set -eu
. "$(dirname -- "$0")/common.sh"

MODE=${1:-}
case "$MODE" in nightly|tag) ;; *) sed -n '2,11p' "$0"; exit 2 ;; esac
OUT=${2:-$RR_ROOT/rrci-release-out/android}

if [ "$MODE" = nightly ]; then
  set -- nightly
else
  REF=${RR_CI_REF:?RR_CI_REF must name the release tag}
  case "$REF" in refs/tags/v*) ;; *) die "not a release tag: $REF" ;; esac
  VERSION=${REF#refs/tags/v}
  if echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$'; then CHANNEL=beta
  elif echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then CHANNEL=stable
  else die "v$VERSION is neither a stable (v1.0.0) nor a beta (v1.0.0-beta.2) tag"; fi
  set -- "$CHANNEL" --version "$VERSION"
fi

# RR CI gives every job of a release run one time, so the Android, Mac and Windows halves derive the same version and
# build number (the APK's versionCode).
NOW=${RR_CI_RELEASE_NOW:-$(date -u +%Y-%m-%dT%H:%M:00Z)}
eval "$(python3 "$RR_ROOT/scripts/rr/rrrelease.py" version "$@" --now "$NOW")"
export BRIDGEY_VERSION_NAME="$VERSION_NAME" BRIDGEY_BUILD_NUMBER="$BUILD_NUMBER"
echo "== Android (unsigned) for $CHANNEL $VERSION_NAME build $BUILD_NUMBER"
mkdir -p "$OUT"
rm -f "$OUT/release.env"
sh "$RR_ROOT/scripts/rr/build-android.sh" --unsigned "$OUT/app-release-unsigned.apk"
# A failed listing stops beta and stable (their SBOM needs it); a nightly goes out without the Android SBOM.
if ! sh "$RR_ROOT/scripts/rr/android-deps.sh" "$OUT/android-dependencies.txt"; then
  [ "$CHANNEL" = nightly ] || die "the Android dependency listing for the SBOM failed"
  echo "warning: no Android SBOM input in this nightly (the dependency listing failed)" >&2
fi
# Written last, with LF lines (printf, never a Windows tool): its presence means the APK is complete.
printf 'NOW=%s\nCHANNEL=%s\nVERSION_NAME=%s\nBUILD_NUMBER=%s\nTAG=%s\nREVISION=%s\n' \
  "$NOW" "$CHANNEL" "$VERSION_NAME" "$BUILD_NUMBER" "$TAG" "$(git -C "$RR_ROOT" rev-parse HEAD)" > "$OUT/release.env"
