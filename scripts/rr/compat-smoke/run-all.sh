#!/bin/bash
# Bridgey compatibility smoke (docs/compatibility.md). Copy this folder and the signed APK (as app-release.apk) to
# /tmp/bridgey-compat on the personal Mac, then run ./run-all.sh <avd>... there. Results land in out/<avd>/.
# run-all.sh <avd>... : for each AVD (creating bridgey-apiNN AVDs as needed), boot, smoke, stop.
cd /tmp/bridgey-compat
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
SDK=~/Library/Android/sdk
for avd in "$@"; do
  if [[ $avd == bridgey-api* ]] && [ ! -d ~/.android/avd/$avd.avd ]; then
    api=${avd#bridgey-api}
    echo no | $SDK/cmdline-tools/latest/bin/avdmanager create avd -n $avd -k "system-images;android-$api;google_apis;arm64-v8a" -d pixel_6 >/dev/null 2>&1 </dev/null || { echo "create $avd failed"; continue; }
    cfg=~/.android/avd/$avd.avd/config.ini
    sed -i '' -e 's/^disk.dataPartition.size=.*/disk.dataPartition.size=4G/' -e 's/^hw.ramSize=.*/hw.ramSize=2048/' $cfg
  fi
  until ./boot.sh $avd; do
    rc=$?; [ $rc = 3 ] || { echo "$avd boot failed"; ./stop.sh; continue 2; }
    echo "emulator lock held, waiting"; sleep 30
  done
  sleep 20
  python3 smoke.py emulator-5580 out/$avd app-release.apk > out/$avd.log 2>&1
  tail -3 out/$avd.log
  ./stop.sh
done
