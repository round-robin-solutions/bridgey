#!/bin/sh
# Stress tests against the Mac app (docs/testing-stress.md). The scripted peer (rust/client/examples/stress.rs) pairs
# with a throwaway test instance of the debug app over loopback TCP and runs the scenarios; the JSON report and the
# peer's event log land in the output folder.
#
# The instance has its own bundle ID (in.roundrobin.bridgey.test.stress), support folder, Keychain items, preferences,
# port, Bonjour type and receive folder, no update feed and no relays, so an installed Bridgey, its data and its
# pairings are never touched. Everything it made is deleted at the end, unless --keep.
#
# Usage, on a Mac:
#   scripts/rr/stress-mac.sh [--app <debug .app>] [--out <dir>] [--keep] [--history <n>] [stress run options ...]
#   e.g. scripts/rr/stress-mac.sh --scenarios quick --mid 256M --big 1G
# --history starts the instance with <n> transfer history entries (at most 2,000, the app's limit) over the last 30
# days, so a run measures a Mac that has moved a lot of files.
# Without --app it builds the debug app (macos/build-app.sh) and the peer while holding /tmp/app-build-mac.lock, a
# directory taken with mkdir and released with rmdir (never a file). The peer's options are stress.rs's (`run`).
# `stress-mac.sh control <verb> ...` is the app control the peer calls; it reads the STRESS_* variables set below.
set -eu

BID=in.roundrobin.bridgey.test.stress
PORT=${STRESS_MAC_PORT:-42497}
SERVICE=_bridgeyst._tcp

if [ "${1:-}" = control ]; then
  shift
  : "${STRESS_APP:?}" "${STRESS_RECV:?}" "${STRESS_APPSRC:?}" "${STRESS_BIN:?}"
  CTL="/tmp/$BID-control"
  verb=$1
  shift
  # A command file, written whole, once the app has read the one before (it reads them five times a second). It
  # returns once the app has taken it, so a cancel cannot land on the next scenario's first file.
  command_file() {
    i=0
    while [ -e "$CTL/$1" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    printf '%s' "$2" > "$CTL/.$1.tmp"
    mv "$CTL/.$1.tmp" "$CTL/$1"
    i=0
    while [ -e "$CTL/$1" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ ! -e "$CTL/$1" ] || { echo '{"ok":false,"error":"the app did not take the command in 5 s"}'; exit 0; }
  }
  case $verb in
    pair-prepare)
      : > "$CTL/autoconfirm"
      command_file allow ""
      echo '{"ok":true}' ;;
    pair-confirm) echo '{"ok":true}' ;;
    send)
      paths=""
      for spec in "$@"; do
        name=${spec%%:*}; rest=${spec#*:}; size=${rest%%:*}; seed=${rest#*:}
        case $name in stress-*) ;; *) echo '{"ok":false,"error":"bad name"}'; exit 0 ;; esac
        file="$STRESS_APPSRC/$name"
        if [ "$(stat -f %z "$file" 2>/dev/null || echo -1)" != "$size" ]; then
          "$STRESS_BIN" gen "$file" "$size" "$seed" >/dev/null
        fi
        paths="$paths$file
"
      done
      command_file send-file "$paths"
      echo '{"ok":true}' ;;
    cancel)
      command_file cancel-files ""
      echo '{"ok":true}' ;;
    kill)
      pkill -9 -f "$STRESS_APP/Contents/MacOS/BridgeyMac" || true
      i=0
      while pgrep -f "$STRESS_APP/Contents/MacOS/BridgeyMac" >/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
      echo '{"ok":true}' ;;
    start)
      rm -f "$CTL/status.json"
      open -n -g "$STRESS_APP"
      i=0
      until [ -s "$CTL/status.json" ] && nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
        sleep 0.5; i=$((i + 1))
        [ $i -lt 120 ] || { echo '{"ok":false,"error":"the app did not start listening in 60 s"}'; exit 0; }
      done
      echo '{"ok":true}' ;;
    status|received|partials)
      python3 -I - "$verb" "$CTL/status.json" "$STRESS_RECV" "$@" <<'PY'
import hashlib, json, os, sys
verb, status_path, recv, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
if verb == "status":
    status = json.load(open(status_path))
    vfs = os.statvfs(recv)
    active = sum(1 for t in status.get("transfers", []) if t.get("active"))
    print(json.dumps({"ok": True, "active": active, "free": vfs.f_bavail * vfs.f_frsize, "sessions": len(status.get("sessions", []))}))
elif verb == "partials":
    parts = [n for n in os.listdir(recv) if n.endswith(".bridgey-part") or n.startswith(".bridgey-")]
    print(json.dumps({"ok": True, "partials": [{"name": n, "size": os.path.getsize(os.path.join(recv, n))} for n in sorted(parts)]}))
else:
    files = []
    for name in names:
        path = os.path.join(recv, name)
        if not os.path.isfile(path):
            files.append({"name": name, "missing": True})
            continue
        digest = hashlib.sha256()
        with open(path, "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                digest.update(block)
        files.append({"name": name, "size": os.path.getsize(path), "sha256": digest.hexdigest()})
    print(json.dumps({"ok": True, "files": files}))
PY
      ;;
    clean)
      find "$STRESS_RECV" -mindepth 1 -maxdepth 1 \( -name 'stress-*' -o -name '*.bridgey-part' \) -delete
      find "$STRESS_APPSRC" -mindepth 1 -maxdepth 1 -name 'stress-*' -delete
      echo '{"ok":true}' ;;
    *) echo '{"ok":false,"error":"unknown verb"}' ;;
  esac
  exit 0
fi

. "$(dirname -- "$0")/common.sh"
[ "$(uname -s)" = Darwin ] || die "run this on macOS"
APP_IN=""
KEEP=0
HISTORY=0
WORK=${STRESS_WORK:-${RUNNER_TEMP:-/tmp}/bridgey-stress-mac}
OUT=""
while [ $# -gt 0 ]; do
  case $1 in
    --app) APP_IN=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --history) HISTORY=$2; shift 2 ;;
    *) break ;;
  esac
done
OUT=${OUT:-$WORK/out}
case "$BID" in "$(edition_value EDITION_APP_ID)") die "refusing the installed bundle ID" ;; esac
APP="$WORK/app/Bridgey Stress.app"
CTL="/tmp/$BID-control"
LOCKED=0
LOG_PID=""
PEER_PID=""

cleanup() {
  [ -n "$PEER_PID" ] && kill "$PEER_PID" 2>/dev/null
  [ $LOCKED = 1 ] && rmdir /tmp/app-build-mac.lock 2>/dev/null
  [ -n "$LOG_PID" ] && kill "$LOG_PID" 2>/dev/null
  pkill -9 -f "$APP/Contents/MacOS/BridgeyMac" 2>/dev/null || true
  [ $KEEP = 1 ] && { echo "kept $WORK and the instance's data ($BID)"; return 0; }
  for s in "$BID.trust" "$BID.identity"; do
    while security delete-generic-password -s "$s" >/dev/null 2>&1; do :; done
  done
  defaults delete "$BID" 2>/dev/null || true
  defaults delete "$BID.handoff-test" 2>/dev/null || true
  rm -rf "$HOME/Library/Application Support/$BID" "$HOME/Library/Caches/$BID" "$HOME/Library/Preferences/$BID.plist" \
    "$HOME/Library/Preferences/$BID.handoff-test.plist" "$HOME/Library/HTTPStorages/$BID" \
    "$HOME/Library/Saved Application State/$BID.savedState" "$CTL" "$WORK/app" "$WORK/src" "$WORK/received" \
    "$WORK/app-src" "$WORK/app-received" "$WORK/state"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$WORK" "$OUT"
if [ -z "$APP_IN" ] || [ ! -x "$WORK/peer/stress" ]; then
  until mkdir /tmp/app-build-mac.lock 2>/dev/null; do echo "waiting for /tmp/app-build-mac.lock"; sleep 30; done
  LOCKED=1
  if [ -z "$APP_IN" ]; then
    echo "== building the debug app"
    (cd "$RR_ROOT/macos" && ./build-app.sh)
    APP_IN="$RR_ROOT/macos/.build/debug/$(edition_value EDITION_MAC_APP_NAME).app"
  fi
  echo "== building the scripted peer"
  . "$RR_ROOT/scripts/rr/rust-env.sh"
  cargo build --release --locked -p bridgey-client --example stress --manifest-path "$RR_ROOT/rust/Cargo.toml"
  mkdir -p "$WORK/peer"
  cp "$RR_ROOT/rust/target/release/examples/stress" "$WORK/peer/stress"
  rmdir /tmp/app-build-mac.lock
  LOCKED=0
fi
[ -d "$APP_IN" ] || die "no app at $APP_IN"

echo "== making the throwaway instance ($BID, port $PORT)"
rm -rf "$WORK/app" "$CTL"
mkdir -p "$WORK/app" "$WORK/app-src" "$WORK/app-received" "$CTL"
ditto "$APP_IN" "$APP"
PL="$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleIdentifier $BID" "$PL"
"$PB" -c "Set :CFBundleName Bridgey Stress" "$PL"
for k in CFBundleDisplayName BridgeyTestInstance BridgeyTestPort BridgeyTestServiceType CFBundleURLTypes NSServices \
  BridgeyConnectControlURL BridgeyCodeRelayURL SUEnableAutomaticChecks; do
  "$PB" -c "Delete :$k" "$PL" 2>/dev/null || true
done
"$PB" -c "Add :CFBundleDisplayName string Bridgey Stress" "$PL"
"$PB" -c "Add :BridgeyTestInstance bool true" "$PL"
"$PB" -c "Add :BridgeyTestPort integer $PORT" "$PL"
"$PB" -c "Add :BridgeyTestServiceType string $SERVICE." "$PL"
"$PB" -c "Set :NSBonjourServices:0 $SERVICE" "$PL"
"$PB" -c "Set :SUFeedURL http://127.0.0.1:9/none.xml" "$PL"
"$PB" -c "Add :SUEnableAutomaticChecks bool false" "$PL"
rm -rf "$APP/Contents/PlugIns" "$APP/Contents/Resources/Metadata.appintents"
codesign --force --sign - --entitlements "$RR_ROOT/macos/Resources/Bridgey.entitlements" \
  --requirements "=designated => identifier \"$BID\"" "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"
defaults write "$BID" setup.completedVersion -int 1
defaults write "$BID" settings.onboarding.completed -bool true
defaults write "$BID" SUEnableAutomaticChecks -bool false
defaults write "$BID" settings.receiveFolderPath "$WORK/app-received"
if [ "$HISTORY" -gt 0 ]; then
  # The app's own format (TransferHistory.swift): newest first, dates in milliseconds, an owner-only file. A mix like
  # a heavy user's: documents, photos and videos (the grid), folders and some failures, from two phones.
  echo "== seeding $HISTORY transfer history entries"
  SUPPORT="$HOME/Library/Application Support/$BID"
  mkdir -p "$SUPPORT"
  chmod 700 "$SUPPORT"
  python3 -I - "$HISTORY" "$WORK/app-received" "$SUPPORT/transfer-history.json" <<'PY'
import json, os, random, sys, time
count, received, target = min(int(sys.argv[1]), 2000), sys.argv[2], sys.argv[3]
rng = random.Random(7)
now = int(time.time() * 1000)
span = 29 * 24 * 3600 * 1000
phones = [("5eed0000-0000-4000-8000-000000000001", "Stress phone"), ("5eed0000-0000-4000-8000-000000000002", "Stress tablet")]
kinds = [("pdf", 20), ("zip", 8), ("docx", 8), ("bin", 14), ("jpg", 22), ("heic", 6), ("mp4", 8), ("folder", 6), ("txt", 8)]
names = [k for k, weight in kinds for _ in range(weight)]
entries = []
for index in range(count):
    kind = rng.choice(names)
    phone = phones[index % 7 == 0]
    outcome = "completed" if rng.random() > 0.05 else rng.choice(["failed", "cancelled", "incomplete"])
    name = f"seed-{index:05d}" if kind == "folder" else f"seed-{index:05d}.{kind}"
    size = rng.randint(2_000, 400_000_000)
    entry = {"id": f"seed-{index:05d}", "date": now - 60_000 - int(span * index / max(1, count)), "direction": rng.choice(["sent", "received"]),
             "deviceID": phone[0], "deviceName": phone[1], "name": name, "isFolder": kind == "folder",
             "fileCount": rng.randint(2, 300) if kind == "folder" else 1, "bytes": size if outcome == "completed" else 0,
             "outcome": outcome, "localPath": os.path.join(received, name), "download": False}
    if outcome == "completed" and size > 1_000_000:
        entry["bytesPerSecond"] = rng.uniform(5e6, 9e8)
    entries.append(entry)
fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(entries, f)
PY
fi

export STRESS_APP="$APP" STRESS_RECV="$WORK/app-received" STRESS_APPSRC="$WORK/app-src" STRESS_BIN="$WORK/peer/stress"
SELF="$RR_ROOT/scripts/rr/stress-mac.sh"
sh "$SELF" control start | grep -q '"ok":true' || die "the instance did not start"
nohup /usr/bin/log stream --style compact --predicate "processImagePath CONTAINS \"$WORK/app/\"" > "$OUT/app.log" 2>&1 </dev/null &
LOG_PID=$!

echo "== running the scenarios"
rm -f "$WORK/events.jsonl"
set +e
"$WORK/peer/stress" run --app "sh $SELF control" --target "127.0.0.1:$PORT" --work "$WORK" --report "$OUT/report.json" \
  --peer-platform android "$@" &
PEER_PID=$!
wait "$PEER_PID"
STATUS=$?
PEER_PID=""
set -e
cp "$WORK/events.jsonl" "$OUT/events.jsonl" 2>/dev/null || true
echo "report: $OUT/report.json"
exit $STATUS
