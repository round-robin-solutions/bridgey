#!/bin/bash
# stop.sh : stops the emulator boot.sh started and releases the lock, but only if this run still owns the lock.
# Never touches another agent's emulator or lock.
STATE=${BRIDGEY_COMPAT_STATE:-/tmp/bridgey-compat/.lock-owner}
ADB=~/Library/Android/sdk/platform-tools/adb
MINE=$(cat "$STATE" 2>/dev/null)
OWNER=$(cat /tmp/android-emulator.lock/owner 2>/dev/null)
if [ -z "$MINE" ] || [ "$MINE" != "$OWNER" ]; then
  echo "not stopping: the lock is not ours (ours: '${MINE:-none}', lock: '${OWNER:-none}')"
  exit 0
fi
$ADB -s emulator-5580 emu kill </dev/null >/dev/null 2>&1
sleep 5
pkill -f 'emulator.*-avd .*-port 5580' 2>/dev/null
rm -f "$STATE" /tmp/android-emulator.lock/owner
rmdir /tmp/android-emulator.lock 2>/dev/null
echo stopped
