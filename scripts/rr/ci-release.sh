#!/bin/sh
# RR CI entry point for Bridgey by Round Robin releases on our own worker (rr-dev-1).
# Usage: scripts/rr/ci-release.sh nightly   nightly from rr/main (fallback; RR CI builds nightlies on GitHub), notes from release-notes.sh
#        scripts/rr/ci-release.sh tag       beta or stable from the annotated tag in RR_CI_REF, notes from its message
#   v1.0.0         -> stable 1.0.0
#   v1.0.0-beta.2  -> beta 1.0.0-beta.2 (betas lead to EDITION_NEXT_VERSION)
# Tags are made by scripts/rr/cut-release.py (beta, promote); see docs/rr-edition.md "Releasing".
# The revision must be on RELEASE_BRANCH (rr/main). Builds Android here, then publishes (release.sh --publish).
# The Mac app comes from this release's RR CI Mac job (release-macos or nightly-macos, which run
# scripts/rr/ci-release-macos.sh) when RR CI hands its files over in RR_CI_INPUT_DIR; otherwise it is
# built on BRIDGEY_RR_MAC_HOST (default personal) over SSH. The Windows zips come from the RR CI Windows job
# (release-windows or nightly-windows, scripts/rr/ci-release-windows.ps1) the same way; without it the release
# goes out without Windows and the channel feed keeps its previous Windows entry.
# RR CI gives jobs a private HOME, so the keys, the GitHub token and the toolchains come from the
# worker account's home (RR_CI_HOST_HOME): ~/.config/bridgey-rr/{rr-bridgey.jks,android-signing.env,
# sparkle_ed25519_private.key,github-token}. Nothing secret is printed.
set -eu
. "$(dirname -- "$0")/common.sh"

MODE=${1:-}
case "$MODE" in nightly|tag) ;; *) sed -n '2,13p' "$0"; exit 2 ;; esac
H=${RR_CI_HOST_HOME:-$HOME}
CONFIG="$H/.config/bridgey-rr"
export BRIDGEY_RR_KEYSTORE="$CONFIG/rr-bridgey.jks" BRIDGEY_RR_SIGNING_ENV="$CONFIG/android-signing.env" \
  BRIDGEY_RR_SPARKLE_KEY="$CONFIG/sparkle_ed25519_private.key"
[ -f "$CONFIG/github-token" ] || die "GitHub token not found at $CONFIG/github-token"
GH_TOKEN=$(cat "$CONFIG/github-token")
export GH_TOKEN

# Toolchains as the RR CI Gradle profiles find them; no Gradle or Kotlin daemon outlives the job.
JAVA_HOME=""
for j in /usr/lib/jvm/java-17-openjdk-amd64 /usr/lib/jvm/java-17-openjdk-arm64; do [ -z "$JAVA_HOME" ] && [ -x "$j/bin/java" ] && JAVA_HOME="$j"; done
[ -n "$JAVA_HOME" ] || die "JDK 17 is not installed on this worker"
ANDROID_HOME=""
for s in "$H/Android/Sdk" "$H/Library/Android/sdk"; do [ -d "$s" ] && ANDROID_HOME="$s"; done
[ -n "$ANDROID_HOME" ] || die "the Android SDK is not installed on this worker"
export JAVA_HOME ANDROID_HOME ANDROID_SDK_ROOT="$ANDROID_HOME" GRADLE_USER_HOME="$H/.gradle" \
  GRADLE_OPTS="-Dorg.gradle.daemon=false -Dkotlin.compiler.execution.strategy=in-process"

REPO=$(edition_value GITHUB_REPO)
BRANCH=$(edition_value RELEASE_BRANCH)
HEAD=$(git -C "$RR_ROOT" rev-parse HEAD)
MAC_HOST=${BRIDGEY_RR_MAC_HOST:-personal}
STATUS=$(gh api "repos/$REPO/compare/$BRANCH...$HEAD" --jq .status)
case "$STATUS" in identical|behind) ;; *) die "$HEAD is not on $BRANCH ($STATUS); releases come from $BRANCH only" ;; esac

NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SHORT=$(printf '%.7s' "$HEAD")

if [ "$MODE" = nightly ]; then
  # Nightlies normally build on GitHub-hosted runners (.github/workflows/rr-ci-nightly.yml); this
  # self-hosted path stays as a fallback. Notes: commits since the previous nightly or beta.
  sh "$RR_ROOT/scripts/rr/release-notes.sh" "$HEAD" > "$NOTES"
  set -- nightly
else
  REF=${RR_CI_REF:?RR_CI_REF must name the release tag}
  case "$REF" in refs/tags/v*) ;; *) die "not a release tag: $REF" ;; esac
  TAG=${REF#refs/tags/}
  VERSION=${TAG#v}
  if echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$'; then CHANNEL=beta
  elif echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then CHANNEL=stable
  else die "$TAG is neither a stable (v1.0.0) nor a beta (v1.0.0-beta.2) tag"; fi
  OBJECT=$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq '.object.type + " " + .object.sha')
  [ "${OBJECT%% *}" = tag ] || die "$TAG is a lightweight tag; release tags must be annotated (git tag -a) and carry the notes"
  TAGGED=$(gh api "repos/$REPO/git/tags/${OBJECT#* }" --jq '.object.sha')
  [ "$TAGGED" = "$HEAD" ] || die "$TAG points at $TAGGED, not at the checked-out $HEAD"
  # Notes are the tag message without a GPG or SSH signature block.
  gh api "repos/$REPO/git/tags/${OBJECT#* }" --jq .message | sed '/^-----BEGIN [A-Z ]*SIGNATURE-----/,$d' > "$NOTES"
  [ -s "$NOTES" ] || die "$TAG has no message to use as release notes"
  set -- "$CHANNEL" --version "$VERSION"
fi

# The Mac app from RR CI's Mac job, when it ran: same revision, and the version and build number this
# release derives from that job's build time must be the ones built into the app.
MAC_DIR=""
if [ -n "${RR_CI_INPUT_DIR:-}" ]; then
  for d in "$RR_CI_INPUT_DIR/release-macos" "$RR_CI_INPUT_DIR/nightly-macos"; do
    if [ -f "$d/release.env" ]; then MAC_DIR=$d; break; fi
  done
fi
# The Windows zips from RR CI's Windows job: same revision and the same version name (its own build number orders
# Windows updates; the Windows job may build at another minute than the Mac's).
WIN_DIR=""
if [ -n "${RR_CI_INPUT_DIR:-}" ]; then
  for d in "$RR_CI_INPUT_DIR/release-windows" "$RR_CI_INPUT_DIR/nightly-windows"; do
    if [ -f "$d/release.env" ]; then WIN_DIR=$d; break; fi
  done
fi
if [ -n "$WIN_DIR" ]; then
  [ "$(sed -n 's/^REVISION=//p' "$WIN_DIR/release.env")" = "$HEAD" ] || die "the Windows build is not of $HEAD"
  WIN_VERSION=$(sed -n 's/^VERSION_NAME=//p' "$WIN_DIR/release.env")
  WIN_NOW=$(sed -n 's/^NOW=//p' "$WIN_DIR/release.env")
  echo "== Windows $WIN_VERSION from RR CI's Windows job"
else
  echo "note: no Windows job output in this release; the channel feed keeps its previous Windows entry" >&2
fi

if [ -n "$MAC_DIR" ]; then
  MAC_NOW=$(sed -n 's/^NOW=//p' "$MAC_DIR/release.env")
  [ "$(sed -n 's/^REVISION=//p' "$MAC_DIR/release.env")" = "$HEAD" ] || die "the Mac build is not of $HEAD"
  WANT=$(python3 "$RR_ROOT/scripts/rr/rrrelease.py" version "$@" --now "$MAC_NOW" | grep -E '^(CHANNEL|VERSION_NAME|BUILD_NUMBER|TAG)=')
  GOT=$(grep -E '^(CHANNEL|VERSION_NAME|BUILD_NUMBER|TAG)=' "$MAC_DIR/release.env")
  [ "$WANT" = "$GOT" ] || die "the Mac build's version differs from this release's"
  if [ -n "$WIN_DIR" ]; then
    [ "$(printf '%s\n' "$WANT" | sed -n 's/^VERSION_NAME=//p')" = "$WIN_VERSION" ] || die "the Windows build's version ($WIN_VERSION) differs from this release's"
  fi
  echo "== $* from $BRANCH @$SHORT, Mac build from RR CI's Mac job"
  sh "$RR_ROOT/scripts/rr/release.sh" "$@" --now "$MAC_NOW" --notes-file "$NOTES" --macos-artifacts "$MAC_DIR" ${WIN_DIR:+--windows-artifacts "$WIN_DIR"} --publish
else
  # Without the Mac job, the release takes its time from the Windows job (when there is one), so the version
  # name it derives is the one built into the Windows zips.
  [ -z "$WIN_DIR" ] || set -- "$@" --now "$WIN_NOW"
  echo "== $* from $BRANCH @$SHORT, Mac build on $MAC_HOST"
  sh "$RR_ROOT/scripts/rr/release.sh" "$@" --notes-file "$NOTES" --mac-host "$MAC_HOST" ${WIN_DIR:+--windows-artifacts "$WIN_DIR"} --publish
fi
