#!/bin/sh
# A throwaway Bridgey test instance for live tests, made from the debug app ./build-app.sh just built (the test hooks
# compile only into debug builds, docs/connect-anywhere.md "Test hooks"). It has its own bundle ID, so its own support
# folder, Keychain items and preferences, its own TCP port, the update feed off and no Share extension. The installed
# Bridgey, its data and its pairings are never touched. Setup is marked done so the instance starts straight away.
# Usage (in macos/, on the Mac, after ./build-app.sh):
#   ./make-test-instance.sh <label> <port> [--model]
#   --model  downloads the code model (Codes from messages > On this Mac) from the manifest's public URL into the
#            instance's own support folder and checks its SHA-256, so the instance reads codes on this Mac.
# Prints the app path. Control files go in /tmp/<bundle id>-control/ (PairingCoordinator test control).
set -eu
LABEL=$1
PORT=$2
WANT_MODEL=${3:-}
value() { sed -n "s/^$1=//p" ../rr-edition.properties | tail -n 1; }
BASE=$(value EDITION_APP_ID)
APP_NAME=$(value EDITION_MAC_APP_NAME)
SOURCE=".build/debug/$APP_NAME.app"
BID="$BASE.test.$LABEL"
OUT_DIR="/tmp/bridgey-test-$LABEL"
APP="$OUT_DIR/Bridgey Test $LABEL.app"
[ -d "$SOURCE" ] || { echo "no debug app: run ./build-app.sh first" >&2; exit 1; }
case "$BID" in "$BASE") echo "refusing to reuse the installed bundle ID" >&2; exit 1 ;; esac
rm -rf "$APP"
mkdir -p "$OUT_DIR"
ditto "$SOURCE" "$APP"
rm -rf "$APP/Contents/PlugIns"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleIdentifier $BID" "$APP/Contents/Info.plist"
"$PB" -c "Add :BridgeyTestInstance bool true" "$APP/Contents/Info.plist"
"$PB" -c "Add :BridgeyTestPort integer $PORT" "$APP/Contents/Info.plist"
"$PB" -c "Set :SUFeedURL http://127.0.0.1:9/none/appcast.xml" "$APP/Contents/Info.plist"
codesign --force --sign - --entitlements Resources/Bridgey.entitlements \
  --requirements "=designated => identifier \"$BID\"" "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"
defaults write "$BID" setup.completedVersion -int 1
if [ "$WANT_MODEL" = --model ]; then
  MODELS="$HOME/Library/Application Support/$BID/Models"
  mkdir -p "$MODELS"
  chmod 700 "$HOME/Library/Application Support/$BID" "$MODELS"
  manifest() { /usr/bin/plutil -extract "$1" raw -o - Resources/otp-model.json; }
  URL=$(manifest url)
  FILE=$(basename "$URL")
  SHA=$(manifest sha256)
  if [ "$(shasum -a 256 "$MODELS/$FILE" 2>/dev/null | cut -d' ' -f1)" != "$SHA" ]; then
    curl -fsSL --retry 3 -o "$MODELS/$FILE.part" "$URL"
    [ "$(shasum -a 256 "$MODELS/$FILE.part" | cut -d' ' -f1)" = "$SHA" ] || { echo "model checksum mismatch" >&2; exit 1; }
    mv "$MODELS/$FILE.part" "$MODELS/$FILE"
    chmod 600 "$MODELS/$FILE"
  fi
  printf '{"fileName":"%s","installedAt":"%s","name":"%s","sha256":"%s","size":%s,"version":%s}\n' \
    "$FILE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(manifest name)" "$SHA" "$(manifest size)" "$(manifest version)" > "$MODELS/installed.json"
fi
echo "$APP ($BID, port $PORT)"
