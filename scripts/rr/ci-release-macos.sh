#!/bin/sh
# RR CI entry point for the Mac half of a Bridgey by Round Robin release or nightly, on an RR CI Mac.
# Usage: scripts/rr/ci-release-macos.sh nightly <output-dir>
#        scripts/rr/ci-release-macos.sh tag <output-dir>     beta or stable from the tag in RR_CI_REF
# Builds the Mac app (scripts/rr/build-macos.sh) for the version scripts/rr/ci-release.sh then publishes
# from rr-dev-1. RR CI hands the output to that job, so rr-dev-1 no longer waits on a Mac over SSH.
# release.env records the build time and the version built in; ci-release.sh derives the same
# version from it and refuses to publish if they differ. The Mac build is ad-hoc signed: no secrets.
set -eu
. "$(dirname -- "$0")/common.sh"

MODE=${1:-}
OUT=${2:-}
case "$MODE" in nightly|tag) ;; *) sed -n '2,8p' "$0"; exit 2 ;; esac
[ -n "$OUT" ] || die "pass the output directory"

if [ "$MODE" = nightly ]; then
  set -- nightly
else
  REF=${RR_CI_REF:?RR_CI_REF must name the release tag}
  case "$REF" in refs/tags/v*) ;; *) die "not a release tag: $REF" ;; esac
  VERSION=${REF#refs/tags/v}
  if echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$'; then CHANNEL=beta
  elif echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then CHANNEL=stable
  else die "v$VERSION is neither a stable (v1.0.0) nor a beta (v1.0.0-beta.2) tag"; fi
  set -- "$CHANNEL" --version "$VERSION"
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:00Z)
eval "$(python3 "$RR_ROOT/scripts/rr/rrrelease.py" version "$@" --now "$NOW")"
export BRIDGEY_VERSION_NAME="$VERSION_NAME" BRIDGEY_BUILD_NUMBER="$BUILD_NUMBER"
echo "== macOS for $CHANNEL $VERSION_NAME build $BUILD_NUMBER"
mkdir -p "$OUT"
sh "$RR_ROOT/scripts/rr/build-macos.sh" "$OUT"
printf 'NOW=%s\nCHANNEL=%s\nVERSION_NAME=%s\nBUILD_NUMBER=%s\nTAG=%s\nREVISION=%s\n' \
  "$NOW" "$CHANNEL" "$VERSION_NAME" "$BUILD_NUMBER" "$TAG" "$(git -C "$RR_ROOT" rev-parse HEAD)" > "$OUT/release.env"
