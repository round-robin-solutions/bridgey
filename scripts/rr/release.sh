#!/bin/sh
# Bridgey by Round Robin release: build, checksum, feeds, signed appcast; publish only with --publish.
#
# Usage: scripts/rr/release.sh <stable|beta|nightly> [options]
#   --version V          version name (stable defaults to EDITION_NEXT_VERSION; beta requires it; nightly is generated)
#   --notes-file F       release notes (plain text) for GitHub, the feeds and the appcast
#   --mac-host HOST      build macOS on HOST over ssh (for example: personal)
#   --mac-sign           sign the Mac build with the Round Robin code signing identity (see docs/rr-mac-signing.md)
#   --macos-artifacts D  use an existing <prefix>-macOS.dmg and .zip from D (built by build-macos.sh)
#   --skip-macos         Android only (the channel feed keeps the previous macOS entry)
#   --skip-android       macOS only (the channel feed keeps the previous Android entry)
#   --apk FILE           use an existing signed APK instead of building one
#   --now ISO            UTC time the version, build number and tag derive from (default now; the hosted
#                        nightly passes one value to its Android, macOS and publish jobs)
#   --publish            create the GitHub release and update the channel feeds (default: dry run into dist/)
#
# Runs on rr-dev-1 (Android build, Sparkle signing key) and drives the Mac over ssh. See docs/rr-edition.md.
set -eu
. "$(dirname -- "$0")/common.sh"

CHANNEL=${1:-}
case "$CHANNEL" in stable|beta|nightly) shift ;; *) sed -n '2,17p' "$0"; exit 2 ;; esac
VERSION="" NOTES_FILE="" MAC_HOST="" MAC_ARTIFACTS="" SKIP_MAC=0 SKIP_ANDROID=0 APK_IN="" PUBLISH=0 NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION=$2; shift 2 ;;
    --notes-file) NOTES_FILE=$(cd "$(dirname -- "$2")" && pwd)/$(basename -- "$2"); shift 2 ;;
    --mac-host) MAC_HOST=$2; shift 2 ;;
    --mac-sign) export BRIDGEY_RR_MAC_SIGN=1; shift ;;
    --macos-artifacts) MAC_ARTIFACTS=$2; shift 2 ;;
    --skip-macos) SKIP_MAC=1; shift ;;
    --skip-android) SKIP_ANDROID=1; shift ;;
    --apk) APK_IN=$2; shift 2 ;;
    --now) NOW=$2; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done
[ $SKIP_MAC = 1 ] || [ -n "$MAC_HOST" ] || [ -n "$MAC_ARTIFACTS" ] || die "pass --mac-host, --macos-artifacts or --skip-macos"
ED_KEY=${BRIDGEY_RR_SPARKLE_KEY:-$HOME/.config/bridgey-rr/sparkle_ed25519_private.key}
[ $SKIP_MAC = 1 ] || [ -f "$ED_KEY" ] || die "Sparkle private key not found at $ED_KEY"

set --
[ -n "$VERSION" ] && set -- "$@" --version "$VERSION"
[ -n "$NOW" ] && set -- "$@" --now "$NOW"
VERSION_ENV=$(python3 "$RR_ROOT/scripts/rr/rrrelease.py" version "$CHANNEL" "$@")
eval "$VERSION_ENV"
export BRIDGEY_VERSION_NAME="$VERSION_NAME" BRIDGEY_BUILD_NUMBER="$BUILD_NUMBER"
DIST="$RR_ROOT/dist/$TAG"
WORK="$DIST/work"
rm -rf "$DIST"
mkdir -p "$WORK"
echo "== $CHANNEL $VERSION_NAME build $BUILD_NUMBER tag $TAG -> $DIST"

set --
if [ $SKIP_ANDROID = 0 ]; then
  if [ -n "$APK_IN" ]; then
    cp "$APK_IN" "$WORK/app-release.apk"
  else
    sh "$RR_ROOT/scripts/rr/build-android.sh" "$WORK/app-release.apk"
  fi
  set -- "$@" --apk "$WORK/app-release.apk"
fi
if [ $SKIP_MAC = 0 ]; then
  PREFIX=$(edition_value EDITION_ASSET_PREFIX)
  if [ -n "$MAC_HOST" ]; then
    sh "$RR_ROOT/scripts/rr/build-macos-remote.sh" "$MAC_HOST" "$WORK/macos"
    MAC_ARTIFACTS="$WORK/macos"
  fi
  set -- "$@" --dmg "$MAC_ARTIFACTS/$PREFIX-macOS.dmg" --zip "$MAC_ARTIFACTS/$PREFIX-macOS.zip" --ed-key "$ED_KEY"
fi
[ -n "$NOTES_FILE" ] && set -- "$@" --notes-file "$NOTES_FILE"

python3 "$RR_ROOT/scripts/rr/rrrelease.py" assemble --channel "$CHANNEL" --version "$VERSION_NAME" \
  --build "$BUILD_NUMBER" --tag "$TAG" --dist "$DIST" --fetch-previous "$@"
python3 "$RR_ROOT/scripts/rr/rrrelease.py" verify --dist "$DIST"
rm -rf "$WORK"

if [ $PUBLISH = 1 ]; then
  sh "$RR_ROOT/scripts/rr/publish.sh" "$DIST"
else
  echo "Dry run complete. Review $DIST, then publish with: scripts/rr/publish.sh $DIST"
fi
