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
#   scripts/rr/stress-mac.sh [--app <debug .app>] [--out <dir>] [--keep] [--history <n>] [--peer <driver>]
#                            [--driver run|soak|accept] [--new-app <debug .app>] [driver options ...]
#   e.g. scripts/rr/stress-mac.sh --scenarios quick --mid 256M --big 1G
#        scripts/rr/stress-mac.sh --driver soak --app new/Bridgey.app --minutes 360 --max-file 256M
#        scripts/rr/stress-mac.sh --driver accept --app old/Bridgey.app --new-app new/Bridgey.app
# --driver as in stress-android.sh (docs/acceptance-1.0.md); `accept` makes the instance from --app and upgrades it in
# place to --new-app mid-file. STRESS_MAC_BID (in.roundrobin.bridgey.test.<label>), STRESS_MAC_PORT and
# STRESS_MAC_SERVICE give a second instance of its own, so a soak and another run can share a Mac.
# --history starts the instance with <n> transfer history entries (at most 2,000, the app's limit) over the last 30
# days, so a run measures a Mac that has moved a lot of files.
# Without --app it builds the debug app (macos/build-app.sh) and the peer while holding /tmp/app-build-mac.lock, a
# directory taken with mkdir and released with rmdir (never a file). The peer's options are stress.rs's (`run`).
# `stress-mac.sh control <verb> ...` is the app control the peer calls; it reads the STRESS_* variables set below.
set -eu

BID=${STRESS_MAC_BID:-in.roundrobin.bridgey.test.stress}
PORT=${STRESS_MAC_PORT:-42497}
SERVICE=${STRESS_MAC_SERVICE:-_bridgeyst._tcp}
case $BID in in.roundrobin.bridgey.test.?*) ;; *) echo "STRESS_MAC_BID must be in.roundrobin.bridgey.test.<label>" >&2; exit 2 ;; esac

. "$(dirname -- "$0")/stress-instance.sh"

if [ "${1:-}" = control ]; then
  shift
  : "${STRESS_APP:?}" "${STRESS_RECV:?}" "${STRESS_APPSRC:?}" "${STRESS_BIN:?}"
  CTL="/tmp/$BID-control"
  SUPPORT="$HOME/Library/Application Support/$BID"
  app_pid() { pgrep -f "$STRESS_APP/Contents/MacOS/BridgeyMac" | head -n 1 || true; }
  # Quits the instance (TERM, then KILL after 10 s) and waits until it is gone.
  quit_app() {
    pkill -TERM -f "$STRESS_APP/Contents/MacOS/BridgeyMac" || true
    i=0
    while [ -n "$(app_pid)" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    pkill -9 -f "$STRESS_APP/Contents/MacOS/BridgeyMac" 2>/dev/null || true
  }
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
    pair-dial)
      # Pairs with a phone at host:port as a tap on it in the nearby list would; Codes match is pressed for the prompt.
      : > "$CTL/autoconfirm"
      command_file pair "$1"
      echo '{"ok":true}' ;;
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
    # Upgrade acceptance and soak (docs/acceptance-1.0.md).
    clipboard-on) echo '{"ok":true}' ;;
    clip-send)
      command_file clipboard-text "$1"
      echo '{"ok":true}' ;;
    clip-status)
      python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1])).get("clipboard") or {}
print(json.dumps({"ok": True, "text": s.get("text"), "changeCount": s.get("changeCount"), "status": s.get("status")}))
' "$CTL/status.json" ;;
    proc)
      pid=$(app_pid)
      [ -n "$pid" ] || { echo '{"ok":false,"error":"the instance is not running"}'; exit 0; }
      set -- $(ps -o rss=,cputime= -p "$pid")
      rss=$1 cpu=$2
      threads=$(($(ps -M -p "$pid" | wc -l) - 1))
      fds=$(($(lsof -n -P -p "$pid" 2>/dev/null | wc -l) - 1))
      idlew=$(top -l 1 -pid "$pid" -stats pid,idlew 2>/dev/null | awk -v p="$pid" '$1 == p { print $2 }')
      printf '{"ok":true,"pid":%s,"rss_kb":%s,"threads":%s,"fds":%s,"cpu":"%s","idle_wakeups":%s}\n' \
        "$pid" "$rss" "$threads" "$fds" "$cpu" "${idlew:-null}" ;;
    grants)
      # Per-phone grants as Settings sets them: this Mac's screen Allow without asking, Remote control on (settings
      # only; a test instance never asks for Accessibility), and Unattended access off (the default is on).
      command_file screen-grant "all always"
      command_file remote-grant "all on"
      command_file screen-unattended "off"
      echo '{"ok":true}' ;;
    settings)
      # Settings away from their defaults, as the app stores them, written while the app is closed.
      quit_app
      defaults write "$BID" settings.deviceName -string "Acceptance Mac"
      defaults write "$BID" settings.reduceMotion -bool true
      defaults write "$BID" settings.activity.previews -bool false
      defaults write "$BID" settings.calls.ring -bool false
      defaults write "$BID" settings.folders.includeHidden -bool true
      defaults write "$BID" send.menuBarDrop -string tray
      defaults write "$BID" updates.channel -string nightly
      sh "$0" control start ;;
    snapshot)
      python3 -I - "$1" "$BID" "$SUPPORT" "$STRESS_APP" <<'SNAPSHOT'
import datetime, hashlib, json, os, plistlib, subprocess, sys
out, bid, support, app = sys.argv[1:5]
SECRET = ("token", "secret", "password", "credential", "installid")
def plain(key, v):
    if isinstance(v, bytes):
        return {"sha256": hashlib.sha256(v).hexdigest(), "size": len(v)}
    if isinstance(v, (datetime.datetime, datetime.date)):
        return v.isoformat()
    if isinstance(v, dict):
        return {k: plain(k, x) for k, x in sorted(v.items())}
    if isinstance(v, list):
        return [plain(key, x) for x in v]
    if isinstance(v, str) and any(s in key.lower() for s in SECRET):
        return "sha256:" + hashlib.sha256(v.encode()).hexdigest()
    return v
raw = subprocess.run(["defaults", "export", bid, "-"], capture_output=True).stdout
prefs = plistlib.loads(raw) if raw else {}
files = {}
def load(name):
    path = os.path.join(support, name)
    try:
        data = open(path, "rb").read()
    except OSError:
        return None
    entry = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "mode": oct(os.stat(path).st_mode & 0o777)}
    files[name] = entry
    try:
        return entry, json.loads(data)
    except ValueError as e:
        entry["error"] = str(e)
        return entry, None
for name in ("trust-v3.json", "screen-grants-v1.json", "activity-stream.json", "transfer-history.json", "file-resume.json",
             "remote-control-audit.json", "mac-actions-audit.json", "notification-history.json"):
    got = load(name)
    if not got or got[1] is None:
        continue
    entry, doc = got
    if name == "trust-v3.json":
        entry["version"] = doc.get("version")
        entry["devices"] = sorted(d.get("id") for d in doc.get("devices", []))
        entry["identityKey"] = hashlib.sha256(str(doc.get("identityKey")).encode()).hexdigest()
    elif name == "screen-grants-v1.json":
        entry["doc"] = doc
    elif name == "file-resume.json":
        records = doc.get("records", []) if isinstance(doc, dict) else []
        entry["records"] = [{k: v for k, v in r.items() if k not in ("path", "partPath", "url")} for r in records if isinstance(r, dict)]
    elif isinstance(doc, list):
        entry["items"] = [{k: i.get(k) for k in ("id", "kind", "outcome", "direction", "at", "date", "count")} for i in doc if isinstance(i, dict)]
info = plistlib.load(open(os.path.join(app, "Contents", "Info.plist"), "rb"))
pid = subprocess.run(["pgrep", "-f", app + "/Contents/MacOS/BridgeyMac"], capture_output=True, text=True).stdout.split()
doc = {"ok": True, "bundle": bid, "versionName": info.get("CFBundleShortVersionString"), "versionCode": int(info.get("CFBundleVersion", "0") or 0),
       "pid": int(pid[0]) if pid else None, "prefs": plain("", prefs), "files": files}
with open(out, "w") as f:
    json.dump(doc, f, indent=1, sort_keys=True)
print(json.dumps({"ok": True, "versionCode": doc["versionCode"]}))
SNAPSHOT
      ;;
    upgrade)
      # As an update does: the app quits, its bundle is replaced by the newer build in place, and it opens again.
      : "${STRESS_NEW_APP:?}" "${RR_ROOT:?}"
      from=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$STRESS_APP/Contents/Info.plist")
      quit_app
      make_instance "$STRESS_NEW_APP" "$STRESS_APP"
      to=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$STRESS_APP/Contents/Info.plist")
      sh "$0" control start | grep -q '"ok":true' || { echo '{"ok":false,"error":"the new build did not start"}'; exit 0; }
      printf '{"ok":true,"from":"%s","to":"%s"}\n' "$from" "$to" ;;
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
DRIVER=run
NEW_APP=""
PEER=""
while [ $# -gt 0 ]; do
  case $1 in
    --app) APP_IN=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --history) HISTORY=$2; shift 2 ;;
    --driver) DRIVER=$2; shift 2 ;;
    --new-app) NEW_APP=$2; shift 2 ;;
    --peer) PEER=$2; shift 2 ;;
    *) break ;;
  esac
done
case $DRIVER in run|soak|accept) ;; *) die "--driver is run, soak or accept" ;; esac
if [ "$DRIVER" = accept ]; then
  [ -d "$APP_IN" ] && [ -d "$NEW_APP" ] || die "--driver accept needs --app <older debug app> and --new-app <newer debug app>"
fi
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
if [ -n "$PEER" ]; then
  mkdir -p "$WORK/peer"
  cp "$PEER" "$WORK/peer/stress"
fi
# Soak and acceptance runs start with a fresh peer: an acceptance run must see the older build ask to pair.
if [ "$DRIVER" != run ]; then rm -rf "$WORK/state"; fi
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
make_instance "$APP_IN" "$APP"
defaults write "$BID" setup.completedVersion -int 1
defaults write "$BID" settings.onboarding.completed -bool true
defaults write "$BID" SUEnableAutomaticChecks -bool false
defaults write "$BID" settings.receiveFolderPath "$WORK/app-received"
# A new install starts with every optional feature off: Files and Clipboard on, as setup's choices.
defaults write "$BID" settings.global.files -bool true
defaults write "$BID" settings.global.clipboard -bool true
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

export STRESS_APP="$APP" STRESS_RECV="$WORK/app-received" STRESS_APPSRC="$WORK/app-src" STRESS_BIN="$WORK/peer/stress" \
  STRESS_NEW_APP="$NEW_APP" STRESS_MAC_BID="$BID" STRESS_MAC_PORT="$PORT" STRESS_MAC_SERVICE="$SERVICE" RR_ROOT
SELF="$RR_ROOT/scripts/rr/stress-mac.sh"
sh "$SELF" control start | grep -q '"ok":true' || die "the instance did not start"
nohup /usr/bin/log stream --style compact --predicate "processImagePath CONTAINS \"$WORK/app/\"" > "$OUT/app.log" 2>&1 </dev/null &
LOG_PID=$!

echo "== running the $DRIVER driver"
rm -f "$WORK/events.jsonl" "$WORK"/before.json "$WORK"/after*.json
case $DRIVER in run) REPORT=report.json ;; soak) REPORT=soak.json ;; accept) REPORT=accept.json ;; esac
set +e
nice -n 5 "$WORK/peer/stress" "$DRIVER" --app "sh $SELF control" --target "127.0.0.1:$PORT" --work "$WORK" --report "$OUT/$REPORT" \
  --peer-platform android "$@" &
PEER_PID=$!
wait "$PEER_PID"
STATUS=$?
PEER_PID=""
set -e
cp "$WORK/events.jsonl" "$OUT/events.jsonl" 2>/dev/null || true
JUDGE=0
case $DRIVER in
  soak)
    cp "$WORK/samples.jsonl" "$OUT/samples.jsonl" 2>/dev/null || true
    python3 -I "$RR_ROOT/scripts/rr/acceptance.py" soak --platform macos --report "$OUT/soak.json" --samples "$OUT/samples.jsonl" --out "$OUT" || JUDGE=$?
    ;;
  accept)
    for f in before.json after.json after-traffic.json; do cp "$WORK/$f" "$OUT/$f" 2>/dev/null || true; done
    python3 -I "$RR_ROOT/scripts/rr/acceptance.py" compare --platform macos --dir "$OUT" || JUDGE=$?
    ;;
esac
[ $STATUS = 0 ] && [ $JUDGE != 0 ] && STATUS=$JUDGE
echo "report: $OUT/$REPORT"
exit $STATUS
