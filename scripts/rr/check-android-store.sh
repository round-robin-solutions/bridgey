#!/bin/sh
# Owned CI proof for both unsigned store variants; never loads signing credentials or publishes.
set -eu
. "$(dirname -- "$0")/common.sh"
. "$RR_ROOT/scripts/rr/rust-env.sh"

# Even when the invoking shell holds release credentials, these checks build unsigned artifacts.
unset ANDROID_STORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD BRIDGEY_ANDROID_KEYSTORE \
  BRIDGEY_ANDROID_STORE_PASSWORD BRIDGEY_ANDROID_KEY_ALIAS BRIDGEY_ANDROID_KEY_PASSWORD \
  BRIDGEY_PLAY_UPLOAD_KEYSTORE BRIDGEY_PLAY_UPLOAD_STORE_PASSWORD BRIDGEY_PLAY_UPLOAD_KEY_ALIAS BRIDGEY_PLAY_UPLOAD_KEY_PASSWORD \
  BRIDGEY_TEST_KEYSTORE BRIDGEY_TEST_STORE_PASSWORD BRIDGEY_TEST_KEY_ALIAS BRIDGEY_TEST_KEY_PASSWORD GH_TOKEN GITHUB_TOKEN

cd "$RR_ROOT/android"
archive_results() {
  mkdir -p .rrci-reports
  set --
  for directory in app/build/test-results/testPlayUnitTest app/build/test-results/testQaUnitTest; do
    [ ! -d "$directory" ] || set -- "$@" "$directory"
  done
  if [ "$#" -gt 0 ]; then
    if (ulimit -f 65536 && tar -czf .rrci-reports/store-test-results.tar.gz "$@"); then
      return 0
    else
      archive_rc=$?
      rm -f .rrci-reports/store-test-results.tar.gz
      return "$archive_rc"
    fi
  fi
  return 0
}
finish() {
  rc=$?
  trap - EXIT
  set +e
  if [ ! -f .rrci-reports/store-test-results.tar.gz ]; then
    archive_results
    archive_rc=$?
    [ "$rc" -ne 0 ] || rc=$archive_rc
  fi
  exit "$rc"
}
trap finish EXIT
mkdir -p .rrci-reports
rm -f .rrci-reports/store-test-results.tar.gz
# Finish checks before starting minification, so failed lint cannot leave R8 running.
./gradlew --console=plain --no-daemon -Dorg.gradle.workers.max="${RR_CI_CPU:-3}" \
  -Pkotlin.compiler.execution.strategy=in-process \
  :app:lintPlay :app:lintQa \
  :app:testPlayUnitTest --tests dev.bridgey.android.BuildGatesTest \
  :app:testQaUnitTest --tests dev.bridgey.android.BuildGatesTest
# Keep completed reports even if the packaging process later reaches its timeout.
archive_results
./gradlew --console=plain --no-daemon -Dorg.gradle.workers.max="${RR_CI_CPU:-3}" \
  -Pkotlin.compiler.execution.strategy=in-process \
  :app:bundlePlay :app:assembleQa

python3 - <<'PY'
import pathlib
import xml.etree.ElementTree as ET
import zipfile

root = pathlib.Path("app/build")
android = "{http://schemas.android.com/apk/res/android}"
removed = {
    "REQUEST_INSTALL_PACKAGES", "UPDATE_PACKAGES_WITHOUT_USER_ACTION",
    "READ_SMS", "SEND_SMS", "RECEIVE_SMS", "READ_CONTACTS",
    "READ_CALL_LOG", "WRITE_CALL_LOG", "PROCESS_OUTGOING_CALLS",
}
manifests = list((root / "intermediates/merged_manifests/play").rglob("AndroidManifest.xml"))
assert len(manifests) == 1, f"expected one merged Play manifest, found {len(manifests)}"
manifest = ET.parse(manifests[0]).getroot()
permissions = {p.get(android + "name") for p in manifest.findall("uses-permission")}
assert not ({"android.permission." + p for p in removed} & permissions), "restricted Play permission remains"
receivers = {r.get(android + "name") for r in manifest.findall("application/receiver")}
assert not any(r.endswith((".UpdateInstallReceiver", ".AutoUpdateLaterReceiver", ".SmsResultReceiver")) for r in receivers), "removed receiver remains"
bundle = root / "outputs/bundle/play/app-play.aab"
qa = root / "outputs/apk/qa/app-qa-unsigned.apk"
for artifact in (bundle, qa):
    assert artifact.is_file(), f"missing unsigned artifact: {artifact}"
    with zipfile.ZipFile(artifact) as archive:
        names = set(archive.namelist())
        prefix = "base/" if artifact.suffix == ".aab" else ""
        for abi in ("arm64-v8a", "x86_64"):
            assert f"{prefix}lib/{abi}/libbridgey_connect.so" in names, f"connection core absent for {abi} in {artifact}"
print("Play permissions/receivers and both native-core artifacts verified")
PY
