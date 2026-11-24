#!/bin/sh
# RR CI entry point for Bridgey by Round Robin releases on our own worker (rr-dev-1).
# Usage: scripts/rr/ci-release.sh nightly   nightly from rr/main (fallback; RR CI builds nightlies on GitHub), notes from release-notes.sh
#        scripts/rr/ci-release.sh tag       beta or stable from the annotated tag in RR_CI_REF, notes from its message
#   v1.0.0         -> stable 1.0.0
#   v1.0.0-beta.2  -> beta 1.0.0-beta.2 (betas lead to EDITION_NEXT_VERSION)
# Tags are made by scripts/rr/cut-release.py (beta, promote); see docs/rr-edition.md "Releasing".
# The revision must be on RELEASE_BRANCH (rr/main). Publishes with release.sh --publish.
# The APK comes unsigned from this release's RR CI Android job (release-android or nightly-android, on a GitHub-hosted
# runner with no secrets, scripts/rr/build-android-unsigned.sh) and is signed here (scripts/rr/sign-android.sh);
# without that job's files it is built and signed here as before.
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
case "$MODE" in nightly|tag) ;; *) sed -n '2,16p' "$0"; exit 2 ;; esac
H=${RR_CI_HOST_HOME:-$HOME}
CONFIG="$H/.config/bridgey-rr"
export BRIDGEY_RR_KEYSTORE="$CONFIG/rr-bridgey.jks" BRIDGEY_RR_SIGNING_ENV="$CONFIG/android-signing.env" \
  BRIDGEY_RR_SPARKLE_KEY="$CONFIG/sparkle_ed25519_private.key"
[ -f "$CONFIG/github-token" ] || die "GitHub token not found at $CONFIG/github-token"
GH_TOKEN=$(cat "$CONFIG/github-token")
export GH_TOKEN

# Toolchains as the RR CI Gradle profiles find them; no Gradle or Kotlin daemon outlives the job.
# A JDK 17 RR CI names in JAVA_HOME comes first, then the worker's packaged one.
JDK=""
for j in ${JAVA_HOME:-} /usr/lib/jvm/java-17-openjdk-amd64 /usr/lib/jvm/java-17-openjdk-arm64; do [ -z "$JDK" ] && [ -x "$j/bin/java" ] && JDK="$j"; done
JAVA_HOME=$JDK
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
SIGNED_DIR=$(mktemp -d)
trap 'rm -rf "$NOTES" "$SIGNED_DIR"' EXIT
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
# The unsigned APK from RR CI's Android job: same revision and the same version and build number (its versionCode).
AND_DIR=""
if [ -n "${RR_CI_INPUT_DIR:-}" ]; then
  for d in "$RR_CI_INPUT_DIR/release-android" "$RR_CI_INPUT_DIR/nightly-android"; do
    if [ -f "$d/release.env" ] && [ -f "$d/app-release-unsigned.apk" ]; then AND_DIR=$d; break; fi
  done
fi

if [ -n "$WIN_DIR" ]; then
  [ "$(env_value "$WIN_DIR/release.env" REVISION)" = "$HEAD" ] || die "the Windows build is not of $HEAD"
  WIN_VERSION=$(env_value "$WIN_DIR/release.env" VERSION_NAME)
  WIN_NOW=$(env_value "$WIN_DIR/release.env" NOW)
  echo "== Windows $WIN_VERSION from RR CI's Windows job"
else
  echo "note: no Windows job output in this release; the channel feed keeps its previous Windows entry" >&2
fi
if [ -n "$MAC_DIR" ]; then
  [ "$(env_value "$MAC_DIR/release.env" REVISION)" = "$HEAD" ] || die "the Mac build is not of $HEAD"
fi
if [ -n "$AND_DIR" ]; then
  [ "$(env_value "$AND_DIR/release.env" REVISION)" = "$HEAD" ] || die "the Android build is not of $HEAD"
fi

# One time for the whole release: the Mac job's, else the Android job's, else the Windows job's (RR CI gives every job
# of a run the same one), else now. The version and build number derived from it must be the ones built in.
NOW=""
if [ -n "$MAC_DIR" ]; then NOW=$(env_value "$MAC_DIR/release.env" NOW)
elif [ -n "$AND_DIR" ]; then NOW=$(env_value "$AND_DIR/release.env" NOW)
elif [ -n "$WIN_DIR" ]; then NOW=$WIN_NOW
fi
[ -z "$NOW" ] || set -- "$@" --now "$NOW"
WANT=$(python3 "$RR_ROOT/scripts/rr/rrrelease.py" version "$@" | grep -E '^(CHANNEL|VERSION_NAME|BUILD_NUMBER|TAG)=')
job_version() { tr -d '\r' < "$1" | grep -E '^(CHANNEL|VERSION_NAME|BUILD_NUMBER|TAG)='; }
[ -z "$MAC_DIR" ] || [ "$(job_version "$MAC_DIR/release.env")" = "$WANT" ] || die "the Mac build's version differs from this release's"
[ -z "$AND_DIR" ] || [ "$(job_version "$AND_DIR/release.env")" = "$WANT" ] || die "the Android build's version differs from this release's"
if [ -n "$WIN_DIR" ]; then
  [ "$(printf '%s\n' "$WANT" | sed -n 's/^VERSION_NAME=//p')" = "$WIN_VERSION" ] || die "the Windows build's version ($WIN_VERSION) differs from this release's"
fi

if [ -n "$AND_DIR" ]; then
  echo "== Android from RR CI's Android job, signed here"
  BRIDGEY_VERSION_NAME=$(printf '%s\n' "$WANT" | sed -n 's/^VERSION_NAME=//p') \
    BRIDGEY_BUILD_NUMBER=$(printf '%s\n' "$WANT" | sed -n 's/^BUILD_NUMBER=//p') \
    sh "$RR_ROOT/scripts/rr/sign-android.sh" "$AND_DIR/app-release-unsigned.apk" "$SIGNED_DIR/app-release.apk"
  set -- "$@" --apk "$SIGNED_DIR/app-release.apk"
  [ ! -s "$AND_DIR/android-dependencies.txt" ] || set -- "$@" --android-deps "$AND_DIR/android-dependencies.txt"
else
  echo "note: no Android job output in this release; building the APK here" >&2
fi

if [ -n "$MAC_DIR" ]; then
  echo "== $* from $BRANCH @$SHORT, Mac build from RR CI's Mac job"
  sh "$RR_ROOT/scripts/rr/release.sh" "$@" --notes-file "$NOTES" --macos-artifacts "$MAC_DIR" ${WIN_DIR:+--windows-artifacts "$WIN_DIR"} --publish
else
  echo "== $* from $BRANCH @$SHORT, Mac build on $MAC_HOST"
  sh "$RR_ROOT/scripts/rr/release.sh" "$@" --notes-file "$NOTES" --mac-host "$MAC_HOST" ${WIN_DIR:+--windows-artifacts "$WIN_DIR"} --publish
fi
