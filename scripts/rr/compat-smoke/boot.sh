#!/bin/bash
# boot.sh <avd> : takes the emulator lock and boots headless; prints serial.
set -u
SDK=~/Library/Android/sdk
ADB=$SDK/platform-tools/adb
AVD=$1
mkdir /tmp/android-emulator.lock 2>/dev/null || { echo "LOCK HELD"; exit 3; }
echo "bridgey-compat $AVD $$" > /tmp/android-emulator.lock/owner
nohup $SDK/emulator/emulator -avd "$AVD" -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -port 5580 > /tmp/bridgey-compat/emu-$AVD.log 2>&1 </dev/null &
SERIAL=emulator-5580
for i in $(seq 1 180); do
  b=$($ADB -s $SERIAL shell getprop sys.boot_completed </dev/null 2>/dev/null | tr -d '\r')
  [ "$b" = 1 ] && { echo "booted $SERIAL after ${i}x2s"; exit 0; }
  sleep 2
done
echo "BOOT TIMEOUT"; tail -20 /tmp/bridgey-compat/emu-$AVD.log; exit 4
