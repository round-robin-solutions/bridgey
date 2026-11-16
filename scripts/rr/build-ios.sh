#!/bin/sh
# Builds and tests Bridgey by Round Robin for iOS and iPadOS on a Mac with Xcode. The RR CI `ios` lane runs it.
#
#  1. bridgey_core (rust/client, without its own DNS-SD) for iOS devices (arm64) and the simulator (arm64), and
#     ios/Frameworks/BridgeyCore.xcframework from the two.
#  2. The app, its Share extension and the tests, built once for the simulator.
#  3. On a throwaway iPhone simulator: the unit tests, then the UI tests, which pair with a scripted Bridgey peer
#     (rust/client/examples/peer.rs) running on this Mac and send text both ways, and take light and dark
#     screenshots.
#  4. On a throwaway iPad simulator: the screenshots again.
#  5. The app for a device (unsigned), to prove it builds and links for arm64.
#
# Everything lands in ios/out: screenshots/*.png, test-results/*.xcresult.zip, logs/*.log.
# Versions come from rr-edition.properties: BRIDGEY_VERSION_NAME and BRIDGEY_BUILD_NUMBER when a release sets them,
# else <next>-dev and the UTC build time (YYDDDHHMM).
#
# Usage: scripts/rr/build-ios.sh [--core-only] [--no-ui-tests] [--no-ipad] [--no-device]
# Env:   IOS_IPHONE_TYPE, IOS_IPAD_TYPE  simulator names to copy, e.g. "iPhone 17" (default: the plainest
#                                        iPhone and iPad Xcode set up for its newest iOS runtime)
#        IOS_KEEP_SIMULATORS=1           keep the throwaway simulators (for a look afterwards)
set -eu
. "$(dirname -- "$0")/common.sh"
. "$RR_ROOT/scripts/rr/rust-env.sh"
export PATH="$CARGO_HOME/bin:$PATH"

CORE_ONLY=0 UI_TESTS=1 IPAD=1 DEVICE=1
for arg in "$@"; do
  case "$arg" in
    --core-only) CORE_ONLY=1 ;;
    --no-ui-tests) UI_TESTS=0 ;;
    --no-ipad) IPAD=0 ;;
    --no-device) DEVICE=0 ;;
    *) die "unknown option $arg" ;;
  esac
done

IOS="$RR_ROOT/ios"
OUT="$IOS/out"
LOGS="$OUT/logs"
SHOTS="$OUT/screenshots"
RESULTS="$OUT/test-results"
BUILD="$IOS/build"
rm -rf "$OUT"
mkdir -p "$LOGS" "$SHOTS" "$RESULTS"

step() { printf '\n== %s\n' "$*"; }
# Runs a command with its output in logs/<name>.log as well; stops on failure with the log's tail.
logged() {
  name=$1; shift
  echo "> $*"
  if ! "$@" > "$LOGS/$name.log" 2>&1; then
    tail -n 80 "$LOGS/$name.log" >&2
    die "$1 failed (see ios/out/logs/$name.log)"
  fi
}

step "Edition and version"
NEXT=$(edition_value EDITION_NEXT_VERSION)
VERSION=${BRIDGEY_VERSION_NAME:-$NEXT-dev}
BUILD_NUMBER=${BRIDGEY_BUILD_NUMBER:-$(date -u +%y%j%H%M)}
# The store version is the plain numbers: 1.0.0-beta.2 is 1.0.0.
MARKETING=$(printf '%s' "$VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
echo "$(edition_value EDITION_DISPLAY_NAME) $VERSION ($MARKETING), build $BUILD_NUMBER"
VERSION_SETTINGS="MARKETING_VERSION=$MARKETING CURRENT_PROJECT_VERSION=$BUILD_NUMBER BRIDGEY_VERSION_NAME=$VERSION BRIDGEY_UPSTREAM_BASE=$(edition_value EDITION_UPSTREAM_BASE) BRIDGEY_BUNDLE_ID=$(edition_value EDITION_APP_ID)"

step "bridgey_core for iOS"
command -v cargo >/dev/null 2>&1 || /bin/sh "$RR_ROOT/scripts/rr/rust-toolchain.sh" mac
if command -v rustup >/dev/null 2>&1; then
  logged rustup-targets rustup target add aarch64-apple-ios aarch64-apple-ios-sim
fi
# Objects match the app's deployment target, so the linker has nothing to warn about.
export IPHONEOS_DEPLOYMENT_TARGET=17.0
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  logged "cargo-$target" cargo rustc -p bridgey-client --lib --crate-type staticlib --release --locked \
    --no-default-features --target "$target" --manifest-path "$RR_ROOT/rust/Cargo.toml"
done
TARGET_DIR="${CARGO_TARGET_DIR:-$RR_ROOT/rust/target}"
XCF="$IOS/Frameworks/BridgeyCore.xcframework"
rm -rf "$XCF"
mkdir -p "$IOS/Frameworks"
logged xcframework xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/release/libbridgey_core.a" \
  -library "$TARGET_DIR/aarch64-apple-ios-sim/release/libbridgey_core.a" \
  -output "$XCF"
echo "built $XCF"
[ "$CORE_ONLY" = 1 ] && exit 0

step "Scripted peer"
logged cargo-peer cargo build -p bridgey-client --example peer --release --locked --manifest-path "$RR_ROOT/rust/Cargo.toml"
PEER_BIN="$TARGET_DIR/release/examples/peer"

step "Build for testing"
# shellcheck disable=SC2086
logged build-for-testing xcodebuild build-for-testing -project "$IOS/Bridgey.xcodeproj" -scheme Bridgey \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$BUILD" $VERSION_SETTINGS

# Throwaway simulators: nothing from another run or another job, and nothing left behind.
SIMS=""
PEER_PID=""
cleanup() {
  [ -n "$PEER_PID" ] && kill "$PEER_PID" 2>/dev/null || true
  if [ "${IOS_KEEP_SIMULATORS:-0}" != 1 ]; then
    for sim in $SIMS; do
      xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
      xcrun simctl delete "$sim" >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT INT TERM

# Prints "<device type id> <runtime id>" for a simulator to copy: the one named $2 if given, else a standard model
# (iPhone <n>; iPad Pro 11-inch, then iPad Air 11-inch) on the newest iOS runtime that has one, else any device
# whose name starts with $1. The device type list itself is in no useful order.
pick_simulator() {
  xcrun simctl list -j devices available runtimes | python3 -c '
import json, re, sys
prefix, wanted = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
runtimes = [r for r in data["runtimes"] if r.get("isAvailable") and r.get("platform", r.get("name", "")).startswith("iOS")]
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")], reverse=True)
if wanted:
    tests = [lambda n: n == wanted]
elif prefix == "iPhone":
    tests = [lambda n: re.fullmatch(r"iPhone \d+", n), lambda n: n.startswith("iPhone ")]
else:
    tests = [lambda n: n.startswith("iPad Pro 11-inch"), lambda n: n.startswith("iPad Air 11-inch"), lambda n: n.startswith("iPad")]
for test in tests:
    for runtime in runtimes:
        matches = sorted((d for d in data["devices"].get(runtime["identifier"], []) if test(d["name"])), key=lambda d: d["name"], reverse=True)
        if matches:
            print(matches[0]["deviceTypeIdentifier"], runtime["identifier"])
            sys.exit(0)
sys.exit("no " + (wanted or prefix) + " simulator set up for any iOS runtime")
' "$1" "${2:-}"
}

# Creates a throwaway simulator and prints its ID. Run it in the main shell, then add the ID to SIMS there.
new_simulator() {
  picked=$(pick_simulator "$1" "${2:-}") || die "no simulator to copy"
  # shellcheck disable=SC2086
  xcrun simctl create "bridgey-ci-$$-$(date +%s)" $picked
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# Exports a result bundle's screenshots as <name>.png.
export_shots() {
  bundle=$1
  tmp="$OUT/attachments-$(basename "$bundle" .xcresult)"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$tmp" >> "$LOGS/attachments.log" 2>&1 || {
    echo "warning: could not export attachments from $bundle" >&2
    return 0
  }
  python3 - "$tmp" "$SHOTS" <<'PY'
import json, os, re, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(src, "manifest.json")))
count = 0
for test in manifest:
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        # "iphone-light-home_0_5D3C....png" -> "iphone-light-home.png"
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(\.\w+)$", r"\1", name)
        if name.lower().endswith(".png"):
            shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(dst, name))
            count += 1
print(f"{count} screenshots")
PY
  rm -rf "$tmp"
}

run_tests() {
  label=$1 sim=$2; shift 2
  bundle="$RESULTS/$label.xcresult"
  status=0
  echo "> xcodebuild test-without-building ($label)"
  xcodebuild test-without-building -project "$IOS/Bridgey.xcodeproj" -scheme Bridgey -destination "id=$sim" \
    -derivedDataPath "$BUILD" -resultBundlePath "$bundle" "$@" > "$LOGS/test-$label.log" 2>&1 || status=$?
  # A new simulator's first UI test can stall the test runner while it loads accessibility, before any test
  # runs (XCTWaiter handleStalledWait). That one case is tried once more, and said so; test failures are not.
  if [ "$status" != 0 ] && grep -q "test runner crashed while preparing to run tests" "$LOGS/test-$label.log"; then
    echo "note: the test runner crashed before any test ran ($label); trying once more"
    mv "$LOGS/test-$label.log" "$LOGS/test-$label-runner-crash.log"
    rm -rf "$bundle"
    status=0
    xcodebuild test-without-building -project "$IOS/Bridgey.xcodeproj" -scheme Bridgey -destination "id=$sim" \
      -derivedDataPath "$BUILD" -resultBundlePath "$bundle" "$@" > "$LOGS/test-$label.log" 2>&1 || status=$?
  fi
  grep -E '^(Test Suite|Test Case .*(passed|failed|skipped)|.*error:|\*\* TEST)' "$LOGS/test-$label.log" | tail -n 60 || true
  [ -d "$bundle" ] && export_shots "$bundle"
  [ -d "$bundle" ] && (cd "$RESULTS" && zip -qry "$label.xcresult.zip" "$label.xcresult" && rm -rf "$label.xcresult")
  return $status
}

FAILED=""
step "iPhone: unit tests"
IPHONE=$(new_simulator "iPhone" "${IOS_IPHONE_TYPE:-}")
SIMS="$SIMS $IPHONE"
xcrun simctl list devices | grep "$IPHONE" | sed 's/^ */simulator: /'
xcrun simctl boot "$IPHONE"
# Fully booted (first-boot setup done) before anything is installed.
xcrun simctl bootstatus "$IPHONE" -b > /dev/null
run_tests iphone-unit "$IPHONE" -only-testing:BridgeyTests || FAILED="$FAILED iphone-unit"

if [ "$UI_TESTS" = 1 ]; then
  step "iPhone: UI tests with a scripted peer"
  PEER_PORT=$(free_port)
  APP_PORT=$(free_port)
  "$PEER_BIN" --name "Test Mac" --port "$PEER_PORT" --allow --send "Hello from the peer" --seconds 1800 > "$LOGS/peer.log" 2>&1 &
  PEER_PID=$!
  TEST_RUNNER_BRIDGEY_PEER="127.0.0.1:$PEER_PORT" TEST_RUNNER_BRIDGEY_APP_PORT="$APP_PORT" \
    TEST_RUNNER_BRIDGEY_PEER_NAME="Test Mac" TEST_RUNNER_BRIDGEY_PEER_TEXT="Hello from the peer" \
    run_tests iphone-ui "$IPHONE" -only-testing:BridgeyUITests || FAILED="$FAILED iphone-ui"
  kill "$PEER_PID" 2>/dev/null || true
  PEER_PID=""
  # The peer saw the app's text: the end-to-end check from the other side.
  if grep -q '"event":"clipboard".*Hello from iOS' "$LOGS/peer.log"; then
    echo "peer received: Hello from iOS"
  elif ! echo "$FAILED" | grep -q iphone-ui; then
    echo "error: the peer never received the app's text" >&2
    FAILED="$FAILED peer"
  fi

  if [ "$IPAD" = 1 ]; then
    step "iPad: screenshots"
    IPAD_SIM=$(new_simulator "iPad" "${IOS_IPAD_TYPE:-}")
    SIMS="$SIMS $IPAD_SIM"
    xcrun simctl list devices | grep "$IPAD_SIM" | sed 's/^ */simulator: /'
    xcrun simctl boot "$IPAD_SIM"
    xcrun simctl bootstatus "$IPAD_SIM" -b > /dev/null
    run_tests ipad-ui "$IPAD_SIM" -only-testing:BridgeyUITests/ScreenshotTests || FAILED="$FAILED ipad-ui"
  fi
fi

if [ "$DEVICE" = 1 ]; then
  step "Device build (arm64, unsigned)"
  # shellcheck disable=SC2086
  logged build-device xcodebuild build -project "$IOS/Bridgey.xcodeproj" -scheme Bridgey -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO $VERSION_SETTINGS
  APP="$BUILD/Build/Products/Release-iphoneos/Bridgey.app"
  [ -d "$APP/PlugIns/BridgeyShare.appex" ] || die "the Share extension is missing from the device build"
  /usr/libexec/PlistBuddy -c "Print :BridgeyVersionName" "$APP/Info.plist"
  ls -la "$APP/Bridgey" | awk '{print "app binary:", $5, "bytes"}'
fi

ls "$SHOTS" 2>/dev/null | sed 's/^/screenshot: /'
[ -z "$FAILED" ] || die "failed:$FAILED"
echo "iOS build and tests passed"
