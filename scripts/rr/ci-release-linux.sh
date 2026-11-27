#!/bin/sh
# The Linux half of a Bridgey by Round Robin release or nightly, on an RR CI Linux runner (GitHub's hosted
# ubuntu-24.04 for x86_64, ubuntu-24.04-arm for aarch64): the AppImage for the version scripts/rr/ci-release.sh then
# publishes, which it takes only with BRIDGEY_RELEASE_LINUX=1 (off until Linux ships).
#
#   scripts/rr/ci-release-linux.sh nightly OUTPUT
#   scripts/rr/ci-release-linux.sh tag OUTPUT       beta or stable from RR_CI_REF
#
# Builds with scripts/rr/build-linux.sh --quick (the verify lane ran every UI test on this revision). The output holds
# the AppImage under a fixed name (Bridgey-RR-linux-<arch>.AppImage), SHA256SUMS, release.env (the time, channel,
# version name, build number, tag and revision; ci-release.sh refuses a different revision or version) and
# linux.build-info (the toolchains). RR_CI_RELEASE_NOW, when set, gives the release time so every job derives the same
# version. No secrets: the AppImage is signed with the release key when ci-release.sh assembles the release.
set -eu
ROOT=$(cd "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/scripts/rr/common.sh"

MODE=${1:-}
OUTPUT=${2:-}
[ -n "$OUTPUT" ] || { sed -n '2,15p' "$0"; exit 2; }
case "$MODE" in
  nightly) set -- nightly ;;
  tag)
    ref=${RR_CI_REF:-}
    case "$ref" in refs/tags/v*) version=${ref#refs/tags/v} ;; *) die "RR_CI_REF must name the release tag (got '$ref')" ;; esac
    if printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$'; then set -- beta --version "$version"
    elif printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then set -- stable --version "$version"
    else die "v$version is neither a stable nor a beta tag"; fi
    ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
NOW=${RR_CI_RELEASE_NOW:-$(date -u +%Y-%m-%dT%H:%M:00Z)}
VALUES=$(python3 "$ROOT/scripts/rr/rrrelease.py" version "$@" --now "$NOW")
value() { printf '%s\n' "$VALUES" | sed -n "s/^$1=//p" | tr -d "'"; }
BRIDGEY_VERSION_NAME=$(value VERSION_NAME)
BRIDGEY_BUILD_NUMBER=$(value BUILD_NUMBER)
export BRIDGEY_VERSION_NAME BRIDGEY_BUILD_NUMBER
echo "== Linux for $(value CHANNEL) $BRIDGEY_VERSION_NAME build $BRIDGEY_BUILD_NUMBER"

sh "$ROOT/scripts/rr/build-linux.sh" --quick

ARCH=$(uname -m)
PREFIX=$(edition_value EDITION_ASSET_PREFIX)
mkdir -p "$OUTPUT"
name="$PREFIX-linux-$ARCH.AppImage"
cp "$ROOT/linux/out/$PREFIX-$BRIDGEY_VERSION_NAME-linux-$ARCH.AppImage" "$OUTPUT/$name"
(cd "$OUTPUT" && sha256sum "$name" > SHA256SUMS)
printf 'NOW=%s\nCHANNEL=%s\nVERSION_NAME=%s\nBUILD_NUMBER=%s\nTAG=%s\nREVISION=%s\n' "$NOW" "$(value CHANNEL)" "$BRIDGEY_VERSION_NAME" \
  "$BRIDGEY_BUILD_NUMBER" "$(value TAG)" "$(git -C "$ROOT" rev-parse HEAD)" > "$OUTPUT/release.env"
printf 'host=%s\nos=%s\nrust=%s\ngtk=%s\nlibadwaita=%s\n' "$(hostname)" "$(. /etc/os-release && echo "$PRETTY_NAME")" "$(rustc --version)" \
  "$(pkg-config --modversion gtk4)" "$(pkg-config --modversion libadwaita-1)" > "$OUTPUT/linux.build-info"
ls -l "$OUTPUT"
