#!/bin/sh
# Package an already owned-CI-built native acceptance tool. No compilation or real app state.
set -eu
[ "$#" -eq 2 ] || { echo "usage: package-call-mute-probe.sh <built-probe> <new-app-path>" >&2; exit 2; }
probe_binary=$1
probe_app=$2
[ -f "$probe_binary" ] && [ ! -e "$probe_app" ] || { echo "need a built probe and a new destination" >&2; exit 2; }
mkdir -p "$probe_app/Contents/MacOS"
cp "$probe_binary" "$probe_app/Contents/MacOS/CallMediaTapProbe"
chmod 755 "$probe_app/Contents/MacOS/CallMediaTapProbe"
cat > "$probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CallMediaTapProbe</string>
<key>CFBundleIdentifier</key><string>in.roundrobin.bridgey.qa.callmute</string>
<key>CFBundleName</key><string>Bridgey mute check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>This isolated check processes only its silent test player's audio in memory. Nothing is recorded or sent.</string>
</dict></plist>
PLIST
probe_entitlements="$probe_app/Contents/probe-entitlements.plist"
cat > "$probe_entitlements" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --options runtime --entitlements "$probe_entitlements" \
  --requirements '=designated => identifier "in.roundrobin.bridgey.qa.callmute"' "$probe_app"
codesign --verify --strict "$probe_app"
printf '%s\n' "$probe_app"
