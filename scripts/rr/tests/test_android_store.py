"""Offline checks for signer isolation and rejecting invalid Play bundles before copying them."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


SOURCE = Path(__file__).resolve().parents[1]
JARSIGNER = shutil.which("jarsigner")
KEYTOOL = shutil.which("keytool")


class StoreSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts/rr"
        scripts.mkdir(parents=True)
        for name in ("common.sh", "rust-env.sh", "build-android-store.sh"):
            shutil.copyfile(SOURCE / name, scripts / name)
        (scripts / "rust-toolchain.sh").write_text("#!/bin/sh\nexit 0\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.certificate = hashlib.sha256(b"upload certificate").hexdigest()
        self.release = "1" * 64
        self.properties = self.root / "rr-edition.properties"
        self.properties.write_text(f"ANDROID_CERT_SHA256={self.release}\nANDROID_UPLOAD_CERT_SHA256={self.certificate}\nANDROID_TEST_CERT_SHA256={'2' * 64}\n")
        self.credentials = self.root / "credentials.json"
        self.credentials.write_text(json.dumps({"keys": {"upload": {"store": "upload.jks", "password": "upload-secret", "alias": "upload", "keyPassword": "upload-key-secret"}}}))
        sdk = self.root / "sdk/build-tools/36.0.0"
        sdk.mkdir(parents=True)
        for name in ("apksigner", "aapt2"):
            self.executable(sdk / name, "#!/bin/sh\nexit 0\n")
        android = self.root / "android"
        android.mkdir()
        self.executable(android / "gradlew", """#!/usr/bin/env python3
import json, os, pathlib
pathlib.Path(os.environ['TEST_CAPTURE']).write_text(json.dumps(dict(os.environ)))
p = pathlib.Path('app/build/outputs/bundle/play/app-play.aab')
p.parent.mkdir(parents=True, exist_ok=True)
p.write_bytes(b'bundle')
""")
        self.executable(self.bin / "unzip", """#!/bin/sh
case "$3" in META-INF/*) printf 'upload certificate';; *) printf 'android.permission.INTERNET';; esac
""")
        self.executable(self.bin / "openssl", "#!/bin/sh\ncat\n")
        self.executable(self.bin / "jarsigner", "#!/bin/sh\nexit \"${TEST_SIGNATURE_EXIT:-0}\"\n")
        self.executable(self.bin / "iieon-slot", '#!/bin/sh\nexec "$@"\n')
        self.capture = self.root / "environment.json"
        self.output = self.root / "play.aab"
        self.environment = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "ANDROID_HOME": str(self.root / "sdk"),
            "BRIDGEY_SIGNING_CREDENTIALS": str(self.credentials),
            "BRIDGEY_VERSION_NAME": "0.10.0-rr.1-test",
            "BRIDGEY_BUILD_NUMBER": "123",
            "TEST_CAPTURE": str(self.capture),
            "BRIDGEY_ANDROID_STORE_PASSWORD": "release-secret",
            "BRIDGEY_TEST_STORE_PASSWORD": "other-test-secret",
        }

    @staticmethod
    def executable(path, content):
        path.write_text(content)
        path.chmod(0o755)

    def run_play(self):
        return subprocess.run(["sh", str(self.root / "scripts/rr/build-android-store.sh"), "play", str(self.output)], env=self.environment, text=True, capture_output=True)

    def test_only_upload_credentials_reach_play_gradle(self):
        result = self.run_play()
        self.assertEqual(0, result.returncode, result.stderr)
        captured = json.loads(self.capture.read_text())
        self.assertEqual("upload-secret", captured["BRIDGEY_PLAY_UPLOAD_STORE_PASSWORD"])
        self.assertNotIn("BRIDGEY_ANDROID_STORE_PASSWORD", captured)
        self.assertNotIn("BRIDGEY_TEST_STORE_PASSWORD", captured)
        self.assertTrue(self.output.exists())
        self.assertNotIn("upload-secret", result.stdout + result.stderr)

    def test_invalid_bundle_signature_is_rejected_before_copy(self):
        self.environment["TEST_SIGNATURE_EXIT"] = "1"
        result = self.run_play()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("bundle signature is invalid", result.stderr)
        self.assertFalse(self.output.exists())

    def test_release_certificate_cannot_be_the_upload_certificate(self):
        self.properties.write_text(f"ANDROID_CERT_SHA256={self.release}\nANDROID_UPLOAD_CERT_SHA256={':'.join([self.release[i:i+2].upper() for i in range(0, 64, 2)])}\n")
        result = self.run_play()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("is the release certificate", result.stderr)
        self.assertFalse(self.capture.exists())
        self.assertFalse(self.output.exists())

    @unittest.skipUnless(JARSIGNER and KEYTOOL, "JDK signing tools are unavailable")
    def test_unsigned_added_entry_is_rejected_with_the_expected_selfsigned_role(self):
        # Ordinary jarsigner verification returns success for this case. Strict verification
        # must accept our selfsigned upload role, then reject an entry added after signing.
        store = self.root / "upload.p12"
        bundle = self.root / "signed.aab"
        password = "temporary-fixture-only"
        self.environment["TEST_FIXTURE_PASSWORD"] = password
        generated = subprocess.run([
            KEYTOOL, "-genkeypair", "-alias", "upload", "-keyalg", "EC", "-dname", "CN=Bridgey offline fixture",
            "-validity", "2", "-storetype", "PKCS12", "-keystore", str(store),
            "-storepass:env", "TEST_FIXTURE_PASSWORD",
        ], env=self.environment, capture_output=True, text=True)
        self.assertEqual(0, generated.returncode, "fixture key generation failed")
        with zipfile.ZipFile(bundle, "w") as archive:
            archive.writestr("base/data.txt", "signed entry")
        signed = subprocess.run([
            JARSIGNER, "-keystore", str(store), "-storepass:env", "TEST_FIXTURE_PASSWORD", str(bundle), "upload",
        ], env=self.environment, capture_output=True, text=True)
        self.assertEqual(0, signed.returncode, "fixture signing failed")
        self.credentials.write_text(json.dumps({"keys": {"upload": {
            "store": str(store), "password": password, "alias": "upload", "keyPassword": password,
        }}}))
        (self.bin / "jarsigner").unlink()
        self.environment["TEST_SIGNED_BUNDLE"] = str(bundle)
        self.executable(self.root / "android/gradlew", """#!/usr/bin/env python3
import os, pathlib, shutil
p = pathlib.Path('app/build/outputs/bundle/play/app-play.aab')
p.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(os.environ['TEST_SIGNED_BUNDLE'], p)
""")
        result = self.run_play()
        self.assertEqual(0, result.returncode, "valid selfsigned upload role was rejected")
        self.output.unlink()
        with zipfile.ZipFile(bundle, "a") as archive:
            archive.writestr("base/unsigned.txt", "added after signing")
        result = self.run_play()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("bundle signature is invalid", result.stderr)
        self.assertFalse(self.output.exists())
