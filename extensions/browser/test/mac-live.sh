#!/bin/sh
# Live check of browser support on a Mac (docs/browser-extensions.md): the real bridgey-browser-host helper, run the
# way a browser runs it, against a throwaway test instance of the debug app paired with the scripted peer
# (rust/client/examples/peer.rs) over loopback.
#
# The instance has its own bundle ID (in.roundrobin.bridgey.test.browser), support folder, Keychain items,
# preferences, port and Bonjour type; its host manifests go to /tmp/<bundle ID>-browsers, never to the browsers on the
# Mac, and no browser is started. An installed Bridgey, its data and its pairings are never touched. Everything it
# made is deleted at the end.
#
# Usage, on a Mac, from the repository root: extensions/browser/test/mac-live.sh [--app <debug .app>]
# Without --app it builds the debug app and the peer while holding /tmp/app-build-mac.lock (mkdir, released with rmdir).
set -eu

ROOT=$(cd "$(dirname -- "$0")/../../.." && pwd)
BID=in.roundrobin.bridgey.test.browser
PORT=42499
PEER_PORT=42501
SERVICE=_bridgeysb._tcp
WORK=/tmp/bridgey-browser-live
APP="$WORK/app/Bridgey Browser.app"
CTL="/tmp/$BID-control"
BROWSERS="/tmp/$BID-browsers"
CHROME=chrome-extension://aajelmcjgfjbhemgofnompobgbcdfcin/
APP_IN=""
[ "${1:-}" = --app ] && APP_IN=$2
LOCKED=0
PEER_PID=""
FAILED=0

cleanup() {
  [ -n "$PEER_PID" ] && kill "$PEER_PID" 2>/dev/null
  [ $LOCKED = 1 ] && rmdir /tmp/app-build-mac.lock 2>/dev/null
  pkill -9 -f "$APP/Contents/MacOS/BridgeyMac" 2>/dev/null || true
  for s in "$BID.trust" "$BID.identity"; do
    while security delete-generic-password -s "$s" >/dev/null 2>&1; do :; done
  done
  defaults delete "$BID" 2>/dev/null || true
  rm -rf "$HOME/Library/Application Support/$BID" "$HOME/Library/Caches/$BID" "$HOME/Library/Preferences/$BID.plist" \
    "$HOME/Library/HTTPStorages/$BID" "$HOME/Library/Saved Application State/$BID.savedState" "$CTL" "$BROWSERS" "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

check() {
  if [ "$2" = ok ]; then echo "ok   $1"; else echo "FAIL $1: $3"; FAILED=1; fi
}

rm -rf "$WORK" "$CTL" "$BROWSERS"
mkdir -p "$WORK/app" "$WORK/peer" "$CTL"
if [ -z "$APP_IN" ]; then
  until mkdir /tmp/app-build-mac.lock 2>/dev/null; do echo "waiting for /tmp/app-build-mac.lock"; sleep 20; done
  LOCKED=1
  (cd "$ROOT/macos" && ./build-app.sh >/dev/null)
  APP_IN="$ROOT/macos/.build/debug/Bridgey by Round Robin.app"
fi
. "$ROOT/scripts/rr/rust-env.sh"
"$CARGO_BIN" build --release --locked -p bridgey-client --example peer --manifest-path "$ROOT/rust/Cargo.toml" >/dev/null 2>&1
cp "$ROOT/rust/target/release/examples/peer" "$WORK/peer/peer"
if [ $LOCKED = 1 ]; then rmdir /tmp/app-build-mac.lock; LOCKED=0; fi
[ -x "$APP_IN/Contents/Helpers/bridgey-browser-host" ] || { echo "no helper in $APP_IN"; exit 1; }

echo "== the throwaway instance ($BID, port $PORT)"
ditto "$APP_IN" "$APP"
PL="$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleIdentifier $BID" "$PL"
"$PB" -c "Set :CFBundleName Bridgey Browser" "$PL"
for k in CFBundleDisplayName BridgeyTestInstance BridgeyTestPort BridgeyTestServiceType CFBundleURLTypes NSServices \
  BridgeyConnectControlURL BridgeyCodeRelayURL SUEnableAutomaticChecks; do
  "$PB" -c "Delete :$k" "$PL" 2>/dev/null || true
done
"$PB" -c "Add :CFBundleDisplayName string Bridgey Browser" "$PL"
"$PB" -c "Add :BridgeyTestInstance bool true" "$PL"
"$PB" -c "Add :BridgeyTestPort integer $PORT" "$PL"
"$PB" -c "Add :BridgeyTestServiceType string $SERVICE." "$PL"
"$PB" -c "Set :NSBonjourServices:0 $SERVICE" "$PL"
"$PB" -c "Set :SUFeedURL http://127.0.0.1:9/none.xml" "$PL"
"$PB" -c "Add :SUEnableAutomaticChecks bool false" "$PL"
rm -rf "$APP/Contents/PlugIns" "$APP/Contents/Resources/Metadata.appintents"
codesign --force --sign - --entitlements "$ROOT/macos/Resources/Bridgey.entitlements" \
  --requirements "=designated => identifier \"$BID\"" "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"
defaults write "$BID" setup.completedVersion -int 1
defaults write "$BID" settings.onboarding.completed -bool true
defaults write "$BID" SUEnableAutomaticChecks -bool false
# Browser support on from the start; two "browsers" in the instance's own folder get the manifests.
defaults write "$BID" settings.browser.support -bool true
mkdir -p "$BROWSERS/Google/Chrome" "$BROWSERS/Mozilla"

open -n -g "$APP"
i=0
until [ -s "$CTL/status.json" ] && nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
  sleep 0.5; i=$((i + 1)); [ $i -lt 120 ] || { echo "the instance did not start"; exit 1; }
done
SOCKET="$HOME/Library/Application Support/$BID/browser.sock"
i=0
until [ -S "$SOCKET" ]; do sleep 0.2; i=$((i + 1)); [ $i -lt 50 ] || break; done
[ -S "$SOCKET" ] && check "browser support starts its socket at launch" ok || check "browser support starts its socket at launch" no "$SOCKET"
MODE=$(stat -f %Lp "$SOCKET" 2>/dev/null || echo none)
[ "$MODE" = 600 ] && check "the socket is owner-only" ok || check "the socket is owner-only" no "$MODE"
HELPER="$APP/Contents/Helpers/bridgey-browser-host"
# The app writes its resolved path (/tmp is /private/tmp on macOS).
HELPER_REAL="$(cd -P "$(dirname -- "$HELPER")" && pwd)/bridgey-browser-host"
GOT=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$BROWSERS/Google/Chrome/NativeMessagingHosts/in.roundrobin.bridgey.json" 2>&1 || true)
[ "$GOT" = "$HELPER_REAL" ] && check "the Chrome manifest names this instance's helper" ok || check "the Chrome manifest names this instance's helper" no "$GOT"
GOT=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["allowed_extensions"])' "$BROWSERS/Mozilla/NativeMessagingHosts/in.roundrobin.bridgey.json" 2>&1 || true)
[ "$GOT" = "['bridgey@roundrobin.in']" ] && check "the Firefox manifest allows only Bridgey's add-on" ok || check "the Firefox manifest allows only Bridgey's add-on" no "$GOT"

echo "== pairing the scripted peer"
: > "$CTL/autoconfirm"
: > "$CTL/allow"
sleep 1
"$WORK/peer/peer" --name "Test phone" --port "$PEER_PORT" --allow --pair "127.0.0.1:$PORT" --seconds 120 > "$WORK/peer.log" 2>&1 &
PEER_PID=$!
i=0
until grep -q '"event":"paired","ok":true' "$WORK/peer.log" 2>/dev/null; do
  sleep 0.5; i=$((i + 1)); [ $i -lt 60 ] || { echo "pairing did not finish"; cat "$WORK/peer.log"; exit 1; }
done
sleep 3

# The helper, as a browser starts it: the caller as its argument, one framed message on stdin, one framed answer.
ask() {
  python3 -I - "$HELPER" "$1" "$2" <<'PY'
import json, struct, subprocess, sys
helper, caller, message = sys.argv[1], sys.argv[2], sys.argv[3].encode()
done = subprocess.run([helper, caller], input=struct.pack("=I", len(message)) + message, capture_output=True, timeout=30)
out = done.stdout
length = struct.unpack("=I", out[:4])[0]
print(out[4:4 + length].decode())
PY
}

ANSWER=$(ask "$CHROME" '{"v":1,"type":"devices"}')
echo "     devices: $ANSWER"
echo "$ANSWER" | grep -q '"name":"Test phone"' && echo "$ANSWER" | grep -q '"connected":true' && echo "$ANSWER" | grep -q '"links":true' \
  && check "the helper lists the paired peer as connected with links" ok || check "the helper lists the paired peer as connected with links" no "$ANSWER"
DEVICE=$(printf '%s' "$ANSWER" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["devices"][0]["id"])')

ANSWER=$(ask "$CHROME" "{\"v\":1,\"type\":\"send\",\"device\":\"$DEVICE\",\"url\":\"https://roundrobin.in/bridgey?from=browser-check\"}")
echo "     send: $ANSWER"
echo "$ANSWER" | grep -Eq '"result":"(opened|waiting)"' && check "a page goes to the device and its answer comes back" ok || check "a page goes to the device and its answer comes back" no "$ANSWER"
sleep 1
grep -q '"event":"link".*from=browser-check' "$WORK/peer.log" && check "the peer received the link" ok || check "the peer received the link" no "$(grep link "$WORK/peer.log" | tail -2)"

ANSWER=$(ask "$CHROME" "{\"v\":1,\"type\":\"send\",\"device\":\"$DEVICE\",\"url\":\"mailto:hello@roundrobin.in?subject=Hi\"}")
echo "     mailto: $ANSWER"
echo "$ANSWER" | grep -q '"result":"copied"' && check "an email address goes to the device's clipboard" ok || check "an email address goes to the device's clipboard" no "$ANSWER"

ANSWER=$(ask "chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/" '{"v":1,"type":"devices"}')
[ "$ANSWER" = '{"error":"forbidden","ok":false,"v":1}' ] && check "an unknown extension is refused" ok || check "an unknown extension is refused" no "$ANSWER"
ANSWER=$(ask "$CHROME" "{\"v\":1,\"type\":\"send\",\"device\":\"$DEVICE\",\"url\":\"file:///etc/hosts\"}")
[ "$ANSWER" = '{"error":"bad_url","ok":false,"v":1}' ] && check "a file address is refused" ok || check "a file address is refused" no "$ANSWER"
ANSWER=$(ask "$CHROME" '{"v":1,"type":"send","device":"00000000-0000-0000-0000-000000000000","url":"https://example.com/"}')
[ "$ANSWER" = '{"error":"unknown_device","ok":false,"v":1}' ] && check "an unknown device is refused" ok || check "an unknown device is refused" no "$ANSWER"

pkill -f "$APP/Contents/MacOS/BridgeyMac" 2>/dev/null || true
sleep 2
ANSWER=$(ask "$CHROME" '{"v":1,"type":"devices"}')
[ "$ANSWER" = '{"error":"app_not_running","ok":false,"v":1}' ] && check "a stopped app is reported" ok || check "a stopped app is reported" no "$ANSWER"

[ $FAILED = 0 ] && echo "all checks passed" || echo "some checks failed"
exit $FAILED
