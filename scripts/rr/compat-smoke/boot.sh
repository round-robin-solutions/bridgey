#!/bin/bash
# boot.sh <avd> : takes the emulator lock and boots headless on port 5580; prints the serial.
# The lock owner line is also kept in $STATE so stop.sh only ever stops what this run started.
set -u
SDK=~/Library/Android/sdk
ADB=$SDK/platform-tools/adb
AVD=$1
STATE=${BRIDGEY_COMPAT_STATE:-/tmp/bridgey-compat/.lock-owner}
mkdir -p "$(dirname "$STATE")"
mkdir /tmp/android-emulator.lock 2>/dev/null || { echo "LOCK HELD by: $(cat /tmp/android-emulator.lock/owner 2>/dev/null)"; exit 3; }
OWNER="bridgey-compat $AVD $$ $(date +%s)"
echo "$OWNER" > /tmp/android-emulator.lock/owner
echo "$OWNER" > "$STATE"
nohup $SDK/emulator/emulator -avd "$AVD" -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -port 5580 > "$(dirname "$STATE")/emu-$AVD.log" 2>&1 </dev/null &
SERIAL=emulator-5580
for i in $(seq 1 180); do
  b=$($ADB -s $SERIAL shell getprop sys.boot_completed </dev/null 2>/dev/null | tr -d '\r')
  [ "$b" = 1 ] && { echo "booted $SERIAL after ${i}x2s"; exit 0; }
  sleep 2
done
echo "BOOT TIMEOUT"; tail -20 "$(dirname "$STATE")/emu-$AVD.log"; exit 4
