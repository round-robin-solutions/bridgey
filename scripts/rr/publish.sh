#!/bin/sh
# Publishes an assembled release directory (dist/<tag>) to GitHub Releases with gh.
# Stable is a normal release marked latest; beta and nightly are prereleases.
# Then overwrites the channel feed and appcast on the fixed `channels` release and
# keeps only the newest 7 nightly releases. Requires gh auth (GH_TOKEN) with write access
# and the release commit already pushed to the fork. A tag that already exists (a release
# started by pushing an annotated tag) is used as it is, if it points at the release commit.
# Usage: scripts/rr/publish.sh <dist-dir>
set -eu
. "$(dirname -- "$0")/common.sh"

DIST=${1:?usage: publish.sh <dist-dir>}
. "$DIST/release.env"
REPO=$(edition_value GITHUB_REPO)
CHANNELS_TAG=$(edition_value UPDATE_CHANNELS_TAG)
DISPLAY_NAME=$(edition_value EDITION_DISPLAY_NAME)
TARGET=$(git -C "$RR_ROOT" rev-parse HEAD)
if ! git -C "$RR_ROOT" branch -r --contains "$TARGET" 2>/dev/null | grep -q .; then
  # A CI checkout has no remote branches: ask GitHub whether the release branch contains it.
  BRANCH=$(edition_value RELEASE_BRANCH)
  case "$(gh api "repos/$REPO/compare/$BRANCH...$TARGET" --jq .status 2>/dev/null || true)" in
    identical|behind) ;;
    *) die "HEAD $TARGET is not on any pushed branch; push it first" ;;
  esac
fi

python3 "$RR_ROOT/scripts/rr/rrrelease.py" verify --dist "$DIST"

NOTES="$DIST/notes.md"
if [ ! -f "$NOTES" ]; then
  NOTES="$DIST/generated-notes.md"
  printf '%s %s (%s channel).\n\nBuilt on Bridgey by Semyon Mikhailov.\n' "$DISPLAY_NAME" "$VERSION_NAME" "$CHANNEL" > "$NOTES"
fi

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  [ "$CHANNEL" = nightly ] || die "release $TAG already exists"
  # A second nightly on the same day replaces the first.
  gh release delete "$TAG" -R "$REPO" --cleanup-tag --yes
fi

if [ "$CHANNEL" != nightly ] && OBJECT=$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq '.object.type + " " + .object.sha' 2>/dev/null); then
  TAGGED=${OBJECT#* }
  [ "${OBJECT%% *}" = tag ] && TAGGED=$(gh api "repos/$REPO/git/tags/$TAGGED" --jq .object.sha)
  [ "$TAGGED" = "$TARGET" ] || die "tag $TAG already exists and points at $TAGGED, not $TARGET"
  echo "using the existing tag $TAG"
fi

set -- "$DIST"/release/*
case "$CHANNEL" in
  stable) gh release create "$TAG" -R "$REPO" --target "$TARGET" --title "$DISPLAY_NAME $VERSION_NAME" --notes-file "$NOTES" --latest "$@" ;;
  *) gh release create "$TAG" -R "$REPO" --target "$TARGET" --title "$DISPLAY_NAME $VERSION_NAME" --notes-file "$NOTES" --prerelease --latest=false "$@" ;;
esac

# Release assets first, feeds second, so a feed never points at a missing file.
if ! gh release view "$CHANNELS_TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release create "$CHANNELS_TAG" -R "$REPO" --target "$TARGET" --prerelease --latest=false \
    --title "Update channels" \
    --notes "Machine-readable update feeds for $DISPLAY_NAME (stable.json, beta.json, nightly.json, appcast.xml). Not an installable release."
fi
set -- "$DIST/channels/$CHANNEL.json"
[ -f "$DIST/channels/appcast.xml" ] && set -- "$@" "$DIST/channels/appcast.xml"
gh release upload "$CHANNELS_TAG" -R "$REPO" --clobber "$@"

if [ "$CHANNEL" = nightly ]; then
  gh release list -R "$REPO" --limit 200 --json tagName --jq '.[].tagName' |
    grep '^nightly-[0-9]\{8\}$' | sort -r | tail -n +8 |
    while read -r old; do
      echo "removing old nightly $old"
      gh release delete "$old" -R "$REPO" --cleanup-tag --yes
    done
fi
echo "published https://github.com/$REPO/releases/tag/$TAG"
