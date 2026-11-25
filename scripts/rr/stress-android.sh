#!/bin/sh
# Stress tests against the Android app (docs/testing-stress.md). The stress build (the `stress` build type: minified
# like release, app ID <edition id>.stress, a control receiver only the shell can reach) runs on an emulator or a test
# device; the scripted peer (rust/client/examples/stress.rs) plays the Mac, reaches the app through a forwarded port and
# runs the scenarios. STRESS_FORWARD picks how: `redir` (the emulator's own port redirect, through QEMU's network, so a
# 1 GiB send cannot stall adb's one connection, which also carries the log and the control broadcasts; the default on
# an emulator), or `adb` (`adb forward`, the default on a real device). The JSON report, the peer's event log and the app's log land in the output folder.
#
# Usage, on a host with adb, a running emulator and Rust:
#   scripts/rr/stress-android.sh [--apk <stress apk>] [--serial <adb serial>] [--out <dir>] [--keep] [stress run options ...]
#   e.g. scripts/rr/stress-android.sh --apk app-stress.apk --scenarios quick --mid 256M --big 1G
# Without --apk it builds one (./gradlew :app:assembleStress). It never boots, wipes or reconfigures the emulator:
# whoever runs it brings one up (and holds its lock). adb is used to install and remove the stress build, forward
# its port, start it, stop it, send its control broadcasts and read its log. Other Bridgey builds on the device hold
# the same port, so they are stopped (force-stop; their data is untouched) for the run.
# `stress-android.sh control <verb> ...` is the app control the peer calls; it reads the STRESS_* variables set below.
set -eu

ACTIVITY=dev.bridgey.android.MainActivity
RECEIVER=dev.bridgey.android.stress.StressControlReceiver

if [ "${1:-}" = control ]; then
  shift
  : "${STRESS_APP_ID:?}" "${STRESS_ADB:?}"
  adb() { "$STRESS_ADB" "$@" </dev/null; }
  verb=$1
  shift
  # One control broadcast; prints its JSON answer (the result data), or an error.
  broadcast() {
    cmd=$1
    shift
    adb shell am broadcast -n "$STRESS_APP_ID/$RECEIVER" -a "$STRESS_APP_ID.STRESS" --es cmd "$cmd" "$@" 2>&1 | tr -d '\r' |
      sed -n 's/^Broadcast completed: result=[-0-9]*, data="\(.*\)"$/\1/p' | tail -n 1 | grep . ||
      echo '{"ok":false,"error":"no answer from the stress build"}'
  }
  normalize() {
    python3 -I -c '
import json, sys
verb, names = sys.argv[1], sys.argv[2:]
s = json.loads(sys.stdin.read())
if not s.get("ok"):
    print(json.dumps(s)); sys.exit(0)
if verb == "status":
    active = sum(1 for t in s["transfers"] if t["active"] and t["kind"] == "FILE")
    print(json.dumps({"ok": True, "active": active, "free": s["freeBytes"], "sessions": len(s["connections"]), "writing": s["writing"], "errors": s["errors"]}))
elif verb == "partials":
    print(json.dumps({"ok": True, "partials": [{"name": r["name"], "size": r["size"]} for r in s["received"] if r["pending"]]}))
else:
    hashes, files = s["hashes"], []
    for n in names:
        h = hashes.get(n, {})
        files.append({"name": n, "size": h["size"], "sha256": h["sha256"]} if h.get("state") == "done" else {"name": n, "missing": True})
    print(json.dumps({"ok": True, "files": files}))
' "$@"
  }
  case $verb in
    pair-prepare) broadcast files-on >/dev/null && broadcast allow ;;
    pair-confirm) broadcast confirm ;;
    send) broadcast send --esa specs "$(printf '%s,' "$@" | sed 's/,$//')" ;;
    cancel) broadcast cancel ;;
    kill)
      adb shell am force-stop "$STRESS_APP_ID"
      echo '{"ok":true}' ;;
    start)
      adb shell am start -n "$STRESS_APP_ID/$ACTIVITY" >/dev/null
      i=0
      until broadcast status | grep -q '"ok":true'; do
        sleep 1; i=$((i + 1))
        [ $i -lt 60 ] || { echo '{"ok":false,"error":"the app did not start in 60 s"}'; exit 0; }
      done
      echo '{"ok":true}' ;;
    status|partials) broadcast status | normalize "$verb" ;;
    received)
      broadcast hash --esa names "$(printf '%s,' "$@" | sed 's/,$//')" >/dev/null
      i=0
      while :; do
        answer=$(broadcast status)
        printf '%s' "$answer" | python3 -I -c 'import json,sys; s=json.load(sys.stdin); sys.exit(0 if s.get("ok") and all(h.get("state") != "running" for h in s["hashes"].values()) else 1)' && break
        sleep 1; i=$((i + 1))
        [ $i -lt 600 ] || break
      done
      printf '%s' "$answer" | normalize received "$@" ;;
    clean) broadcast clean ;;
    *) echo '{"ok":false,"error":"unknown verb"}' ;;
  esac
  exit 0
fi

. "$(dirname -- "$0")/common.sh"
APK=""
SERIAL=${ANDROID_SERIAL:-}
KEEP=0
WORK=${STRESS_WORK:-${RUNNER_TEMP:-/tmp}/bridgey-stress-android}
OUT=""
FORWARD=${STRESS_FORWARD_PORT:-42496}
FORWARD_MODE=${STRESS_FORWARD:-auto}
while [ $# -gt 0 ]; do
  case $1 in
    --apk) APK=$2; shift 2 ;;
    --serial) SERIAL=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) break ;;
  esac
done
OUT=${OUT:-$WORK/out}
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
ADB=$(command -v adb || echo "$SDK/platform-tools/adb")
[ -x "$ADB" ] || die "adb not found"
[ -n "$SERIAL" ] || SERIAL=$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')
[ -n "$SERIAL" ] || die "no device or emulator on adb"
export ANDROID_SERIAL="$SERIAL"
# Two nightly runs stalled adb itself when the app sent 1 GiB through `adb forward` (log and broadcasts went quiet,
# the device came back later), so an emulator gets its port through the emulator instead.
if [ "$FORWARD_MODE" = auto ]; then
  case $SERIAL in emulator-*) FORWARD_MODE=redir ;; *) FORWARD_MODE=adb ;; esac
fi
case $FORWARD_MODE in redir|adb) ;; *) die "STRESS_FORWARD must be redir, adb or auto (got $FORWARD_MODE)" ;; esac
APP_ID="$(edition_value EDITION_APP_ID).stress"
REAL_ID=$(edition_value EDITION_APP_ID)
LOGCAT_PID=""
PEER_PID=""

cleanup() {
  [ -n "$PEER_PID" ] && kill "$PEER_PID" 2>/dev/null
  [ -n "$LOGCAT_PID" ] && kill "$LOGCAT_PID" 2>/dev/null
  if [ "$FORWARD_MODE" = redir ]; then
    "$ADB" emu redir del "tcp:$FORWARD" </dev/null >/dev/null 2>&1 || true
  else
    "$ADB" forward --remove "tcp:$FORWARD" </dev/null 2>/dev/null || true
  fi
  [ $KEEP = 1 ] && { echo "kept $WORK and $APP_ID on $SERIAL"; return 0; }
  STRESS_APP_ID=$APP_ID STRESS_ADB=$ADB sh "$SELF" control clean >/dev/null 2>&1 || true
  "$ADB" uninstall "$APP_ID" </dev/null >/dev/null 2>&1 || true
  rm -rf "$WORK/src" "$WORK/received" "$WORK/state"
}
SELF="$RR_ROOT/scripts/rr/stress-android.sh"
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$WORK" "$OUT"
if [ -z "$APK" ]; then
  echo "== building the stress APK"
  . "$RR_ROOT/scripts/rr/rust-env.sh"
  (cd "$RR_ROOT/android" && ./gradlew --console=plain :app:assembleStress)
  APK="$RR_ROOT/android/app/build/outputs/apk/stress/app-stress.apk"
fi
[ -f "$APK" ] || die "no APK at $APK"
if [ ! -x "$WORK/peer/stress" ]; then
  echo "== building the scripted peer"
  . "$RR_ROOT/scripts/rr/rust-env.sh"
  cargo build --release --locked -p bridgey-client --example stress --manifest-path "$RR_ROOT/rust/Cargo.toml"
  mkdir -p "$WORK/peer"
  cp "$RR_ROOT/rust/target/release/examples/stress" "$WORK/peer/stress"
fi

echo "== installing $APP_ID on $SERIAL"
"$ADB" install -r -g "$APK" </dev/null >/dev/null
# Any other Bridgey build listens on the same port inside the device: stopped for the run, its data untouched.
for other in $("$ADB" shell pm list packages "$REAL_ID" </dev/null | tr -d '\r' | sed -n 's/^package://p'); do
  [ "$other" = "$APP_ID" ] && continue
  "$ADB" shell am force-stop "$other" </dev/null
  echo "stopped $other for the run (force-stop only)"
done
if [ "$FORWARD_MODE" = redir ]; then
  "$ADB" emu redir del "tcp:$FORWARD" </dev/null >/dev/null 2>&1 || true
  "$ADB" emu redir add "tcp:$FORWARD:42458" </dev/null | tr -d '\r' | grep -q '^OK' || die "the emulator would not redirect port $FORWARD"
else
  "$ADB" forward "tcp:$FORWARD" tcp:42458 </dev/null >/dev/null
fi
echo "== port $FORWARD reaches the app through $FORWARD_MODE"
"$ADB" logcat -c </dev/null || true
export STRESS_APP_ID="$APP_ID" STRESS_ADB="$ADB"
sh "$SELF" control start | grep -q '"ok":true' || die "the stress build did not start"
PID=$("$ADB" shell pidof "$APP_ID" </dev/null | tr -d '\r')
nohup "$ADB" logcat -v threadtime -s Bridgey:V AndroidRuntime:E ActivityManager:I > "$OUT/app.log" 2>&1 </dev/null &
LOGCAT_PID=$!
echo "== running the scenarios (app pid $PID)"
rm -f "$WORK/events.jsonl"
set +e
"$WORK/peer/stress" run --app "sh $SELF control" --target "127.0.0.1:$FORWARD" --work "$WORK" --report "$OUT/report.json" \
  --peer-platform macos "$@" &
PEER_PID=$!
wait "$PEER_PID"
STATUS=$?
PEER_PID=""
set -e
cp "$WORK/events.jsonl" "$OUT/events.jsonl" 2>/dev/null || true
"$ADB" logcat -b crash -d </dev/null > "$OUT/crash.log" 2>/dev/null || true
[ -s "$OUT/crash.log" ] && echo "the crash buffer is not empty: $OUT/crash.log"
echo "report: $OUT/report.json"
exit $STATUS
