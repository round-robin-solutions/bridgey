#!/bin/sh
# Copies the repository to a Mac over SSH, builds there under the shared Mac build lock,
# and brings the DMG and ZIP back. rsync to macOS hangs, so this uses tar over ssh.
# Usage: BRIDGEY_VERSION_NAME=... BRIDGEY_BUILD_NUMBER=... scripts/rr/build-macos-remote.sh <host> <output-dir>
set -eu
. "$(dirname -- "$0")/common.sh"

HOST=${1:?usage: build-macos-remote.sh <host> <output-dir>}
OUTPUT=${2:?usage: build-macos-remote.sh <host> <output-dir>}
: "${BRIDGEY_VERSION_NAME:?set BRIDGEY_VERSION_NAME}"
: "${BRIDGEY_BUILD_NUMBER:?set BRIDGEY_BUILD_NUMBER}"
REMOTE=/tmp/bridgey-rr-release
mkdir -p "$OUTPUT"

tar -C "$(dirname -- "$RR_ROOT")" -czf - --exclude=.git --exclude=android --exclude=macos/.build --exclude=dist \
  "$(basename -- "$RR_ROOT")" |
  ssh "$HOST" "rm -rf $REMOTE && mkdir -p $REMOTE && tar -C $REMOTE -xzf - && mv $REMOTE/$(basename -- "$RR_ROOT") $REMOTE/src"

ssh "$HOST" "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH
  until mkdir /tmp/app-build-mac.lock 2>/dev/null; do echo 'waiting for the Mac build lock'; sleep 30; done
  trap 'rmdir /tmp/app-build-mac.lock' EXIT INT TERM
  cd $REMOTE/src && BRIDGEY_VERSION_NAME='$BRIDGEY_VERSION_NAME' BRIDGEY_BUILD_NUMBER='$BRIDGEY_BUILD_NUMBER' \
    sh scripts/rr/build-macos.sh $REMOTE/out"

ssh "$HOST" "tar -C $REMOTE/out -cf - ." | tar -C "$OUTPUT" -xf -
ssh "$HOST" "rm -rf $REMOTE"
ls -l "$OUTPUT"
