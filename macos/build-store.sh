#!/bin/sh
set -eu
cd "$(dirname "$0")"
CONFIGURATION=${CONFIGURATION:-debug}
case "$CONFIGURATION" in debug|release) ;; *) echo 'Use debug or release' >&2; exit 2;; esac
# SwiftPM removes an unused direct-edition lockfile when resolving the dependency-free flavour.
# Restore its exact bytes on every exit so building the store never changes direct-download resolution.
LOCK_COPY=$(mktemp "${TMPDIR:-/tmp}/bridgey-store-resolution.XXXXXX")
HAD_LOCK=0
if [ -f Package.resolved ]; then cp Package.resolved "$LOCK_COPY"; HAD_LOCK=1; fi
restore_lock() {
  if [ -f "$LOCK_COPY" ]; then
    if [ "$HAD_LOCK" = 1 ]; then cp "$LOCK_COPY" Package.resolved; else rm -f Package.resolved; fi
    rm -f "$LOCK_COPY"
  fi
}
trap restore_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export BRIDGEY_DISTRIBUTION=app-store
SCRATCH="$PWD/.build/store"
if [ "${1:-}" = --test ]; then
  if xcrun --find xctest >/dev/null 2>&1; then
    swift test --scratch-path "$SCRATCH/tests" --jobs "${RR_CI_CPU:-2}" -Xswiftc -warnings-as-errors
  else
    # Command Line Tools includes the SDK/compiler but not XCTest. Run the same three cases in the built app.
    swift run --scratch-path "$SCRATCH/tests" --jobs "${RR_CI_CPU:-2}" -Xswiftc -warnings-as-errors BridgeyMacStore --self-check
  fi
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
mkdir -p "$APP/Contents/Resources/Licences"
cp ../LICENSE "$APP/Contents/Resources/Licences/LICENSE.txt"

# No Apple account or certificate is needed for local sandbox verification.
# Store signing is a later, explicit operation using an Apple Distribution identity/profile.
codesign --force --sign - --entitlements Resources/BridgeyStore.entitlements "$APP"
codesign --verify --deep --strict "$APP"
python3 ../scripts/rr/check-macos-store.py "$APP"
mkdir -p .rrci-reports
"$APP/Contents/MacOS/BridgeyMacStore" --sandbox-smoke > .rrci-reports/store-sandbox.json
cat .rrci-reports/store-sandbox.json
"$APP/Contents/MacOS/BridgeyMacStore" --snapshot-dark > .rrci-reports/store-dark.png
"$APP/Contents/MacOS/BridgeyMacStore" --snapshot-light > .rrci-reports/store-light.png
ditto -c -k --keepParent "$APP" .rrci-reports/BridgeyStore.zip
python3 - <<'PYPROOF'
import zipfile
with zipfile.ZipFile('.rrci-reports/BridgeyStore.zip', 'a') as archive:
    for name in ['store-sandbox.json', 'store-dark.png', 'store-light.png']:
        archive.write('.rrci-reports/' + name, name)
PYPROOF
printf '%s\n' "$APP"
