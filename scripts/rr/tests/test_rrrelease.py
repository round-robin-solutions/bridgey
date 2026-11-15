"""Tests for scripts/rr/rrrelease.py. Run: python3 -m unittest discover -s scripts/rr/tests

Set RR_UPDATE_FIXTURE=1 to rewrite scripts/rr/testdata/feed-sample/{stable,beta,nightly}.json (read by the
Android and macOS tests). legacy-0.11-*.* there are the feeds as published for 0.11.0-rr.1 Beta 3; keep them.
"""

import base64
import contextlib
import datetime as dt
import io
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import rrrelease  # noqa: E402
import versions  # noqa: E402
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
        now = dt.datetime(2026, 11, 16, 13, 15, tzinfo=dt.timezone.utc)
        self.assertEqual(rrrelease.resolve_version("stable", "1.0.0", None, now), ("1.0.0", "v1.0.0"))
        self.assertEqual(rrrelease.resolve_version("beta", "1.0.0", "1.0.0-beta.1", now), ("1.0.0-beta.1", "v1.0.0-beta.1"))
        # One tag per build (UTC minute); the version name keeps the date the apps accept.
        self.assertEqual(rrrelease.resolve_version("nightly", "1.1.0", None, now), ("1.1.0-nightly.20261116", "nightly-20261116.1315"))
        later = dt.datetime(2026, 11, 16, 18, 2, tzinfo=dt.timezone.utc)
        self.assertEqual(rrrelease.resolve_version("nightly", "1.0.0", None, later)[1], "nightly-20261116.1802")
        for channel, requested in [("beta", None), ("beta", "1.0.0"), ("stable", "1.0.0-beta.1"),
                                   ("nightly", "1.0.0-nightly.20261116"), ("beta", "1.1.0-beta.1"), ("canary", None),
                                   # New releases never use the pre-1.0 form.
                                   ("beta", "1.0.0-rr.1-beta.1"), ("stable", "1.0.0-rr.1")]:
            with self.assertRaises(rrrelease.ReleaseError, msg=f"{channel} {requested}"):
                rrrelease.resolve_version(channel, "1.0.0", requested, now)
        with self.assertRaises(rrrelease.ReleaseError):
            rrrelease.resolve_version("beta", "0.11.0-rr.1", "0.11.0-rr.1-beta.4", now)

    def test_version_command_prints_store_and_display_versions(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(rrrelease.main(["version", "beta", "--version", "1.0.0-beta.3", "--now", "2026-11-16T12:00:00Z"]), 0)
        env = dict(line.split("=", 1) for line in out.getvalue().splitlines())
        self.assertEqual(env["VERSION_NAME"], "1.0.0-beta.3")
        self.assertEqual(env["BUILD_NUMBER"], "263201200")
        self.assertEqual(env["STORE_VERSION"], "1.0.0")
        self.assertEqual(env["DISPLAY_VERSION"], "'1.0 Beta 3'")


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
        self.assertEqual(self.fixture.assemble(dist, "beta", "1.0.0-beta.1", 262981315, "v1.0.0-beta.1"), 0)
        feed = json.loads((dist / "channels" / "beta.json").read_text())
        self.assertEqual(feed["android"]["versionCode"], 262981315)
        self.assertTrue(feed["android"]["url"].endswith("/v1.0.0-beta.1/Bridgey-RR-1.0.0-beta.1-Android.apk"))
        self.assertEqual(feed["macos"]["zip"]["sha256"], rrrelease.sha256_file(self.fixture.zip))
        sums = (dist / "release" / "SHA256SUMS").read_text().splitlines()
        self.assertEqual(len(sums), 5)  # APK, DMG, ZIP, the macOS SBOM and the provenance file
        items = rrrelease.parse_appcast((dist / "channels" / "appcast.xml").read_bytes())
        self.assertEqual([(i["channel"], i["version"]) for i in items], [("beta", "262981315")])
        self.assertIn("&lt;tags&gt;", items[0]["description"])
        report = rrrelease.verify(dist, self.props, self.fixture.public)
        self.assertIn("SHA256SUMS ok", report)
        self.assertTrue(any("EdDSA ok" in line for line in report))

    def test_tampered_zip_fails_verification(self):
        dist = self.root / "dist"
        self.fixture.assemble(dist, "beta", "1.0.0-beta.1", 262981315, "v1.0.0-beta.1")
        (dist / "release" / "Bridgey-RR-1.0.0-beta.1-macOS.zip").write_bytes(b"evil")
        with self.assertRaises(rrrelease.ReleaseError):
            rrrelease.verify(dist, self.props, self.fixture.public)

    def test_wrong_key_is_refused(self):
        dist = self.root / "dist"
        other = base64.b64encode(bytes(32)).decode()
        code = rrrelease.main([
            "assemble", "--channel", "beta", "--version", "1.0.0-beta.1", "--build", "1", "--tag", "t",
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
            version = f"1.0.0-nightly.202610{day:02d}"
            self.fixture.assemble(dist, "nightly", version, build, f"nightly-202610{day:02d}",
                                  previous=previous if previous.exists() else None)
            previous.mkdir(exist_ok=True)
            for name in ("nightly.json", "appcast.xml"):
                (previous / name).write_bytes((dist / "channels" / name).read_bytes())
        dist = self.root / "stable"
        self.fixture.assemble(dist, "stable", "1.0.0", 263200000, "v1.0.0", previous=previous)
        items = rrrelease.parse_appcast((dist / "channels" / "appcast.xml").read_bytes())
        nightly = [int(i["version"]) for i in items if i["channel"] == "nightly"]
        self.assertEqual(nightly, sorted(builds, reverse=True)[:10])
        self.assertEqual(items[0]["channel"], "stable")
        self.assertNotIn("<sparkle:channel>stable", (dist / "channels" / "appcast.xml").read_text())

    def test_refuses_a_build_that_is_not_newer_than_published(self):
        published = self.root / "published"
        first = self.root / "first"
        self.fixture.assemble(first, "beta", "1.0.0-beta.2", 263000000, "v1.0.0-beta.2")
        published.mkdir()
        (published / "beta.json").write_bytes((first / "channels" / "beta.json").read_bytes())
        code = self.fixture.assemble(self.root / "second", "beta", "1.0.0-beta.3", 262000000, "v1.0.0-beta.3", previous=published)
        self.assertEqual(code, 1)

    def test_two_nightlies_on_one_day_both_publish_in_build_order(self):
        published = self.root / "published"
        first = self.root / "first"
        self.fixture.assemble(first, "nightly", "1.0.0-nightly.20261026", 262990900, "nightly-20261026.0900")
        published.mkdir()
        for name in ("nightly.json", "appcast.xml"):
            (published / name).write_bytes((first / "channels" / name).read_bytes())
        second = self.root / "second"
        self.assertEqual(self.fixture.assemble(second, "nightly", "1.0.0-nightly.20261026", 262991400, "nightly-20261026.1400", previous=published), 0)
        items = rrrelease.parse_appcast((second / "channels" / "appcast.xml").read_bytes())
        # Same version name, two builds: both stay, newest first, like the releases on GitHub.
        self.assertEqual([i["version"] for i in items if i["channel"] == "nightly"], ["262991400", "262990900"])
        older = self.root / "older"
        self.assertEqual(self.fixture.assemble(older, "nightly", "1.0.0-nightly.20261026", 262990800, "nightly-20261026.0800", previous=published), 1)

    def publish_feeds(self, dist, published):
        published.mkdir(exist_ok=True)
        for name in ("beta.json", "nightly.json", "stable.json", "appcast.xml"):
            if (dist / "channels" / name).is_file():
                (published / name).write_bytes((dist / "channels" / name).read_bytes())

    def test_rebase_keeps_items_published_meanwhile(self):
        # A beta and a nightly both assembled from the same published feeds; the beta publishes first.
        start = self.root / "start"
        self.fixture.assemble(self.root / "s", "stable", "1.0.0", 262900000, "v1.0.0")
        self.publish_feeds(self.root / "s", start)
        beta = self.root / "beta"
        nightly = self.root / "nightly"
        self.fixture.assemble(beta, "beta", "1.0.0-beta.1", 262980000, "v1.0.0-beta.1", previous=start)
        self.fixture.assemble(nightly, "nightly", "1.0.0-nightly.20261026", 262990900, "nightly-20261026.0900", previous=start)
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
        self.fixture.assemble(newer, "nightly", "1.0.0-nightly.20261026", 262991400, "nightly-20261026.1400")
        self.publish_feeds(newer, live)
        older = self.root / "older"
        self.fixture.assemble(older, "nightly", "1.0.0-nightly.20261026", 262990900, "nightly-20261026.0900")
        self.assertEqual(rrrelease.main(["rebase", "--dist", str(older), "--previous-channels", str(live)]), 3)
        android_only = self.root / "android-only"
        self.fixture.assemble(android_only, "nightly", "1.0.0-nightly.20261026", 262991500, "nightly-20261026.1500", mac=False)
        self.assertEqual(rrrelease.main(["rebase", "--dist", str(android_only), "--previous-channels", str(live)]), 0)
        feed = json.loads((android_only / "channels" / "nightly.json").read_text())
        self.assertEqual(feed["macos"]["build"], 262991400)
        self.assertFalse((android_only / "channels" / "appcast.xml").exists())

    def test_platform_missing_from_release_keeps_previous_entry(self):
        published = self.root / "published"
        first = self.root / "first"
        self.fixture.assemble(first, "beta", "1.0.0-beta.1", 263000000, "v1.0.0-beta.1")
        published.mkdir()
        (published / "beta.json").write_bytes((first / "channels" / "beta.json").read_bytes())
        second = self.root / "second"
        self.fixture.assemble(second, "beta", "1.0.0-beta.2", 263010000, "v1.0.0-beta.2", previous=published, mac=False)
        feed = json.loads((second / "channels" / "beta.json").read_text())
        self.assertEqual(feed["android"]["version"], "1.0.0-beta.2")
        self.assertEqual(feed["android"]["versionName"], "1.0.0-rr.1-beta.2")
        self.assertEqual(feed["macos"]["version"], "1.0.0-beta.1")
        self.assertEqual(feed["macos"]["shortVersion"], "1.0.0-rr.1-beta.1")

    def test_validation_rejects_foreign_assets(self):
        dist = self.root / "dist"
        self.fixture.assemble(dist, "beta", "1.0.0-beta.1", 262981315, "v1.0.0-beta.1")
        feed = json.loads((dist / "channels" / "beta.json").read_text())
        feed["android"]["url"] = "https://evil.example/x.apk"
        with self.assertRaises(rrrelease.ReleaseError):
            rrrelease.validate_feed(feed, "beta", self.props["EDITION_APP_ID"], self.props["UPDATE_ASSET_URL_PREFIX"])

    def test_committed_fixtures_are_current(self):
        # One feed per channel in the 1.0 scheme, read by the Android and macOS parser tests (and by their
        # copies of the 0.11.0-rr.1 Beta 3 parser). legacy-0.11-*.* are the feeds as published for Beta 3.
        for channel, version, build, tag in FIXTURES:
            dist = self.root / f"fixture-{channel}"
            self.fixture.assemble(dist, channel, version, build, tag, published="2026-11-16T12:00:00Z")
            generated = (dist / "channels" / f"{channel}.json").read_text()
            target = FIXTURE_DIR / f"{channel}.json"
            if os.environ.get("RR_UPDATE_FIXTURE") == "1":
                FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
                target.write_text(generated)
            self.assertEqual(target.read_text(), generated, "run with RR_UPDATE_FIXTURE=1 to refresh the fixture")


# 0.11.0-rr.1 Beta 3, the build on every device when 1.0 started, and every 0.x build before it check feed
# names with this pattern and then the channel suffix (UpdateFeeds in UpdateLogic.kt and UpdateLogic.swift at
# v0.11.0-rr.1-beta.3). Android skips a feed that fails; it orders and installs by versionCode only.
BETA3_PATTERN = re.compile(r"^\d+\.\d+\.\d+-rr\.\d+(-(beta\.\d+|nightly\.\d{8}))?$")
BETA3_BUILD = 263191654
APP_ID = "in.roundrobin.bridgey"
ASSET_PREFIX = "https://github.com/round-robin-solutions/bridgey/releases/download/"


def beta3_name_matches(name: str, channel: str) -> bool:
    if not BETA3_PATTERN.match(name):
        return False
    return {"stable": "-beta." not in name and "-nightly." not in name, "beta": "-beta." in name, "nightly": "-nightly." in name}[channel]


def beta3_android(feed: dict, channel: str):
    """UpdateFeeds.parseAndroid of Beta 3: (versionName, versionCode), None without Android, raises otherwise."""
    if feed["schema"] != 1 or feed["app"] != APP_ID or feed["channel"] != channel:
        raise ValueError("wrong feed")
    android = feed.get("android")
    if android is None:
        return None
    if not beta3_name_matches(android["versionName"], channel):
        raise ValueError(f"Version {android['versionName']} does not belong to {channel}")
    if not 0 < android["versionCode"] <= 2**31 - 1 or not android["url"].startswith(ASSET_PREFIX):
        raise ValueError("bad entry")
    if not re.match(r"^[0-9a-f]{64}$", android["sha256"]) or not 0 < android["size"] <= 150 * 1024 * 1024:
        raise ValueError("bad asset")
    return android["versionName"], android["versionCode"]


def beta3_macos(feed: dict, channel: str):
    """UpdateFeeds.parse of the Beta 3 Mac app (used by its tests; Sparkle reads the appcast)."""
    macos = feed.get("macos")
    if macos is None:
        return None
    if not beta3_name_matches(macos["shortVersion"], channel) or macos["build"] <= 0:
        raise ValueError(f"Version {macos['shortVersion']} does not belong to {channel}")
    return macos["shortVersion"], macos["build"]


class Beta3CompatibilityTests(unittest.TestCase):
    """Every device runs 0.11.0-rr.1 Beta 3 when 1.0 starts; it must see and order the 1.0 releases."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fixture = ReleaseFixture(self.root)
        self.props = rrrelease.load_properties()
        self.published = self.root / "published"
        self.published.mkdir()
        (self.published / "beta.json").write_bytes((FIXTURE_DIR / "legacy-0.11-beta.json").read_bytes())
        (self.published / "appcast.xml").write_bytes((FIXTURE_DIR / "legacy-0.11-appcast.xml").read_bytes())

    def tearDown(self):
        self.temp.cleanup()

    def test_beta3_reads_every_new_channel_feed_and_takes_the_newer_build(self):
        for channel, version, build, _ in FIXTURES:
            with self.subTest(channel=channel):
                feed = json.loads((FIXTURE_DIR / f"{channel}.json").read_text())
                name, code = beta3_android(feed, channel)
                self.assertEqual(name, versions.legacy_name(version))
                self.assertEqual(feed["android"]["version"], version)
                self.assertGreater(code, BETA3_BUILD)
                self.assertEqual(beta3_macos(feed, channel), (versions.legacy_name(version), build))
        # A Beta 3 phone on Beta reads stable.json and beta.json and installs the highest versionCode.
        candidates = [beta3_android(json.loads((FIXTURE_DIR / f"{c}.json").read_text()), c) for c in ("stable", "beta")]
        self.assertEqual(max(code for _, code in candidates if code > BETA3_BUILD), max(b for c, _, b, _ in FIXTURES if c != "nightly"))

    def test_beta3_would_have_skipped_a_feed_with_the_plain_name(self):
        # Why versionName keeps the old form: the plain 1.0 name fails Beta 3's pattern.
        for name, channel in (("1.0.0-beta.1", "beta"), ("1.0.0", "stable"), ("1.0.0-nightly.20261116", "nightly")):
            self.assertFalse(beta3_name_matches(name, channel))
            self.assertTrue(beta3_name_matches(versions.legacy_name(name), channel))

    def test_first_beta_merges_into_the_feeds_published_for_beta3(self):
        dist = self.root / "b1"
        self.assertEqual(self.fixture.assemble(dist, "beta", "1.0.0-beta.1", 263201200, "v1.0.0-beta.1", previous=self.published), 0)
        self.assertEqual(rrrelease.main(["verify", "--dist", str(dist), "--ed-public-key", self.fixture.public]), 0)
        items = rrrelease.parse_appcast((dist / "channels" / "appcast.xml").read_bytes())
        self.assertEqual(items[0]["shortVersion"], "1.0.0-beta.1")
        self.assertEqual(items[0]["channel"], "beta")
        # Sparkle compares sparkle:version (the build) with CFBundleVersion: the new item is newer than Beta 3's.
        self.assertGreater(int(items[0]["version"]), BETA3_BUILD)
        self.assertIn("0.11.0-rr.1-beta.3", [i["shortVersion"] for i in items])
        self.assertEqual([int(i["version"]) for i in items], sorted((int(i["version"]) for i in items), reverse=True))
        self.assertLessEqual(sum(1 for i in items if i["channel"] == "beta"), rrrelease.APPCAST_RETENTION["beta"])
        # And a rebase on the same published feeds (publish.sh) gives the same result.
        self.assertEqual(rrrelease.main(["rebase", "--dist", str(dist), "--previous-channels", str(self.published)]), 0)
        feed = json.loads((dist / "channels" / "beta.json").read_text())
        self.assertEqual(beta3_android(feed, "beta"), ("1.0.0-rr.1-beta.1", 263201200))

    def test_a_build_older_than_beta3_is_refused(self):
        code = self.fixture.assemble(self.root / "old", "beta", "1.0.0-beta.1", BETA3_BUILD - 1, "v1.0.0-beta.1", previous=self.published)
        self.assertEqual(code, 1)

    def test_published_beta3_feed_is_still_valid(self):
        feed = json.loads((FIXTURE_DIR / "legacy-0.11-beta.json").read_text())
        rrrelease.validate_feed(feed, "beta", self.props["EDITION_APP_ID"], self.props["UPDATE_ASSET_URL_PREFIX"])
        self.assertEqual(rrrelease.entry_version(feed["android"], "versionName"), "0.11.0-rr.1-beta.3")

    def test_feed_names_must_stay_readable_by_beta3(self):
        dist = self.root / "dist"
        self.fixture.assemble(dist, "beta", "1.0.0-beta.1", 263201200, "v1.0.0-beta.1")
        good = json.loads((dist / "channels" / "beta.json").read_text())
        for platform, key, bad in (("android", "versionName", "1.0.0-beta.1"), ("android", "versionName", "1.0.0-rr.1-beta.2"),
                                   ("macos", "shortVersion", "1.0.0-beta.1"), ("android", "version", "1.0.0-beta.x")):
            with self.subTest(platform=platform, key=key, value=bad):
                feed = json.loads(json.dumps(good))
                feed[platform][key] = bad
                with self.assertRaises(rrrelease.ReleaseError):
                    rrrelease.validate_feed(feed, "beta", self.props["EDITION_APP_ID"], self.props["UPDATE_ASSET_URL_PREFIX"])

    def test_promotion_rebuild_reaches_beta_and_stable_users(self):
        beta = self.root / "beta"
        self.fixture.assemble(beta, "beta", "1.0.0-beta.3", 263220900, "v1.0.0-beta.3", previous=self.published)
        live = self.root / "live"
        live.mkdir()
        for name in ("beta.json", "appcast.xml"):
            (live / name).write_bytes((beta / "channels" / name).read_bytes())
        stable = self.root / "stable"
        self.assertEqual(self.fixture.assemble(stable, "stable", "1.0.0", 263241200, "v1.0.0", previous=live), 0)
        feed = json.loads((stable / "channels" / "stable.json").read_text())
        self.assertEqual(beta3_android(feed, "stable"), ("1.0.0-rr.1", 263241200))
        items = rrrelease.parse_appcast((stable / "channels" / "appcast.xml").read_bytes())
        self.assertEqual((items[0]["shortVersion"], items[0]["channel"]), ("1.0.0", "stable"))
        self.assertGreater(int(items[0]["version"]), 263220900)


FIXTURES = (
    ("nightly", "1.0.0-nightly.20261116", 263200900, "nightly-20261116.0900"),
    ("beta", "1.0.0-beta.1", 263201200, "v1.0.0-beta.1"),
    ("stable", "1.0.0", 263241200, "v1.0.0"),
)

if __name__ == "__main__":
    unittest.main()
