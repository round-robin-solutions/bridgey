"""Tests for scripts/rr/bump-cask.py (the Homebrew cask updater) and obtainium.py's release wiring.
Run: python3 -m unittest discover -s scripts/rr/tests
"""

import hashlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

RR = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("bump_cask", RR / "bump-cask.py")
bump_cask = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bump_cask)

OLD_SHA = "a" * 64
NEW_SHA = "b" * 64
CASK = f'''cask "bridgey-rr" do
  version "0.6.0-rr.1-beta.13"
  sha256 "{OLD_SHA}"

  url "https://github.com/round-robin-solutions/bridgey/releases/download/v#{{version}}/Bridgey-RR-#{{version}}-macOS.dmg"
  name "Bridgey by Round Robin"

  livecheck do
    regex(/^v?(\\d+(?:\\.\\d+)+-rr\\.\\d+(?:-beta\\.\\d+)?)$/i)
  end

  app "Bridgey by Round Robin.app"
end
'''


class RewriteTests(unittest.TestCase):
    def test_rewrites_version_and_sha_only(self):
        out = bump_cask.rewrite_cask(CASK, "0.6.0-rr.1", NEW_SHA)
        self.assertIn('  version "0.6.0-rr.1"\n', out)
        self.assertIn(f'  sha256 "{NEW_SHA}"\n', out)
        # Nothing else changed, including the url and livecheck lines that mention versions.
        self.assertEqual(out.splitlines()[3:], CASK.splitlines()[3:])

    def test_idempotent(self):
        once = bump_cask.rewrite_cask(CASK, "0.6.0-rr.1-beta.14", NEW_SHA)
        self.assertEqual(bump_cask.rewrite_cask(once, "0.6.0-rr.1-beta.14", NEW_SHA), once)

    def test_rejects_bad_input(self):
        for version in ("1.0", "0.6.0-rr.1-nightly.20261025", "v0.6.0-rr.1", "0.6.0-rr.1-beta", ""):
            with self.assertRaises(bump_cask.BumpError, msg=version):
                bump_cask.rewrite_cask(CASK, version, NEW_SHA)
        for sha in ("", "A" * 64, "b" * 63, "g" * 64):
            with self.assertRaises(bump_cask.BumpError, msg=sha):
                bump_cask.rewrite_cask(CASK, "0.6.0-rr.1", sha)

    def test_needs_exactly_one_version_and_sha_line(self):
        with self.assertRaises(bump_cask.BumpError):
            bump_cask.rewrite_cask(CASK.replace('  version "0.6.0-rr.1-beta.13"\n', ""), "0.6.0-rr.1", NEW_SHA)
        with self.assertRaises(bump_cask.BumpError):
            bump_cask.rewrite_cask(CASK + '  sha256 "' + OLD_SHA + '"\n', "0.6.0-rr.1", NEW_SHA)


class VersionOrderTests(unittest.TestCase):
    def test_order(self):
        order = ["0.6.0-rr.1-beta.2", "0.6.0-rr.1-beta.13", "0.6.0-rr.1", "0.6.0-rr.2-beta.1", "0.6.1-rr.1-beta.1", "0.10.0-rr.1-beta.1"]
        keys = [bump_cask.version_key(v) for v in order]
        self.assertEqual(keys, sorted(keys))
        self.assertEqual(len(set(keys)), len(keys))

    def test_apply_refuses_older_unless_forced(self):
        with self.assertRaises(bump_cask.BumpError):
            bump_cask.apply_to_text(CASK, "0.6.0-rr.1-beta.12", NEW_SHA, force=False)
        self.assertIn("beta.12", bump_cask.apply_to_text(CASK, "0.6.0-rr.1-beta.12", NEW_SHA, force=True))

    def test_apply_returns_none_when_unchanged(self):
        self.assertIsNone(bump_cask.apply_to_text(CASK, "0.6.0-rr.1-beta.13", OLD_SHA, force=False))

    def test_stable_replaces_beta(self):
        self.assertIn('version "0.6.0-rr.1"', bump_cask.apply_to_text(CASK, "0.6.0-rr.1", NEW_SHA, force=False))


class TagAndUrlTests(unittest.TestCase):
    def test_version_from_tag(self):
        self.assertEqual(bump_cask.version_from_tag("v0.6.0-rr.1-beta.13"), "0.6.0-rr.1-beta.13")
        with self.assertRaises(bump_cask.BumpError):
            bump_cask.version_from_tag("nightly-20261025.2100")

    def test_release_dmg_url_matches_the_published_asset_name(self):
        url = bump_cask.release_dmg_url(bump_cask.load_properties(), "v0.6.0-rr.1-beta.13", "0.6.0-rr.1-beta.13")
        self.assertEqual(url, "https://github.com/round-robin-solutions/bridgey/releases/download/v0.6.0-rr.1-beta.13/Bridgey-RR-0.6.0-rr.1-beta.13-macOS.dmg")


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.dmg = self.dir / "x.dmg"
        self.dmg.write_bytes(b"not really a dmg")
        self.sha = hashlib.sha256(b"not really a dmg").hexdigest()
        self.cask = self.dir / "bridgey-rr.rb"
        self.cask.write_text(CASK)

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = bump_cask.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_local_file_edit(self):
        code, out, _ = self.run_main("--version", "0.6.0-rr.1", "--dmg", str(self.dmg), "--cask-file", str(self.cask))
        self.assertEqual(code, 0, out)
        text = self.cask.read_text()
        self.assertIn('version "0.6.0-rr.1"', text)
        self.assertIn(f'sha256 "{self.sha}"', text)

    def test_dry_run_changes_nothing(self):
        code, _, _ = self.run_main("--version", "0.6.0-rr.1", "--dmg", str(self.dmg), "--cask-file", str(self.cask), "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(self.cask.read_text(), CASK)

    def test_argument_errors(self):
        for argv in (["--version", "0.6.0-rr.1", "--dmg", str(self.dmg)],  # nowhere to write
                     ["--dmg", str(self.dmg), "--cask-file", str(self.cask)],  # no version
                     ["--version", "0.6.0-rr.1", "--cask-file", str(self.cask)],  # no dmg or tag
                     ["--version", "0.6.0-rr.1", "--dmg", str(self.dir / "missing.dmg"), "--cask-file", str(self.cask)],
                     ["--version", "0.6.0-rr.1-beta.1", "--tag", "v0.6.0-rr.1-beta.2", "--cask-file", str(self.cask)]):
            code, _, err = self.run_main(*argv)
            self.assertEqual(code, 1, argv)
            self.assertIn("bump-cask:", err)

    def test_push_needs_a_token(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            code, _, err = self.run_main("--version", "0.6.0-rr.1", "--dmg", str(self.dmg), "--push")
        self.assertEqual(code, 1)
        self.assertIn("GH_TOKEN", err)

    def test_tag_downloads_the_dmg(self):
        def fake_download(url, target):
            self.assertTrue(url.endswith("/v0.6.0-rr.1/Bridgey-RR-0.6.0-rr.1-macOS.dmg"), url)
            target.write_bytes(b"not really a dmg")

        with mock.patch.object(bump_cask, "download", fake_download):
            code, out, _ = self.run_main("--tag", "v0.6.0-rr.1", "--cask-file", str(self.cask))
        self.assertEqual(code, 0, out)
        self.assertIn(f'sha256 "{self.sha}"', self.cask.read_text())


class PushTests(unittest.TestCase):
    """push_to_tap against a local bare repository standing in for GitHub."""

    def git(self, *args, cwd=None):
        subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.bare = base / "tap.git"
        seed = base / "seed"
        self.git("init", "--bare", "--initial-branch=main", str(self.bare))
        self.git("init", "--initial-branch=main", str(seed))
        (seed / "Casks").mkdir()
        (seed / "Casks" / "bridgey-rr.rb").write_text(CASK)
        self.git("add", ".", cwd=seed)
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "seed", cwd=seed)
        self.git("remote", "add", "origin", str(self.bare), cwd=seed)
        self.git("push", "origin", "main", cwd=seed)
        patcher = mock.patch.object(bump_cask, "tap_url", lambda tap: str(self.bare))
        patcher.start()
        self.addCleanup(patcher.stop)

    def read_cask(self):
        out = subprocess.run(["git", "--git-dir", str(self.bare), "show", "main:Casks/bridgey-rr.rb"], check=True, capture_output=True, text=True)
        return out.stdout

    def test_commits_and_pushes(self):
        self.assertTrue(bump_cask.push_to_tap("any/tap", "0.6.0-rr.1", NEW_SHA, "secret-token", force=False))
        self.assertIn('version "0.6.0-rr.1"', self.read_cask())
        author = subprocess.run(["git", "--git-dir", str(self.bare), "log", "-1", "--format=%an <%ae>%n%s%n%b"], check=True, capture_output=True, text=True).stdout
        self.assertIn("Rahul Bansal <50016724+rbansal42@users.noreply.github.com>", author)
        self.assertIn("bridgey-rr 0.6.0-rr.1", author)
        self.assertIn("Co-Authored-By: Claude Opus 5.5", author)

    def test_second_run_is_a_no_op(self):
        bump_cask.push_to_tap("any/tap", "0.6.0-rr.1", NEW_SHA, "secret-token", force=False)
        self.assertFalse(bump_cask.push_to_tap("any/tap", "0.6.0-rr.1", NEW_SHA, "secret-token", force=False))

    def test_older_version_is_refused(self):
        with self.assertRaises(bump_cask.BumpError):
            bump_cask.push_to_tap("any/tap", "0.6.0-rr.1-beta.2", NEW_SHA, "secret-token", force=False)
        self.assertIn("beta.13", self.read_cask())

    def test_errors_never_contain_the_token(self):
        with mock.patch.object(bump_cask, "tap_url", lambda tap: str(self.bare) + "-missing"):
            with self.assertRaises(bump_cask.BumpError) as caught:
                bump_cask.push_to_tap("any/tap", "0.6.0-rr.1", NEW_SHA, "secret-token", force=False)
        self.assertNotIn("secret-token", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
