#!/bin/sh
# The throwaway Mac test instance the stress, soak, acceptance and cross-version runs use (docs/testing-stress.md,
# docs/acceptance-1.0.md). Sourced by stress-mac.sh, or run as
#   STRESS_MAC_BID=in.roundrobin.bridgey.test.<label> STRESS_MAC_PORT=<port> STRESS_MAC_SERVICE=_<type>._tcp \
#     sh scripts/rr/stress-instance.sh <debug .app> <instance .app>
# BID, PORT and SERVICE come from those variables; RR_ROOT is the repository.
BID=${BID:-${STRESS_MAC_BID:-in.roundrobin.bridgey.test.stress}}
PORT=${PORT:-${STRESS_MAC_PORT:-42497}}
SERVICE=${SERVICE:-${STRESS_MAC_SERVICE:-_bridgeyst._tcp}}
RR_ROOT=${RR_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}

# The throwaway instance from a debug app: its own bundle ID, port, Bonjour type and preferences, the update feed off,
# the synthetic screen (so it never asks macOS for Screen Recording or Accessibility) and an ad-hoc signature. Its
# clipboard is a private pasteboard of its own (AppPasteboard), never the Mac's.
make_instance() {
  src=$1 app=$2
  rm -rf "$app"
  mkdir -p "$(dirname "$app")"
  ditto "$src" "$app"
  PL="$app/Contents/Info.plist"
  PB=/usr/libexec/PlistBuddy
  "$PB" -c "Set :CFBundleIdentifier $BID" "$PL"
  "$PB" -c "Set :CFBundleName Bridgey Stress" "$PL"
  for k in CFBundleDisplayName BridgeyTestInstance BridgeyTestPort BridgeyTestServiceType BridgeyTestScreenSource CFBundleURLTypes \
    NSServices BridgeyConnectControlURL BridgeyCodeRelayURL SUEnableAutomaticChecks; do
    "$PB" -c "Delete :$k" "$PL" 2>/dev/null || true
  done
  "$PB" -c "Add :CFBundleDisplayName string Bridgey Stress" "$PL"
  "$PB" -c "Add :BridgeyTestInstance bool true" "$PL"
  "$PB" -c "Add :BridgeyTestPort integer $PORT" "$PL"
  "$PB" -c "Add :BridgeyTestServiceType string $SERVICE." "$PL"
  "$PB" -c "Add :BridgeyTestScreenSource string synthetic" "$PL"
  "$PB" -c "Set :NSBonjourServices:0 $SERVICE" "$PL"
  "$PB" -c "Set :SUFeedURL http://127.0.0.1:9/none.xml" "$PL"
  "$PB" -c "Add :SUEnableAutomaticChecks bool false" "$PL"
  rm -rf "$app/Contents/PlugIns" "$app/Contents/Resources/Metadata.appintents"
  codesign --force --sign - --entitlements "$RR_ROOT/macos/Resources/Bridgey.entitlements" \
    --requirements "=designated => identifier \"$BID\"" "$app" >/dev/null 2>&1
  codesign --verify --deep --strict "$app"
}

if [ "$(basename -- "$0")" = stress-instance.sh ] && [ $# -eq 2 ]; then
  case $BID in in.roundrobin.bridgey.test.?*) ;; *) echo "STRESS_MAC_BID must be in.roundrobin.bridgey.test.<label>" >&2; exit 2 ;; esac
  set -eu
  make_instance "$1" "$2"
fi
