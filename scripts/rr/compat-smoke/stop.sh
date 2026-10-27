#!/bin/bash
ADB=~/Library/Android/sdk/platform-tools/adb
$ADB -s emulator-5580 emu kill </dev/null >/dev/null 2>&1
sleep 5
pkill -f 'emulator.*-port 5580' 2>/dev/null
rm -f /tmp/android-emulator.lock/owner; rmdir /tmp/android-emulator.lock 2>/dev/null
echo stopped
