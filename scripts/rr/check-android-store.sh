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
./gradlew --console=plain --no-daemon -Dorg.gradle.workers.max="${RR_CI_CPU:-3}" \
  -Pkotlin.compiler.execution.strategy=in-process \
  :app:lintPlay :app:lintQa \
  :app:testPlayUnitTest --tests dev.bridgey.android.BuildGatesTest \
  :app:testQaUnitTest --tests dev.bridgey.android.BuildGatesTest \
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

mkdir -p .rrci-reports
tar -czf .rrci-reports/store-test-results.tar.gz \
  app/build/test-results/testPlayUnitTest app/build/test-results/testQaUnitTest
