#!/bin/sh
# Prints nightly release notes: the commit subjects on the release branch since the newest nightly
# or beta release (whichever came last), newest last. Reads GitHub through gh (GH_TOKEN).
# Usage: scripts/rr/release-notes.sh <revision>
set -eu
. "$(dirname -- "$0")/common.sh"

HEAD=${1:?usage: release-notes.sh <revision>}
REPO=$(edition_value GITHUB_REPO)
BRANCH=$(edition_value RELEASE_BRANCH)
SHORT=$(printf '%.7s' "$HEAD")

# Newest nightly or beta release by creation time (nightly-YYYYMMDD[.HHMM], v<x>-rr.N-beta.M).
PREVIOUS=$(gh release list -R "$REPO" --limit 100 --json tagName,createdAt \
  --jq '[.[] | select(.tagName | test("^nightly-[0-9]{8}([.][0-9]{4})?$|^v[0-9.]+-rr[.][0-9]+-beta[.][0-9]+$"))] | sort_by(.createdAt) | last | .tagName // ""')

printf 'Nightly build of %s at %s.\n\n' "$BRANCH" "$SHORT"
if [ -n "$PREVIOUS" ]; then
  REF=$(gh api "repos/$REPO/git/ref/tags/$PREVIOUS" --jq '.object.type + " " + .object.sha')
  BASE=${REF#* }
  [ "${REF%% *}" = tag ] && BASE=$(gh api "repos/$REPO/git/tags/$BASE" --jq .object.sha)
  if [ "$BASE" = "$HEAD" ]; then
    printf 'No new commits since %s.\n' "$PREVIOUS"
    exit 0
  fi
  STATUS=$(gh api "repos/$REPO/compare/$BASE...$HEAD" --jq .status)
  if [ "$STATUS" = ahead ]; then
    printf 'Changes since %s:\n\n' "$PREVIOUS"
    gh api "repos/$REPO/compare/$BASE...$HEAD" --jq '.commits[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"' | tail -n 100
    exit 0
  fi
fi
printf 'Recent changes:\n\n'
gh api "repos/$REPO/commits?sha=$HEAD&per_page=20" --jq 'reverse | .[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"'
