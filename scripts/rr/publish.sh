#!/bin/sh
# Publishes an assembled release directory (dist/<tag>) to GitHub Releases with gh.
# Stable is a normal release marked latest; beta and nightly are prereleases.
# Then overwrites the channel feed and appcast on the fixed `channels` release and
# keeps only the newest 10 nightly releases. Requires gh auth (GH_TOKEN) with write access
# and the release commit already pushed to the fork. A tag that already exists (a release
# started by pushing an annotated tag) is used as it is, if it points at the release commit.
#
# The feeds hold every channel (the appcast has stable, beta and nightly items), and nightlies
# publish from GitHub Actions while betas and stable publish from rr-dev-1. So the whole publish
# runs under one lock, the git ref refs/rr-ci/channels-lock (creating a ref is atomic on GitHub),
# and re-merges this release into the feeds downloaded under that lock (rrrelease.py rebase). A
# lock older than BRIDGEY_RR_LOCK_STALE_SECONDS (default 1800) is taken over.
# Usage: scripts/rr/publish.sh <dist-dir>
set -eu
. "$(dirname -- "$0")/common.sh"

DIST=${1:?usage: publish.sh <dist-dir>}
. "$DIST/release.env"
REPO=$(edition_value GITHUB_REPO)
CHANNELS_TAG=$(edition_value UPDATE_CHANNELS_TAG)
FEED_BASE=$(edition_value UPDATE_FEED_BASE_URL)
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

# ---- channels lock
HOLDER="$CHANNEL $TAG on ${RR_CI_HOLDER:-$(hostname)}"
. "$RR_ROOT/scripts/rr/channels-lock.sh"
trap release_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
acquire_lock
echo "holding the channels lock"

# ---- re-merge into the feeds as published now
FRESH="$DIST/fresh-channels"
rm -rf "$FRESH"
mkdir -p "$FRESH"
# Only a feed the channels release really lacks (the first release of a channel) may be missing; a
# download that fails for any other reason stops the release, so no channel's items are ever dropped.
if gh release view "$CHANNELS_TAG" -R "$REPO" >/dev/null 2>&1; then
  ASSETS=$(gh release view "$CHANNELS_TAG" -R "$REPO" --json assets --jq '.assets[].name') || die "could not list the channels assets"
else
  ASSETS=""
fi
for name in "$CHANNEL.json" appcast.xml; do
  printf '%s\n' "$ASSETS" | grep -qx "$name" || continue
  code=$(curl -sS -L -o "$FRESH/$name" -w '%{http_code}' "$FEED_BASE/$name?nocache=$(date +%s)") || die "could not download $name"
  [ "$code" = 200 ] || die "downloading $name returned HTTP $code"
done
set +e
python3 "$RR_ROOT/scripts/rr/rrrelease.py" rebase --dist "$DIST" --previous-channels "$FRESH"
status=$?
set -e
if [ $status -eq 3 ]; then
  echo "not published: a newer $CHANNEL build is already out"
  exit 3
fi
[ $status -eq 0 ] || die "could not merge into the published feeds"
python3 "$RR_ROOT/scripts/rr/rrrelease.py" verify --dist "$DIST"

# ---- release
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  die "release $TAG already exists"
fi
if [ "$CHANNEL" != nightly ] && OBJECT=$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq '.object.type + " " + .object.sha' 2>/dev/null); then
  TAGGED=${OBJECT#* }
  [ "${OBJECT%% *}" = tag ] && TAGGED=$(gh api "repos/$REPO/git/tags/$TAGGED" --jq .object.sha)
  [ "$TAGGED" = "$TARGET" ] || die "tag $TAG already exists and points at $TAGGED, not $TARGET"
  echo "using the existing tag $TAG"
fi

still_ours || die "lost the channels lock before publishing"
set -- "$DIST"/release/*
CREATED=""
undo_release() {
  # The release exists but its feeds were not updated: remove it so a retry starts clean. A tag that
  # existed before (a beta or stable started by pushing it) stays.
  [ -n "$CREATED" ] || return 0
  echo "removing $TAG: its feeds were not updated"
  if [ "$CHANNEL" = nightly ]; then gh release delete "$TAG" -R "$REPO" --cleanup-tag --yes || true
  else gh release delete "$TAG" -R "$REPO" --yes || true; fi
}
trap 'undo_release; release_lock' EXIT
case "$CHANNEL" in
  stable) gh release create "$TAG" -R "$REPO" --target "$TARGET" --title "$DISPLAY_NAME $VERSION_NAME" --notes-file "$NOTES" --latest "$@" ;;
  *) gh release create "$TAG" -R "$REPO" --target "$TARGET" --title "$DISPLAY_NAME $VERSION_NAME" --notes-file "$NOTES" --prerelease --latest=false "$@" ;;
esac
CREATED=1

# Release assets first, feeds second, so a feed never points at a missing file.
if ! gh release view "$CHANNELS_TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release create "$CHANNELS_TAG" -R "$REPO" --target "$TARGET" --prerelease --latest=false \
    --title "Update channels" \
    --notes "Machine-readable update feeds for $DISPLAY_NAME (stable.json, beta.json, nightly.json, appcast.xml). Not an installable release."
fi
set -- "$DIST/channels/$CHANNEL.json"
[ -f "$DIST/channels/appcast.xml" ] && set -- "$@" "$DIST/channels/appcast.xml"
still_ours || die "lost the channels lock before updating the feeds"
gh release upload "$CHANNELS_TAG" -R "$REPO" --clobber "$@"
CREATED=""

if [ "$CHANNEL" = nightly ]; then
  # Keep the newest 10 nightly releases (tags nightly-YYYYMMDD.HHMM, and the older nightly-YYYYMMDD).
  gh release list -R "$REPO" --limit 200 --json tagName --jq '.[].tagName' |
    grep -E '^nightly-[0-9]{8}(\.[0-9]{4})?$' | sort -r | tail -n +11 |
    while read -r old; do
      echo "removing old nightly $old"
      gh release delete "$old" -R "$REPO" --cleanup-tag --yes
    done
fi
release_lock
echo "published https://github.com/$REPO/releases/tag/$TAG"
