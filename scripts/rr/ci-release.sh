#!/bin/sh
# RR CI entry point for Bridgey by Round Robin releases on our own worker (rr-dev-1).
# Usage: scripts/rr/ci-release.sh nightly   nightly from rr/main, notes from the commits since the last nightly
#        scripts/rr/ci-release.sh tag       beta or stable from the annotated tag in RR_CI_REF, notes from its message
#   v0.6.0-rr.1         -> stable 0.6.0-rr.1
#   v0.6.0-rr.2-beta.1  -> beta 0.6.0-rr.2-beta.1
# The revision must be on RELEASE_BRANCH (rr/main). Builds Android here and the Mac app on
# BRIDGEY_RR_MAC_HOST (default personal) over SSH, then publishes (release.sh --publish).
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
trap 'rm -f "$NOTES"' EXIT INT TERM
SHORT=$(printf '%.7s' "$HEAD")

if [ "$MODE" = nightly ]; then
  PREVIOUS=$(gh release list -R "$REPO" --limit 100 --json tagName --jq '.[].tagName' | grep '^nightly-[0-9]\{8\}$' | sort -r | head -n 1 || true)
  # A nightly republished the same day replaces its release, so compare with an older one.
  TODAY=nightly-$(date -u +%Y%m%d)
  [ "$PREVIOUS" = "$TODAY" ] && PREVIOUS=$(gh release list -R "$REPO" --limit 100 --json tagName --jq '.[].tagName' | grep '^nightly-[0-9]\{8\}$' | sort -r | sed -n 2p || true)
  {
    printf 'Nightly build of %s at %s.\n\n' "$BRANCH" "$SHORT"
    if [ -n "$PREVIOUS" ]; then
      BASE=$(gh api "repos/$REPO/git/ref/tags/$PREVIOUS" --jq .object.sha)
      printf 'Changes since %s:\n\n' "$PREVIOUS"
      gh api "repos/$REPO/compare/$BASE...$HEAD" --jq '.commits | reverse | .[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"' | head -n 100
    else
      printf 'Recent changes:\n\n'
      gh api "repos/$REPO/commits?sha=$HEAD&per_page=20" --jq '.[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"'
    fi
  } > "$NOTES"
  set -- nightly
else
  REF=${RR_CI_REF:?RR_CI_REF must name the release tag}
  case "$REF" in refs/tags/v*) ;; *) die "not a release tag: $REF" ;; esac
  TAG=${REF#refs/tags/}
  VERSION=${TAG#v}
  if echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-rr\.[0-9]+-beta\.[0-9]+$'; then CHANNEL=beta
  elif echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-rr\.[0-9]+$'; then CHANNEL=stable
  else die "$TAG is neither a stable (v0.6.0-rr.1) nor a beta (v0.6.0-rr.2-beta.1) tag"; fi
  OBJECT=$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq '.object.type + " " + .object.sha')
  [ "${OBJECT%% *}" = tag ] || die "$TAG is a lightweight tag; release tags must be annotated (git tag -a) and carry the notes"
  TAGGED=$(gh api "repos/$REPO/git/tags/${OBJECT#* }" --jq '.object.sha')
  [ "$TAGGED" = "$HEAD" ] || die "$TAG points at $TAGGED, not at the checked-out $HEAD"
  gh api "repos/$REPO/git/tags/${OBJECT#* }" --jq .message > "$NOTES"
  [ -s "$NOTES" ] || die "$TAG has no message to use as release notes"
  set -- "$CHANNEL" --version "$VERSION"
fi

echo "== $* from $BRANCH @$SHORT, Mac build on $MAC_HOST"
sh "$RR_ROOT/scripts/rr/release.sh" "$@" --notes-file "$NOTES" --mac-host "$MAC_HOST" --publish
