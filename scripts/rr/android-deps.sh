#!/bin/sh
# Lists the resolved Android release dependencies (the SBOM input): Gradle's own dependency report
# for releaseRuntimeClasspath, written to <output.txt>. Needs the same JDK and Android SDK as the build
# and network or a warm Gradle cache; it compiles nothing and leaves the build untouched.
# Usage: BRIDGEY_VERSION_NAME=... BRIDGEY_BUILD_NUMBER=... scripts/rr/android-deps.sh <output.txt>
set -eu
. "$(dirname -- "$0")/common.sh"

OUTPUT=${1:?usage: android-deps.sh <output.txt>}
SLOT=""
command -v iieon-slot >/dev/null 2>&1 && SLOT=iieon-slot
mkdir -p "$(dirname -- "$OUTPUT")"
(
  cd "$RR_ROOT/android"
  env -u GH_TOKEN -u GITHUB_TOKEN $SLOT ./gradlew --console=plain -q :app:dependencies --configuration releaseRuntimeClasspath
) > "$OUTPUT" || { rm -f "$OUTPUT"; die "could not list the Android dependencies"; }
grep -q -e '^[+\\]--- ' "$OUTPUT" || { rm -f "$OUTPUT"; die "the Gradle dependency report has no dependencies"; }
echo "Android dependencies: $OUTPUT ($(grep -c -e '[+\\]--- ' "$OUTPUT") lines)"
