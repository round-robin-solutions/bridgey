"""Tests for the browser extension's packaging (extensions/browser/build.py), its release assets, and a runner for
the extension's JavaScript tests and the native messaging helper's Rust tests when node and cargo are installed.
Run: python3 -m unittest discover -s scripts/rr/tests
"""

import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "rr"))

import rrrelease  # noqa: E402

spec = importlib.util.spec_from_file_location("browser_build", ROOT / "extensions" / "browser" / "build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

HOST = json.loads((ROOT / "extensions" / "browser" / "native-host.json").read_text(encoding="utf-8"))


def chromium_id(public_key_b64: str) -> str:
    """Chromium's extension ID: the first 32 hex digits of SHA-256 over the public key, written with a to p."""
    digest = hashlib.sha256(base64.b64decode(public_key_b64)).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in digest)


class ManifestTests(unittest.TestCase):
    def test_versions_browsers_accept(self):
        self.assertEqual(build.manifest_version("1.0.0"), "1.0.0.1000")
        self.assertEqual(build.manifest_version("1.0.0-beta.6"), "1.0.0.6")
        self.assertEqual(build.manifest_version("1.0.0-nightly.20261126"), "1.0.0.0")
        self.assertEqual(build.manifest_version("1.0.0-dev"), "1.0.0.0")
        self.assertEqual(build.manifest_version("1.2.3"), "1.2.3.1000")
        ordered = ["1.0.0-nightly.20261126", "1.0.0-beta.1", "1.0.0-beta.12", "1.0.0", "1.1.0-beta.1", "1.1.0"]
        keys = [tuple(int(p) for p in build.manifest_version(v).split(".")) for v in ordered]
        self.assertEqual(keys, sorted(keys))
        for bad in ("1.0", "v1.0.0", "1.0.0-beta.0", "1.0.0-beta.1000", "1.0.0-rc.1", "70000.0.0", "1.0.0-rr.1"):
            with self.assertRaises(build.BuildError, msg=bad):
                build.manifest_version(bad)

    def test_the_fixed_key_gives_the_id_the_native_host_allows(self):
        self.assertEqual(chromium_id(HOST["chromiumPublicKey"]), HOST["chromiumExtensionIds"][0])
        self.assertEqual(HOST["name"], "in.roundrobin.bridgey")

    def test_chrome_and_edge_manifests(self):
        for browser in ("chrome", "edge"):
            data = build.manifest(browser, "1.0.0-beta.7")
            self.assertEqual(data["manifest_version"], 3)
            self.assertEqual(data["background"], {"service_worker": "background.js"})
            self.assertEqual(data["key"], HOST["chromiumPublicKey"])
            self.assertEqual(data["version"], "1.0.0.7")
            self.assertEqual(data["version_name"], "1.0.0-beta.7")
            self.assertEqual(sorted(data["permissions"]), ["activeTab", "contextMenus", "nativeMessaging", "storage"])
            self.assertNotIn("host_permissions", data)
            self.assertNotIn("tabs", data["permissions"])
            self.assertNotIn("browser_specific_settings", data)
            self.assertNotIn("key", build.manifest(browser, "1.0.0", store=True))

    def test_firefox_manifest(self):
        data = build.manifest("firefox", "1.0.0")
        self.assertEqual(data["background"], {"scripts": ["lib.js", "background.js"]})
        gecko = data["browser_specific_settings"]["gecko"]
        self.assertEqual(gecko["id"], HOST["firefoxExtensionIds"][0])
        self.assertEqual(gecko["data_collection_permissions"], {"required": ["none"]})
        for key in ("key", "version_name", "minimum_chrome_version"):
            self.assertNotIn(key, data)

    def test_test_permission_is_opt_in(self):
        data = build.manifest("chrome", "1.0.0-dev", host_permissions=["http://127.0.0.1/*"])
        self.assertEqual(data["host_permissions"], ["http://127.0.0.1/*"])


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_packages_are_reproducible_and_complete(self):
        first = build.build("1.0.0-beta.7", self.out / "a")
        second = build.build("1.0.0-beta.7", self.out / "b")
        self.assertEqual([p.name for p in first], [
            "Bridgey-RR-1.0.0-beta.7-Chrome.zip", "Bridgey-RR-1.0.0-beta.7-Edge.zip", "Bridgey-RR-1.0.0-beta.7-Firefox.zip"])
        for a, b in zip(first, second):
            self.assertEqual(a.read_bytes(), b.read_bytes(), a.name)
        with zipfile.ZipFile(first[2]) as archive:
            names = archive.namelist()
            self.assertEqual(names, sorted(names))
            for required in ("manifest.json", "background.js", "lib.js", "popup.html", "popup.js", "popup.css",
                             "_locales/en/messages.json", "_locales/ru/messages.json", "icons/icon-128.png",
                             "fonts/Inter-OFL.txt", "LICENSE.txt"):
                self.assertIn(required, names)
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["browser_specific_settings"]["gecko"]["id"], "bridgey@roundrobin.in")
            for name in names:
                self.assertFalse(name.startswith("/") or ".." in name, name)

    def test_store_packages_drop_the_key(self):
        paths = build.build("1.0.0", self.out, store=True)
        self.assertEqual([p.name for p in paths], ["Bridgey-RR-1.0.0-Chrome-store.zip", "Bridgey-RR-1.0.0-Edge-store.zip"])
        with zipfile.ZipFile(paths[0]) as archive:
            self.assertNotIn("key", json.loads(archive.read("manifest.json")))

    def test_every_message_is_translated_and_used_keys_exist(self):
        package = build.files("chrome", "1.0.0", store=False, host_permissions=None)
        en = json.loads(package["_locales/en/messages.json"])
        ru = json.loads(package["_locales/ru/messages.json"])
        self.assertEqual(set(en), set(ru))
        self.assertLessEqual(len(en["extDescription"]["message"]), 132)
        self.assertLessEqual(len(ru["extDescription"]["message"]), 132)
        for key, entry in ru.items():
            self.assertEqual(entry["message"].count("$1"), en[key]["message"].count("$1"), key)
        broken = dict(package)
        broken["popup.js"] = package["popup.js"] + b"\nt('noSuchMessage');\n"
        with self.assertRaises(build.BuildError):
            build.check(broken)
        dashed = dict(package)
        dashed["popup.js"] = package["popup.js"] + "\n// a \u2014 dash\n".encode()
        with self.assertRaises(build.BuildError):
            build.check(dashed)

    def test_british_spelling_in_english_strings(self):
        text = (ROOT / "extensions/browser/src/_locales/en/messages.json").read_text(encoding="utf-8").lower()
        for american in ("color", "optimiz", "canceled", "favorite", "behavior", "license "):
            self.assertNotIn(american, text)


class ReleaseAssetTests(unittest.TestCase):
    def test_assemble_adds_the_extension_zips_to_the_sums_and_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            apk = root / "app.apk"
            apk.write_bytes(b"apk" * 50)
            zips = root / "browser"
            build.build("1.0.0-beta.7", zips)
            dist = root / "dist"
            argv = ["assemble", "--channel", "beta", "--version", "1.0.0-beta.7", "--build", "263300000", "--tag", "v1.0.0-beta.7",
                    "--dist", str(dist), "--apk", str(apk), "--published", "2026-11-26T00:00:00Z", "--browser-extensions", str(zips)]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(rrrelease.main(argv), 0)
            release = dist / "release"
            sums = (release / "SHA256SUMS").read_text()
            provenance = json.loads((release / "Bridgey-RR-1.0.0-beta.7-provenance.json").read_text())
            subjects = {s["name"] for s in provenance["subject"]}
            for label in ("Chrome", "Edge", "Firefox"):
                name = f"Bridgey-RR-1.0.0-beta.7-{label}.zip"
                self.assertTrue((release / name).is_file(), name)
                self.assertIn(name, sums)
                self.assertIn(name, subjects)
            feed = json.loads((dist / "channels" / "beta.json").read_text())
            self.assertNotIn("Chrome", json.dumps(feed))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(rrrelease.main(["verify", "--dist", str(dist)]), 0)
            (zips / "Bridgey-RR-1.0.0-beta.7-Edge.zip").unlink()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertNotEqual(rrrelease.main(argv), 0)


def cargo() -> str | None:
    found = shutil.which("cargo")
    if found:
        return found
    home = os.environ.get("RR_CI_HOST_HOME") or os.environ.get("HOME", "")
    candidate = Path(os.environ.get("CARGO_HOME", Path(home) / ".cargo")) / "bin" / "cargo"
    return str(candidate) if candidate.is_file() else None


class ToolchainTests(unittest.TestCase):
    """The extension's own tests (node --test) and the helper's (cargo test), where the tools exist."""

    def test_extension_javascript(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("node is not installed")
        tests = sorted(str(p) for p in (ROOT / "extensions/browser/test").glob("*.test.js"))
        result = subprocess.run([node, "--test", *tests], capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout[-4000:] + result.stderr[-2000:])

    def test_native_messaging_helper(self):
        tool = cargo()
        if not tool:
            self.skipTest("cargo is not installed")
        env = dict(os.environ)
        if os.environ.get("RR_CI_CPU"):
            env.setdefault("CARGO_BUILD_JOBS", os.environ["RR_CI_CPU"])
        result = subprocess.run([tool, "test", "--locked", "-p", "bridgey-browser-host", "--manifest-path", str(ROOT / "rust/Cargo.toml")],
                                capture_output=True, text=True, timeout=540, env=env)
        self.assertEqual(result.returncode, 0, result.stdout[-4000:] + result.stderr[-4000:])


if __name__ == "__main__":
    unittest.main()
