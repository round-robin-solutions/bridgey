#!/bin/sh
# Release-build smoke test for Android: the minified release APK (R8, shrinking, the release
# ProGuard rules) signed with a throwaway key, launched on emulators. It catches what unit tests
# and debug builds cannot, such as keep rules that break in R8 full mode (0.9.0-rr.1-beta.1 crashed
# in InitializationProvider before any Bridgey code ran).
#
# For each API level: install, launch the launcher activity, wait 10 s, then fail if the crash
# buffer has anything for the app or the process is gone. Then, best effort, tap "Get started
# quickly" and open Settings, and check again.
#
# Usage: scripts/rr/release-smoke-android.sh [api ...]   (default: 35 30)
# Needs an Android SDK (ANDROID_HOME) with sdkmanager, JDK 17 and /dev/kvm: GitHub's Ubuntu
# runners have all three. Nothing secret is used.
set -eu
. "$(dirname -- "$0")/common.sh"

[ $# -gt 0 ] || set -- 35 30
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
TOOLS=$(ls -d "$SDK"/cmdline-tools/*/bin 2>/dev/null | sort -V | tail -n 1)
[ -n "$TOOLS" ] && [ -x "$TOOLS/sdkmanager" ] || die "sdkmanager not found under $SDK/cmdline-tools"
export PATH="$SDK/platform-tools:$SDK/emulator:$TOOLS:$PATH"
WORK=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bridgey-release-smoke
rm -rf "$WORK"
mkdir -p "$WORK"
APP_ID=$(edition_value EDITION_APP_ID)
STARTED=$(date +%s)

# KVM: GitHub's runners have the device but not the permission.
if [ ! -w /dev/kvm ]; then
  if [ -e /dev/kvm ] && command -v sudo >/dev/null 2>&1; then
    echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
    sudo udevadm control --reload-rules && sudo udevadm trigger --name-match=kvm
  fi
  [ -w /dev/kvm ] || die "/dev/kvm is not available; the emulator needs hardware acceleration"
fi

echo "== building the minified release APK with a throwaway key"
KEYSTORE="$WORK/throwaway.jks"
keytool -genkeypair -keystore "$KEYSTORE" -storepass smoketest -keypass smoketest -alias smoke \
  -keyalg RSA -keysize 2048 -validity 2 -dname "CN=Bridgey release smoke" >/dev/null 2>&1
(
  cd "$RR_ROOT/android"
  chmod +x gradlew
  BRIDGEY_ANDROID_KEYSTORE="$KEYSTORE" BRIDGEY_ANDROID_STORE_PASSWORD=smoketest BRIDGEY_ANDROID_KEY_ALIAS=smoke \
    BRIDGEY_ANDROID_KEY_PASSWORD=smoketest BRIDGEY_VERSION_NAME="$(edition_value EDITION_NEXT_VERSION)-smoke" BRIDGEY_BUILD_NUMBER=1 \
    ./gradlew --no-daemon --console=plain :app:assembleRelease
)
APK="$RR_ROOT/android/app/build/outputs/apk/release/app-release.apk"
[ -f "$APK" ] || die "the release APK was not produced"
BUILT=$(date +%s)
echo "::rrci-metric build_seconds $((BUILT - STARTED))"

BUILD_TOOLS=""
for dir in $(ls -d "$SDK"/build-tools/* | sort -V -r); do
  [ -x "$dir/aapt2" ] && { BUILD_TOOLS=$dir; break; }
done
ACTIVITY=$("$BUILD_TOOLS/aapt2" dump badging "$APK" | sed -n "s/^launchable-activity: name='\([^']*\)'.*/\1/p" | head -n 1)
[ -n "$ACTIVITY" ] || die "no launchable activity in the APK"

yes | sdkmanager --licenses >/dev/null 2>&1 || true

FAILED=""
smoke() {
  api=$1
  image="system-images;android-$api;google_apis;x86_64"
  echo "== API $api: $image"
  sdkmanager --install "$image" "platforms;android-$api" emulator platform-tools >/dev/null
  echo no | avdmanager create avd -n "smoke$api" -k "$image" -d pixel_6 --force >/dev/null
  emulator -avd "smoke$api" -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect \
    -camera-back none -camera-front none > "$WORK/emulator-$api.log" 2>&1 &
  emu=$!
  adb wait-for-device
  t=0
  until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
    t=$((t + 5)); [ $t -le 600 ] || { kill $emu; die "API $api emulator did not boot in 10 minutes"; }
    sleep 5
  done
  booted=$(date +%s)
  adb shell settings put global window_animation_scale 0
  adb shell settings put global transition_animation_scale 0
  adb shell settings put global animator_duration_scale 0
  adb install -r -g "$APK" >/dev/null
  adb logcat -b all -c
  adb shell am start -W -n "$APP_ID/$ACTIVITY" | tr -d '\r' | grep -E "Status|LaunchState|TotalTime" || true
  sleep 10
  verdict=ok
  check "API $api launch" || verdict=failed
  if [ $verdict = ok ]; then
    # Best effort: the first-run choice, then Settings. Missing text is noted, not a failure.
    if tap_text "Get started quickly"; then
      sleep 4; check "API $api after Get started quickly" || verdict=failed
    else
      echo "note: API $api: 'Get started quickly' not on screen"
    fi
  fi
  if [ $verdict = ok ]; then
    if tap_desc_or_text "Settings"; then
      sleep 4; check "API $api after Settings" || verdict=failed
    else
      echo "note: API $api: no Settings control on screen"
    fi
  fi
  echo "::rrci-metric api${api}_seconds $(($(date +%s) - booted))"
  adb emu kill >/dev/null 2>&1 || true
  wait $emu 2>/dev/null || true
  [ $verdict = ok ] || FAILED="$FAILED $api"
}

check() {
  crashes=$(adb logcat -b crash -d 2>/dev/null | tr -d '\r' | grep -v '^--------- beginning of' || true)
  pid=$(adb shell pidof "$APP_ID" 2>/dev/null | tr -d '\r')
  if [ -n "$crashes" ]; then
    echo "FAIL: $1: the crash buffer is not empty:"
    printf '%s\n' "$crashes" | head -n 60
    return 1
  fi
  if [ -z "$pid" ]; then
    echo "FAIL: $1: $APP_ID is not running"
    adb logcat -d -t 200 2>/dev/null | tr -d '\r' | grep -E "AndroidRuntime|$APP_ID|ActivityManager" | tail -n 40
    return 1
  fi
  echo "ok: $1 (pid $pid, crash buffer empty)"
}

# Taps the centre of the first UI node whose text (or content description) is $1.
tap_node() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || return 1
  adb pull /sdcard/ui.xml "$WORK/ui.xml" >/dev/null 2>&1 || return 1
  xy=$(python3 - "$WORK/ui.xml" "$1" "$2" <<'PY'
import re, sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for node in root.iter('node'):
    if any(node.get(a, '') == sys.argv[3] for a in sys.argv[2].split(',')):
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds', '')))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PY
)
  [ -n "$xy" ] || return 1
  adb shell input tap $xy
}
tap_text() { tap_node text "$1"; }
tap_desc_or_text() { tap_node content-desc,text "$1"; }

for api in "$@"; do smoke "$api"; done
echo "::rrci-metric total_seconds $(($(date +%s) - STARTED))"
[ -z "$FAILED" ] || die "release smoke failed on API$FAILED"
echo "release smoke passed on API $*"
