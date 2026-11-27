#!/bin/sh
# The upgrade acceptance and soak in one CI job (docs/acceptance-1.0.md), for RR CI's accept-* and soak-* tasks.
#
#   scripts/rr/acceptance-ci.sh android|macos --out <dir> [--soak-minutes 20] [--no-accept] [--base <tag>]
#                               [--apk <stress apk of this revision>] [--app <debug app of this revision>]
#
# Accept: builds the older build from --base (default: the newest v* release tag before this revision) with this
# revision's test hooks laid over it (the Android stress source set; on the Mac the test instance's private pasteboard,
# for releases from before it), then runs the acceptance driver: a fresh install of the older build, set up and
# upgraded in place mid-file to this revision. Soak: --soak-minutes of mixed traffic against this revision (0 skips it).
# Android needs a running emulator with its lock held, as stress-android.sh; the Mac needs Xcode and Rust. Every
# file a run makes goes under --out (reports, snapshots, samples, graphs, logs); the job fails when any part fails.
set -eu
. "$(dirname -- "$0")/common.sh"
PLATFORM=${1:-}
[ "$PLATFORM" = android ] || [ "$PLATFORM" = macos ] || die "usage: acceptance-ci.sh android|macos --out <dir> [options]"
shift
OUT=""
SOAK=20
ACCEPT=1
BASE=""
APK=""
APP=""
while [ $# -gt 0 ]; do
  case $1 in
    --out) OUT=$2; shift 2 ;;
    --soak-minutes) SOAK=$2; shift 2 ;;
    --no-accept) ACCEPT=0; shift ;;
    --base) BASE=$2; shift 2 ;;
    --apk) APK=$2; shift 2 ;;
    --app) APP=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
[ -n "$OUT" ] || die "--out is needed"
mkdir -p "$OUT"
TMP=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bridgey-acceptance-ci
rm -rf "$TMP"
mkdir -p "$TMP"
. "$RR_ROOT/scripts/rr/rust-env.sh"

echo "== the scripted peer"
cargo build --release --locked -p bridgey-client --example stress --manifest-path "$RR_ROOT/rust/Cargo.toml"
PEER="$TMP/stress"
cp "$RR_ROOT/rust/target/release/examples/stress" "$PEER"

build_android() { # <tree> <out apk>
  (cd "$1/android" && chmod +x gradlew && ./gradlew --no-daemon --console=plain :app:assembleStress)
  cp "$1/android/app/build/outputs/apk/stress/app-stress.apk" "$2"
}
build_mac() { # <tree> <out app>
  (cd "$1/macos" && ./build-app.sh)
  ditto "$1/macos/.build/debug/$(edition_value EDITION_MAC_APP_NAME).app" "$2"
}

if [ $ACCEPT = 1 ]; then
  if [ -z "$BASE" ]; then
    # Shallow CI checkouts carry no tags: fetch the release tags first.
    git -C "$RR_ROOT" fetch --quiet --tags --force origin 'refs/tags/v*:refs/tags/v*' 2>/dev/null || true
    BASE=$(git -C "$RR_ROOT" tag --merged HEAD --list 'v[0-9]*' --sort=-creatordate | while read -r t; do
      [ "$(git -C "$RR_ROOT" rev-list -n 1 "$t")" = "$(git -C "$RR_ROOT" rev-parse HEAD)" ] || { echo "$t"; break; }
    done)
  fi
  [ -n "$BASE" ] || die "no release tag before this revision (pass --base)"
  echo "== the older build: $BASE"
  git -C "$RR_ROOT" fetch --quiet origin "refs/tags/$BASE:refs/tags/$BASE" 2>/dev/null || true
  git -C "$RR_ROOT" worktree add --detach "$TMP/base" "$BASE" >/dev/null
  trap 'git -C "$RR_ROOT" worktree remove --force "$TMP/base" 2>/dev/null || true' EXIT
  echo "$BASE" > "$OUT/base.txt"
fi

STATUS=0
if [ "$PLATFORM" = android ]; then
  if [ -z "$APK" ]; then
    APK="$TMP/new.apk"
    build_android "$RR_ROOT" "$APK"
  fi
  if [ $ACCEPT = 1 ]; then
    # This revision's control receiver over the older app: the older app's code, this revision's test commands.
    rm -rf "$TMP/base/android/app/src/stress"
    cp -R "$RR_ROOT/android/app/src/stress" "$TMP/base/android/app/src/stress"
    build_android "$TMP/base" "$TMP/base.apk"
    STRESS_WORK="$TMP/accept" sh "$RR_ROOT/scripts/rr/stress-android.sh" --driver accept --apk "$TMP/base.apk" --new-apk "$APK" \
      --peer "$PEER" --out "$OUT/accept" --mid 192M || STATUS=1
  fi
  if [ "$SOAK" -gt 0 ]; then
    STRESS_WORK="$TMP/soak" sh "$RR_ROOT/scripts/rr/stress-android.sh" --driver soak --apk "$APK" --peer "$PEER" --out "$OUT/soak" \
      --minutes "$SOAK" --max-file 64M || STATUS=1
  fi
else
  [ "$(uname -s)" = Darwin ] || die "macos runs on a Mac"
  if [ -z "$APP" ]; then
    APP="$TMP/new/Bridgey.app"
    mkdir -p "$TMP/new"
    build_mac "$RR_ROOT" "$APP"
  fi
  if [ $ACCEPT = 1 ]; then
    if ! grep -q 'clipboard-text' "$TMP/base/macos/Sources/BridgeyMac/Pairing.swift"; then
      # Releases from before the test instance had a pasteboard of its own (1.0 Beta 12 and older).
      git -C "$TMP/base" apply --3way "$RR_ROOT/scripts/rr/testdata/acceptance/mac-test-pasteboard.patch"
    fi
    mkdir -p "$TMP/old"
    build_mac "$TMP/base" "$TMP/old/Bridgey.app"
    STRESS_MAC_BID=in.roundrobin.bridgey.test.accept STRESS_MAC_PORT=42498 STRESS_MAC_SERVICE=_bridgeyac._tcp STRESS_WORK="$TMP/accept" \
      sh "$RR_ROOT/scripts/rr/stress-mac.sh" --driver accept --app "$TMP/old/Bridgey.app" --new-app "$APP" --peer "$PEER" \
      --out "$OUT/accept" --proxy-port 42493 --mid 192M || STATUS=1
  fi
  if [ "$SOAK" -gt 0 ]; then
    STRESS_MAC_BID=in.roundrobin.bridgey.test.soak STRESS_MAC_PORT=42495 STRESS_MAC_SERVICE=_bridgeysk._tcp STRESS_WORK="$TMP/soak" \
      sh "$RR_ROOT/scripts/rr/stress-mac.sh" --driver soak --app "$APP" --peer "$PEER" --out "$OUT/soak" --proxy-port 42492 \
      --minutes "$SOAK" --max-file 256M || STATUS=1
  fi
fi
echo "== acceptance $PLATFORM: $([ $STATUS = 0 ] && echo passed || echo FAILED) (files in $OUT)"
exit $STATUS
