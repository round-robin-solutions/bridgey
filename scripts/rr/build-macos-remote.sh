#!/bin/sh
# Copies the repository to a Mac over SSH, builds there under the shared Mac build lock,
# and brings the DMG and ZIP back. rsync to macOS hangs, so this uses tar over ssh.
# Usage: BRIDGEY_VERSION_NAME=... BRIDGEY_BUILD_NUMBER=... scripts/rr/build-macos-remote.sh <host> <output-dir>
# With BRIDGEY_RR_MAC_SIGN=1 the Round Robin code signing identity (BRIDGEY_RR_MAC_P12, default
# ~/.config/bridgey-rr/macos-codesign.p12, and its .password file) is piped to the Mac for this
# build only; build-macos.sh deletes it after importing it into a throwaway keychain.
set -eu
. "$(dirname -- "$0")/common.sh"

HOST=${1:?usage: build-macos-remote.sh <host> <output-dir>}
OUTPUT=${2:?usage: build-macos-remote.sh <host> <output-dir>}
: "${BRIDGEY_VERSION_NAME:?set BRIDGEY_VERSION_NAME}"
: "${BRIDGEY_BUILD_NUMBER:?set BRIDGEY_BUILD_NUMBER}"
# One folder per build, so two releases (a nightly and a hand-run one) never share it.
REMOTE=/tmp/bridgey-rr-release-$(date -u +%Y%m%d%H%M%S)-$$
mkdir -p "$OUTPUT"
P12=${BRIDGEY_RR_MAC_P12:-$HOME/.config/bridgey-rr/macos-codesign.p12}
if [ "${BRIDGEY_RR_MAC_SIGN:-0}" = 1 ]; then
  [ -f "$P12" ] && [ -f "$P12.password" ] || die "signing identity not found at $P12 (and $P12.password)"
fi
# Never leave the source tree or signing files on the Mac, even when the build fails.
trap 'ssh "$HOST" "rm -rf $REMOTE" || true' EXIT

tar -C "$(dirname -- "$RR_ROOT")" -czf - --exclude=.git --exclude=android --exclude=macos/.build --exclude=dist --exclude=rust/target \
  "$(basename -- "$RR_ROOT")" |
  ssh "$HOST" "rm -rf $REMOTE && mkdir -p $REMOTE && tar -C $REMOTE -xzf - && mv $REMOTE/$(basename -- "$RR_ROOT") $REMOTE/src"

SIGN_ENV=""
if [ "${BRIDGEY_RR_MAC_SIGN:-0}" = 1 ]; then
  ssh "$HOST" "umask 077 && mkdir -p $REMOTE/sign && cat > $REMOTE/sign/id.p12" < "$P12"
  ssh "$HOST" "umask 077 && cat > $REMOTE/sign/id.password" < "$P12.password"
  SIGN_ENV="RR_MAC_P12_FILE=$REMOTE/sign/id.p12 RR_MAC_P12_PASSWORD_FILE=$REMOTE/sign/id.password"
fi

ssh "$HOST" "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH
  until mkdir /tmp/app-build-mac.lock 2>/dev/null; do echo 'waiting for the Mac build lock'; sleep 30; done
  trap 'rmdir /tmp/app-build-mac.lock' EXIT INT TERM
  cd $REMOTE/src && BRIDGEY_VERSION_NAME='$BRIDGEY_VERSION_NAME' BRIDGEY_BUILD_NUMBER='$BRIDGEY_BUILD_NUMBER' $SIGN_ENV \
    sh scripts/rr/build-macos.sh $REMOTE/out"

ssh "$HOST" "tar -C $REMOTE/out -cf - ." | tar -C "$OUTPUT" -xf -
ls -l "$OUTPUT"
