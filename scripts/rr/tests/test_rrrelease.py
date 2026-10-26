"""Tests for scripts/rr/rrrelease.py. Run: python3 -m unittest discover -s scripts/rr/tests

Set RR_UPDATE_FIXTURE=1 to rewrite scripts/rr/testdata/feed-sample (read by the Android and macOS tests).
"""

import base64
import datetime as dt
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import rrrelease  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

FIXTURE_DIR = Path(__file__).resolve().parents[1] / "testdata" / "feed-sample"
TEST_SEED = bytes(range(1, 33))


class ReleaseFixture:
    def __init__(self, root: Path):
        self.root = root
        self.key_file = root / "test.key"
        self.key_file.write_text(base64.b64encode(TEST_SEED).decode())
        self.public = rrrelease.public_key_b64(Ed25519PrivateKey.from_private_bytes(TEST_SEED))
        self.apk = root / "app-release.apk"
        self.apk.write_bytes(b"apk-bytes" * 100)
        self.dmg = root / "Bridgey-RR-macOS.dmg"
        self.dmg.write_bytes(b"dmg-bytes" * 100)
        self.zip = root / "Bridgey-RR-macOS.zip"
        self.zip.write_bytes(b"zip-bytes" * 100)
        self.notes = root / "notes.md"
        self.notes.write_text("Adds update channels.\nFixes <tags> & things.")

    def assemble(self, dist, channel, version, build, tag, previous=None, apk=True, mac=True, published="2026-10-25T13:15:00Z"):
        argv = [
            "assemble", "--channel", channel, "--version", version, "--build", str(build), "--tag", tag,
            "--dist", str(dist), "--notes-file", str(self.notes), "--published", published,
            "--ed-key", str(self.key_file), "--ed-public-key", self.public,
        ]
        if apk:
            argv += ["--apk", str(self.apk)]
        if mac:
            argv += ["--dmg", str(self.dmg), "--zip", str(self.zip)]
        if previous:
            argv += ["--previous-channels", str(previous)]
        return rrrelease.main(argv)


class VersionTests(unittest.TestCase):
    def test_build_number_is_monotonic_and_fits_version_code(self):
        moments = [
            dt.datetime(2026, 10, 25, 13, 15, tzinfo=dt.timezone.utc),
            dt.datetime(2026, 10, 25, 13, 16, tzinfo=dt.timezone.utc),
            dt.datetime(2026, 12, 31, 23, 59, tzinfo=dt.timezone.utc),
            dt.datetime(2027, 1, 1, 0, 0, tzinfo=dt.timezone.utc),
            dt.datetime(2099, 12, 31, 23, 59, tzinfo=dt.timezone.utc),
        ]
        numbers = [rrrelease.build_number(m) for m in moments]
        self.assertEqual(numbers[0], 262981315)
        self.assertEqual(numbers, sorted(numbers))
        self.assertEqual(len(set(numbers)), len(numbers))
        self.assertLess(numbers[-1], 2_100_000_000)

    def test_build_number_uses_utc(self):
        ist = dt.timezone(dt.timedelta(hours=5, minutes=30))
        self.assertEqual(rrrelease.build_number(dt.datetime(2026, 10, 25, 18, 45, tzinfo=ist)), 262981315)

    def test_versions_per_channel(self):
        now = dt.datetime(2026, 10, 25, 13, 15, tzinfo=dt.timezone.utc)
        self.assertEqual(rrrelease.resolve_version("stable", "0.6.0-rr.1", None, now), ("0.6.0-rr.1", "v0.6.0-rr.1"))
        self.assertEqual(rrrelease.resolve_version("beta", "0.6.0-rr.2", "0.6.0-rr.2-beta.1", now), ("0.6.0-rr.2-beta.1", "v0.6.0-rr.2-beta.1"))
        # One tag per build (UTC minute); the version name keeps the date the apps accept.
        self.assertEqual(rrrelease.resolve_version("nightly", "0.6.0-rr.2", None, now), ("0.6.0-rr.2-nightly.20261025", "nightly-20261025.1315"))
        later = dt.datetime(2026, 10, 25, 18, 2, tzinfo=dt.timezone.utc)
        self.assertEqual(rrrelease.resolve_version("nightly", "0.6.0-rr.2", None, later)[1], "nightly-20261025.1802")
        for channel, requested in [("beta", None), ("beta", "0.6.0-rr.2"), ("stable", "0.6.0-rr.2-beta.1"),
                                   ("nightly", "0.6.0-rr.2-nightly.20261025"), ("beta", "0.7.0-rr.1-beta.1"), ("canary", None)]:
            with self.assertRaises(rrrelease.ReleaseError, msg=f"{channel} {requested}"):
                rrrelease.resolve_version(channel, "0.6.0-rr.2", requested, now)


class AssembleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fixture = ReleaseFixture(self.root)
        self.props = rrrelease.load_properties()

    def tearDown(self):
        self.temp.cleanup()

    def test_assemble_writes_valid_feed_sums_and_signed_appcast(self):
        dist = self.root / "dist"
        self.assertEqual(self.fixture.assemble(dist, "beta", "0.6.0-rr.1-beta.1", 262981315, "v0.6.0-rr.1-beta.1"), 0)
        feed = json.loads((dist / "channels" / "beta.json").read_text())
        self.assertEqual(feed["android"]["versionCode"], 262981315)
        self.assertTrue(feed["android"]["url"].endswith("/v0.6.0-rr.1-beta.1/Bridgey-RR-0.6.0-rr.1-beta.1-Android.apk"))
        self.assertEqual(feed["macos"]["zip"]["sha256"], rrrelease.sha256_file(self.fixture.zip))
        sums = (dist / "release" / "SHA256SUMS").read_text().splitlines()
        self.assertEqual(len(sums), 3)
        items = rrrelease.parse_appcast((dist / "channels" / "appcast.xml").read_bytes())
        self.assertEqual([(i["channel"], i["version"]) for i in items], [("beta", "262981315")])
        self.assertIn("&lt;tags&gt;", items[0]["description"])
        report = rrrelease.verify(dist, self.props, self.fixture.public)
        self.assertIn("SHA256SUMS ok", report)
        self.assertTrue(any("EdDSA ok" in line for line in report))

    def test_tampered_zip_fails_verification(self):
        dist = self.root / "dist"
        self.fixture.assemble(dist, "beta", "0.6.0-rr.1-beta.1", 262981315, "v0.6.0-rr.1-beta.1")
        (dist / "release" / "Bridgey-RR-0.6.0-rr.1-beta.1-macOS.zip").write_bytes(b"evil")
        with self.assertRaises(rrrelease.ReleaseError):
            rrrelease.verify(dist, self.props, self.fixture.public)

    def test_wrong_key_is_refused(self):
        dist = self.root / "dist"
        other = base64.b64encode(bytes(32)).decode()
        code = rrrelease.main([
            "assemble", "--channel", "beta", "--version", "0.6.0-rr.1-beta.1", "--build", "1", "--tag", "t",
            "--dist", str(dist), "--dmg", str(self.fixture.dmg), "--zip", str(self.fixture.zip),
            "--ed-key", str(self.fixture.key_file), "--ed-public-key", other,
        ])
        self.assertEqual(code, 1)

    def test_appcast_merges_channels_and_keeps_newest(self):
        previous = self.root / "published"
        builds = []
        for day in range(1, 13):
            dist = self.root / f"n{day}"
            build = 263000000 + day * 10_000
            builds.append(build)
            version = f"0.6.0-rr.1-nightly.202610{day:02d}"
            self.fixture.assemble(dist, "nightly", version, build, f"nightly-202610{day:02d}",
                                  previous=previous if previous.exists() else None)
            previous.mkdir(exist_ok=True)
            for name in ("nightly.json", "appcast.xml"):
                (previous / name).write_bytes((dist / "channels" / name).read_bytes())
        dist = self.root / "stable"
        self.fixture.assemble(dist, "stable", "0.6.0-rr.1", 263200000, "v0.6.0-rr.1", previous=previous)
        items = rrrelease.parse_appcast((dist / "channels" / "appcast.xml").read_bytes())
        nightly = [int(i["version"]) for i in items if i["channel"] == "nightly"]
        self.assertEqual(nightly, sorted(builds, reverse=True)[:10])
        self.assertEqual(items[0]["channel"], "stable")
        self.assertNotIn("<sparkle:channel>stable", (dist / "channels" / "appcast.xml").read_text())

    def test_refuses_a_build_that_is_not_newer_than_published(self):
        published = self.root / "published"
        first = self.root / "first"
        self.fixture.assemble(first, "beta", "0.6.0-rr.1-beta.2", 263000000, "v0.6.0-rr.1-beta.2")
        published.mkdir()
        (published / "beta.json").write_bytes((first / "channels" / "beta.json").read_bytes())
        code = self.fixture.assemble(self.root / "second", "beta", "0.6.0-rr.1-beta.3", 262000000, "v0.6.0-rr.1-beta.3", previous=published)
        self.assertEqual(code, 1)

    def test_two_nightlies_on_one_day_both_publish_in_build_order(self):
        published = self.root / "published"
        first = self.root / "first"
        self.fixture.assemble(first, "nightly", "0.6.0-rr.1-nightly.20261026", 262990900, "nightly-20261026.0900")
        published.mkdir()
        for name in ("nightly.json", "appcast.xml"):
            (published / name).write_bytes((first / "channels" / name).read_bytes())
        second = self.root / "second"
        self.assertEqual(self.fixture.assemble(second, "nightly", "0.6.0-rr.1-nightly.20261026", 262991400, "nightly-20261026.1400", previous=published), 0)
        items = rrrelease.parse_appcast((second / "channels" / "appcast.xml").read_bytes())
        # Same version name, two builds: both stay, newest first, like the releases on GitHub.
        self.assertEqual([i["version"] for i in items if i["channel"] == "nightly"], ["262991400", "262990900"])
        older = self.root / "older"
        self.assertEqual(self.fixture.assemble(older, "nightly", "0.6.0-rr.1-nightly.20261026", 262990800, "nightly-20261026.0800", previous=published), 1)

    def publish_feeds(self, dist, published):
        published.mkdir(exist_ok=True)
        for name in ("beta.json", "nightly.json", "stable.json", "appcast.xml"):
            if (dist / "channels" / name).is_file():
                (published / name).write_bytes((dist / "channels" / name).read_bytes())

    def test_rebase_keeps_items_published_meanwhile(self):
        # A beta and a nightly both assembled from the same published feeds; the beta publishes first.
        start = self.root / "start"
        self.fixture.assemble(self.root / "s", "stable", "0.6.0-rr.1", 262900000, "v0.6.0-rr.1")
        self.publish_feeds(self.root / "s", start)
        beta = self.root / "beta"
        nightly = self.root / "nightly"
        self.fixture.assemble(beta, "beta", "0.6.0-rr.1-beta.1", 262980000, "v0.6.0-rr.1-beta.1", previous=start)
        self.fixture.assemble(nightly, "nightly", "0.6.0-rr.1-nightly.20261026", 262990900, "nightly-20261026.0900", previous=start)
        live = self.root / "live"
        self.publish_feeds(self.root / "s", live)
        self.assertEqual(rrrelease.main(["rebase", "--dist", str(beta), "--previous-channels", str(live)]), 0)
        self.publish_feeds(beta, live)
        # The nightly's own appcast predates the beta; rebasing on the live feeds keeps the beta item.
        self.assertEqual(rrrelease.main(["rebase", "--dist", str(nightly), "--previous-channels", str(live)]), 0)
        channels = [i["channel"] for i in rrrelease.parse_appcast((nightly / "channels" / "appcast.xml").read_bytes())]
        self.assertEqual(sorted(channels), ["beta", "nightly", "stable"])
        self.assertEqual(rrrelease.main(["verify", "--dist", str(nightly), "--ed-public-key", self.fixture.public]), 0)

    def test_rebase_refuses_when_a_newer_build_is_out_and_keeps_the_other_platform(self):
        live = self.root / "live"
        newer = self.root / "newer"
        self.fixture.assemble(newer, "nightly", "0.6.0-rr.1-nightly.20261026", 262991400, "nightly-20261026.1400")
        self.publish_feeds(newer, live)
        older = self.root / "older"
        self.fixture.assemble(older, "nightly", "0.6.0-rr.1-nightly.20261026", 262990900, "nightly-20261026.0900")
        self.assertEqual(rrrelease.main(["rebase", "--dist", str(older), "--previous-channels", str(live)]), 3)
        android_only = self.root / "android-only"
        self.fixture.assemble(android_only, "nightly", "0.6.0-rr.1-nightly.20261026", 262991500, "nightly-20261026.1500", mac=False)
        self.assertEqual(rrrelease.main(["rebase", "--dist", str(android_only), "--previous-channels", str(live)]), 0)
        feed = json.loads((android_only / "channels" / "nightly.json").read_text())
        self.assertEqual(feed["macos"]["build"], 262991400)
        self.assertFalse((android_only / "channels" / "appcast.xml").exists())

    def test_platform_missing_from_release_keeps_previous_entry(self):
        published = self.root / "published"
        first = self.root / "first"
        self.fixture.assemble(first, "beta", "0.6.0-rr.1-beta.1", 263000000, "v0.6.0-rr.1-beta.1")
        published.mkdir()
        (published / "beta.json").write_bytes((first / "channels" / "beta.json").read_bytes())
        second = self.root / "second"
        self.fixture.assemble(second, "beta", "0.6.0-rr.1-beta.2", 263010000, "v0.6.0-rr.1-beta.2", previous=published, mac=False)
        feed = json.loads((second / "channels" / "beta.json").read_text())
        self.assertEqual(feed["android"]["versionName"], "0.6.0-rr.1-beta.2")
        self.assertEqual(feed["macos"]["shortVersion"], "0.6.0-rr.1-beta.1")

    def test_validation_rejects_foreign_assets(self):
        dist = self.root / "dist"
        self.fixture.assemble(dist, "beta", "0.6.0-rr.1-beta.1", 262981315, "v0.6.0-rr.1-beta.1")
        feed = json.loads((dist / "channels" / "beta.json").read_text())
        feed["android"]["url"] = "https://evil.example/x.apk"
        with self.assertRaises(rrrelease.ReleaseError):
            rrrelease.validate_feed(feed, "beta", self.props["EDITION_APP_ID"], self.props["UPDATE_ASSET_URL_PREFIX"])

    def test_committed_fixture_is_current(self):
        dist = self.root / "fixture"
        self.fixture.assemble(dist, "beta", "0.6.0-rr.1-beta.1", 262981315, "v0.6.0-rr.1-beta.1")
        generated = (dist / "channels" / "beta.json").read_text()
        target = FIXTURE_DIR / "beta.json"
        if os.environ.get("RR_UPDATE_FIXTURE") == "1":
            FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
            target.write_text(generated)
        self.assertEqual(target.read_text(), generated, "run with RR_UPDATE_FIXTURE=1 to refresh the fixture")


if __name__ == "__main__":
    unittest.main()
