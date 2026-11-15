"""Tests for scripts/rr/versions.py and scripts/rr/cut-release.py. Run: python3 -m unittest discover -s scripts/rr/tests"""

import argparse
import datetime as dt
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RR))

import versions  # noqa: E402

SPEC = importlib.util.spec_from_file_location("cut_release", RR / "cut-release.py")
cut_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cut_release)


class VersionTests(unittest.TestCase):
    def test_channels_in_both_schemes(self):
        cases = {
            "1.0.0": "stable", "1.0.0-beta.2": "beta", "1.0.0-nightly.20261116": "nightly",
            "0.11.0-rr.1": "stable", "0.11.0-rr.1-beta.3": "beta", "0.10.0-rr.1-nightly.20261108": "nightly",
        }
        for name, channel in cases.items():
            self.assertEqual(versions.channel_of(name), channel, name)
            self.assertTrue(versions.matches_channel(name, channel))
        for name in ("1.0.0-dev", "1.0", "v1.0.0", "1.0.0-rc.1", "1.0.0-nightly.2026", "1.0.0-beta.", ""):
            self.assertIsNone(versions.parse(name), name)
        self.assertFalse(versions.matches_channel("0.11.0-rr.1-beta.3", "beta", legacy=False))
        self.assertTrue(versions.matches_channel("1.0.0-beta.3", "beta", legacy=False))

    def test_legacy_name_is_what_0x_apps_accept(self):
        self.assertEqual(versions.legacy_name("1.0.0"), "1.0.0-rr.1")
        self.assertEqual(versions.legacy_name("1.0.0-beta.2"), "1.0.0-rr.1-beta.2")
        self.assertEqual(versions.legacy_name("1.1.0-nightly.20261201"), "1.1.0-rr.1-nightly.20261201")
        self.assertEqual(versions.legacy_name("0.11.0-rr.1-beta.3"), "0.11.0-rr.1-beta.3")
        for name in ("1.0.0", "1.0.0-beta.2", "1.0.0-nightly.20261116"):
            self.assertTrue(versions.LEGACY[versions.channel_of(name)].match(versions.legacy_name(name)))
        with self.assertRaises(ValueError):
            versions.legacy_name("1.0.0-dev")

    def test_labels_people_see(self):
        self.assertEqual(versions.display("1.0.0-beta.1"), "1.0 Beta 1")
        self.assertEqual(versions.display("1.0.0"), "1.0")
        self.assertEqual(versions.display("1.0.1"), "1.0.1")
        self.assertEqual(versions.display("1.1.0-nightly.20261116"), "1.1 Nightly 16 Nov")
        self.assertEqual(versions.display("0.11.0-rr.1-beta.3"), "0.11.0-rr.1 Beta 3")
        self.assertEqual(versions.display("0.9.0-rr.2"), "0.9.0-rr.2")
        self.assertEqual(versions.display("1.0.0-dev"), "1.0.0-dev")

    def test_store_versions_are_plain_numbers(self):
        self.assertEqual(versions.store_version("1.0.0-beta.3"), "1.0.0")
        self.assertEqual(versions.store_version("1.0.1"), "1.0.1")
        self.assertEqual(versions.store_version("1.1.0-nightly.20261201"), "1.1.0")
        self.assertEqual(versions.store_version("1.0.0-dev"), "1.0.0")

    def test_order_across_the_boundary(self):
        order = ["0.10.0-rr.1-beta.27", "0.11.0-rr.1-beta.3", "1.0.0-nightly.20261116", "1.0.0-beta.1", "1.0.0-rr.1-beta.2",
                 "1.0.0-beta.10", "1.0.0", "1.0.1-beta.1", "1.0.1", "1.1.0"]
        self.assertEqual(sorted(order, key=versions.sort_key), order)

    def test_next_versions(self):
        self.assertEqual(versions.next_minor("1.0.0"), "1.1.0")
        self.assertEqual(versions.next_patch("1.0.0"), "1.0.1")


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class CutReleaseTests(unittest.TestCase):
    """cut-release.py against a local bare repository standing in for the fork."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.origin = root / "origin.git"
        git(root, "init", "--quiet", "--bare", str(self.origin))
        self.repo = root / "repo"
        git(root, "init", "--quiet", "-b", "rr/main", str(self.repo))
        for key, value in (("user.name", "Test"), ("user.email", "test@example.com"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false")):
            git(self.repo, "config", key, value)
        self.write("rr-edition.properties", "GITHUB_REPO=round-robin-solutions/bridgey\nEDITION_NEXT_VERSION=1.0.0\n")
        self.write("CHANGELOG.md", "# Changelog\n\nNewest first.\n\n## 0.11 Beta 3 (0.11.0-rr.1-beta.3), 15 November 2026\n\n- Calls window.\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "--quiet", "-m", "start")
        git(self.repo, "remote", "add", "origin", str(self.origin))
        git(self.repo, "push", "--quiet", "origin", "rr/main")
        self.notes = root / "notes.md"
        self.notes.write_text("Bridgey by Round Robin 1.0 Beta 1\n\n- Own version numbers.\n")
        self.published = set()
        self.day = dt.date(2026, 11, 16)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, text):
        (self.repo / name).write_text(text)

    def run_cut(self, command, push=True, **options):
        args = argparse.Namespace(command=command, push=push, remote="origin", notes_file=options.get("notes_file"),
                                  commit=options.get("commit"), source=options.get("source"), next=options.get("next", "minor"))
        return cut_release.cut(args, root=self.repo, published=lambda repo: self.published, today=self.day)

    def origin_file(self, name, ref="rr/main"):
        return git(self.repo, "show", f"origin/{ref}:{name}") if ref else None

    def test_dry_run_creates_nothing(self):
        plan = self.run_cut("beta", push=False, notes_file=str(self.notes))
        self.assertEqual(plan["tag"], "v1.0.0-beta.1")
        self.assertIn("## 1.0 Beta 1 (1.0.0-beta.1), 16 November 2026\n\n- Own version numbers.", plan["changelog"])
        self.assertEqual(git(self.origin, "tag"), "")

    def test_beta_numbers_count_up_and_the_changelog_grows_newest_first(self):
        first = self.run_cut("beta", notes_file=str(self.notes))
        self.assertEqual(first["tag"], "v1.0.0-beta.1")
        self.assertEqual(git(self.origin, "rev-parse", "v1.0.0-beta.1^{commit}"), first["commit"])
        self.assertEqual(git(self.origin, "cat-file", "-t", "v1.0.0-beta.1"), "tag")
        self.assertIn("Own version numbers", git(self.origin, "tag", "-l", "--format=%(contents)", "v1.0.0-beta.1"))
        second = self.run_cut("beta", notes_file=str(self.notes))
        self.assertEqual(second["tag"], "v1.0.0-beta.2")
        git(self.repo, "fetch", "--quiet", "origin")
        changelog = self.origin_file("CHANGELOG.md")
        self.assertLess(changelog.index("1.0 Beta 2"), changelog.index("1.0 Beta 1"))
        self.assertLess(changelog.index("1.0 Beta 1"), changelog.index("0.11 Beta 3"))
        self.assertTrue(changelog.startswith("# Changelog\n\nNewest first.\n\n## 1.0 Beta 2"))

    def test_beta_needs_notes(self):
        with self.assertRaises(cut_release.CutError):
            self.run_cut("beta")

    def test_promote_tags_the_published_betas_commit_and_moves_the_next_version_on(self):
        beta1 = self.run_cut("beta", notes_file=str(self.notes))
        self.published = {"v1.0.0-beta.1"}
        # Work merged after the beta must not reach Stable.
        git(self.repo, "fetch", "--quiet", "origin")
        git(self.repo, "reset", "--quiet", "--hard", "origin/rr/main")
        self.write("feature.txt", "after the beta\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "--quiet", "-m", "feature")
        git(self.repo, "push", "--quiet", "origin", "rr/main")
        # beta.2 exists as a tag but was never published: the newest published beta is beta.1.
        git(self.repo, "tag", "-a", "v1.0.0-beta.2", "-m", "unpublished")
        git(self.repo, "push", "--quiet", "origin", "v1.0.0-beta.2")
        plan = self.run_cut("promote")
        self.assertEqual(plan["tag"], "v1.0.0")
        self.assertEqual(plan["commit"], beta1["commit"])
        self.assertEqual(git(self.origin, "rev-parse", "v1.0.0^{commit}"), beta1["commit"])
        self.assertIn("The same code as 1.0 Beta 1, now on Stable.", plan["message"])
        self.assertTrue(plan["message"].startswith("Bridgey by Round Robin 1.0\n"))
        git(self.repo, "fetch", "--quiet", "origin")
        self.assertIn("EDITION_NEXT_VERSION=1.1.0", self.origin_file("rr-edition.properties"))
        self.assertIn("## 1.0 (1.0.0), 16 November 2026", self.origin_file("CHANGELOG.md"))
        self.assertEqual(self.origin_file("feature.txt"), "after the beta")
        with self.assertRaises(cut_release.CutError):
            self.run_cut("promote", source="v1.0.0-beta.1")

    def test_promote_refuses_without_a_published_beta_or_with_an_unpublished_choice(self):
        self.run_cut("beta", notes_file=str(self.notes))
        with self.assertRaises(cut_release.CutError):
            self.run_cut("promote", push=False)
        with self.assertRaises(cut_release.CutError):
            self.run_cut("promote", push=False, source="v1.0.0-beta.1")
        self.published = {"v1.0.0-beta.1"}
        plan = self.run_cut("promote", push=False, next="patch")
        self.assertEqual((plan["tag"], plan["next"]), ("v1.0.0", "1.0.1"))
        with self.assertRaises(cut_release.CutError):
            self.run_cut("promote", push=False, next="0.9.0")

    def test_changelog_helpers(self):
        self.assertEqual(cut_release.notes_body("Bridgey by Round Robin 1.0 Beta 2\n\n- One.\n"), "- One.")
        self.assertEqual(cut_release.notes_body("- One.\n- Two."), "- One.\n- Two.")
        text = cut_release.add_entry("", "## 1.0 (1.0.0), 1 December 2026\n\nDone.\n")
        self.assertTrue(text.startswith("# Changelog\n\n## 1.0"))
        self.assertEqual(cut_release.set_next_version("A=1\nEDITION_NEXT_VERSION=1.0.0\n", "1.1.0"), "A=1\nEDITION_NEXT_VERSION=1.1.0\n")


if __name__ == "__main__":
    unittest.main()
