#!/bin/sh
# Release-build smoke test for macOS: builds the release app and its zip (the Sparkle update
# archive), unpacks the zip and launches that app for 10 s. Fails if the process exits or a new
# crash report for it appears.
#
# The app runs with a private home (HOME and CFFIXED_USER_HOME), so its preferences, support
# files and pairing file never touch a real install. Run it on a disposable runner (RR CI uses
# GitHub's macOS runners), not on a Mac where Bridgey is in use: both would claim port 42458.
#
# Usage: scripts/rr/release-smoke-macos.sh
set -eu
. "$(dirname -- "$0")/common.sh"

[ "$(uname -s)" = Darwin ] || die "run this on macOS"
WORK=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bridgey-release-smoke-macos
rm -rf "$WORK"
mkdir -p "$WORK/out" "$WORK/unzipped" "$WORK/home"
STARTED=$(date +%s)
APP_NAME=$(edition_value EDITION_MAC_APP_NAME)
PREFIX=$(edition_value EDITION_ASSET_PREFIX)

echo "== building the release app and zip"
(
  cd "$RR_ROOT/macos"
  BRIDGEY_VERSION_NAME="$(edition_value EDITION_NEXT_VERSION)-smoke" BRIDGEY_BUILD_NUMBER=1 OUTPUT_DIR="$WORK/out" sh ./package-release.sh
)
ZIP="$WORK/out/$PREFIX-macOS.zip"
[ -f "$ZIP" ] || die "the release zip was not produced"
echo "::rrci-metric build_seconds $(($(date +%s) - STARTED))"

ditto -x -k "$ZIP" "$WORK/unzipped"
APP="$WORK/unzipped/$APP_NAME.app"
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
[ -x "$EXE" ] || die "no executable in $APP"
codesign --verify --deep --strict "$APP"

REPORTS="$HOME/Library/Logs/DiagnosticReports"
MARK="$WORK/mark"
touch "$MARK"
sleep 1
echo "== launching $APP_NAME for 10 s with a private home"
HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home" "$EXE" > "$WORK/app.log" 2>&1 &
pid=$!
sleep 10
alive=0
kill -0 "$pid" 2>/dev/null && alive=1
new_reports=$(find "$REPORTS" /Library/Logs/DiagnosticReports -newer "$MARK" -type f \
  \( -name "*$(basename "$EXE")*" -o -name "*Bridgey*" \) 2>/dev/null || true)
[ $alive = 1 ] && kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

if [ $alive != 1 ] || [ -n "$new_reports" ]; then
  echo "FAIL: the app did not stay up for 10 s or wrote a crash report"
  echo "--- app output"; tail -n 60 "$WORK/app.log"
  for report in $new_reports; do echo "--- $report"; head -n 80 "$report"; done
  exit 1
fi
echo "::rrci-metric total_seconds $(($(date +%s) - STARTED))"
echo "release smoke passed: $APP_NAME stayed up for 10 s with no crash report"
