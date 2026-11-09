#!/bin/sh
set -eu
cd "$(dirname "$0")"
CONFIGURATION=${CONFIGURATION:-debug}
case "$CONFIGURATION" in debug|release) ;; *) echo 'Use debug or release' >&2; exit 2;; esac
export BRIDGEY_DISTRIBUTION=app-store
SCRATCH="$PWD/.build/store"
if [ "${1:-}" = --test ]; then
  swift test --scratch-path "$SCRATCH/tests" --jobs "${RR_CI_CPU:-2}" -Xswiftc -warnings-as-errors
  exit
fi
swift build -c "$CONFIGURATION" --product BridgeyMacStore --scratch-path "$SCRATCH" --jobs "${RR_CI_CPU:-2}" -Xswiftc -warnings-as-errors
APP="$SCRATCH/$CONFIGURATION/Bridgey Store.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/$CONFIGURATION/BridgeyMacStore" "$APP/Contents/MacOS/BridgeyMacStore"
python3 - "$APP/Contents/Info.plist" <<'PY'
import os,plistlib,sys
p={'CFBundleIdentifier':'in.roundrobin.bridgey.store','CFBundleName':'Bridgey Store','CFBundleDisplayName':'Bridgey by Round Robin',
   'CFBundleExecutable':'BridgeyMacStore','CFBundlePackageType':'APPL','CFBundleShortVersionString':os.environ.get('BRIDGEY_VERSION_NAME','0.10.0'),
   'CFBundleVersion':os.environ.get('BRIDGEY_BUILD_NUMBER','1'),'LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,
   'NSLocalNetworkUsageDescription':'Bridgey finds and connects to your paired Android phone to share files, clipboard text and notifications.',
   'NSBonjourServices':['_bridgey._tcp.'],'NSHumanReadableCopyright':'Round Robin Solutions','CFBundleIconFile':'Bridgey'}
with open(sys.argv[1],'wb') as f:plistlib.dump(p,f)
PY
cp Resources/BridgeyStorePrivacy.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
python3 create-icns.py Resources/AppIcon.iconset "$APP/Contents/Resources/Bridgey.icns"
# No Apple account or certificate is needed for local sandbox verification.
# Store signing is a later, explicit operation using an Apple Distribution identity/profile.
codesign --force --sign - --entitlements Resources/BridgeyStore.entitlements "$APP"
codesign --verify --deep --strict "$APP"
python3 ../scripts/rr/check-macos-store.py "$APP"
mkdir -p .rrci-reports
ditto -c -k --keepParent "$APP" .rrci-reports/BridgeyStore.zip
printf '%s\n' "$APP"
