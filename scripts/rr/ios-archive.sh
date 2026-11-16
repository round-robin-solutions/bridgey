#!/bin/sh
# Archives Bridgey for iOS, exports it for App Store Connect and, with --upload, sends it to TestFlight.
# NOT RUN YET: it needs the Apple Developer team (enrolment is waiting on an ID region query), the App IDs and
# App Group, and an App Store Connect API key. ios/README.md "TestFlight" lists the steps. Uploading is a release
# action: only with Rahul's go-ahead.
#
# Usage: DEVELOPMENT_TEAM=<team ID> ASC_KEY_ID=<id> ASC_ISSUER_ID=<uuid> ASC_KEY_PATH=<AuthKey.p8> \
#        BRIDGEY_VERSION_NAME=1.0.0-beta.N BRIDGEY_BUILD_NUMBER=<YYDDDHHMM> scripts/rr/ios-archive.sh [--upload]
set -eu
. "$(dirname -- "$0")/common.sh"

UPLOAD=0
[ "${1:-}" = --upload ] && UPLOAD=1
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM (the Apple Developer team ID)}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH (the .p8 file)}"
: "${BRIDGEY_VERSION_NAME:?set BRIDGEY_VERSION_NAME}"
: "${BRIDGEY_BUILD_NUMBER:?set BRIDGEY_BUILD_NUMBER}"

IOS="$RR_ROOT/ios"
OUT="$IOS/out/archive"
rm -rf "$OUT"
mkdir -p "$OUT"
MARKETING=$(printf '%s' "$BRIDGEY_VERSION_NAME" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')

sh "$RR_ROOT/scripts/rr/build-ios.sh" --core-only

AUTH="-allowProvisioningUpdates -authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
# shellcheck disable=SC2086
xcodebuild archive -project "$IOS/Bridgey.xcodeproj" -scheme Bridgey -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Bridgey.xcarchive" $AUTH \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" MARKETING_VERSION="$MARKETING" CURRENT_PROJECT_VERSION="$BRIDGEY_BUILD_NUMBER" \
  BRIDGEY_VERSION_NAME="$BRIDGEY_VERSION_NAME" BRIDGEY_UPSTREAM_BASE="$(edition_value EDITION_UPSTREAM_BASE)" \
  BRIDGEY_BUNDLE_ID="$(edition_value EDITION_APP_ID)"

OPTIONS="$OUT/ExportOptions.plist"
cp "$IOS/Config/ExportOptions.plist" "$OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $DEVELOPMENT_TEAM" "$OPTIONS"
[ "$UPLOAD" = 1 ] && /usr/libexec/PlistBuddy -c "Set :destination upload" "$OPTIONS"
# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$OUT/Bridgey.xcarchive" -exportOptionsPlist "$OPTIONS" -exportPath "$OUT/export" $AUTH
ls -la "$OUT/export"
[ "$UPLOAD" = 1 ] && echo "uploaded $BRIDGEY_VERSION_NAME ($BRIDGEY_BUILD_NUMBER) to App Store Connect; it shows in TestFlight once processed"
exit 0
