"""scripts/rr/ci-release-macos.sh: the Mac half of an RR CI release records the version it built in."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class CiReleaseMacosTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.repo = self.tmp / 'repo'
        shutil.copytree(ROOT / 'scripts' / 'rr', self.repo / 'scripts' / 'rr',
                        ignore=shutil.ignore_patterns('tests', '__pycache__'))
        shutil.copy(ROOT / 'rr-edition.properties', self.repo / 'rr-edition.properties')
        # In place of the real build: record the version it was given, which the real one stamps into the app.
        (self.repo / 'scripts' / 'rr' / 'build-macos.sh').write_text(
            '#!/bin/sh\nset -eu\nmkdir -p "$1"\nprintf "%s %s\\n" "$BRIDGEY_VERSION_NAME" "$BRIDGEY_BUILD_NUMBER" > "$1/built"\n')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                        'commit', '-q', '--allow-empty', '-m', 'fixture'], check=True)
        self.out = self.tmp / 'out'

    def build(self, mode, ref=None):
        env = {k: v for k, v in os.environ.items() if k != 'RR_CI_REF'}
        if ref:
            env['RR_CI_REF'] = ref
        return subprocess.run(['sh', str(self.repo / 'scripts' / 'rr' / 'ci-release-macos.sh'), mode, str(self.out)],
                              env=env, capture_output=True, text=True)

    def recorded(self):
        return dict(line.split('=', 1) for line in (self.out / 'release.env').read_text().splitlines())

    def derived(self, *args):
        """What ci-release.sh derives from the recorded build time."""
        out = subprocess.run(['python3', str(self.repo / 'scripts' / 'rr' / 'rrrelease.py'), 'version', *args],
                             capture_output=True, text=True, check=True).stdout
        return dict(line.split('=', 1) for line in out.splitlines())

    def check(self, recorded, *args):
        built = (self.out / 'built').read_text().split()
        self.assertEqual(built, [recorded['VERSION_NAME'], recorded['BUILD_NUMBER']])
        again = self.derived(*args, '--now', recorded['NOW'])
        for key in ('CHANNEL', 'VERSION_NAME', 'BUILD_NUMBER', 'TAG'):
            self.assertEqual(again[key], recorded[key], key)
        head = subprocess.run(['git', '-C', str(self.repo), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
        self.assertEqual(recorded['REVISION'], head)

    def test_a_beta_tag(self):
        result = self.build('tag', 'refs/tags/v1.0.0-beta.2')
        self.assertEqual(result.returncode, 0, result.stderr)
        recorded = self.recorded()
        self.assertEqual((recorded['CHANNEL'], recorded['VERSION_NAME']), ('beta', '1.0.0-beta.2'))
        self.check(recorded, 'beta', '--version', '1.0.0-beta.2')

    def test_a_stable_tag(self):
        result = self.build('tag', 'refs/tags/v1.0.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        recorded = self.recorded()
        self.assertEqual((recorded['CHANNEL'], recorded['VERSION_NAME']), ('stable', '1.0.0'))
        self.check(recorded, 'stable', '--version', '1.0.0')

    def test_a_nightly(self):
        result = self.build('nightly')
        self.assertEqual(result.returncode, 0, result.stderr)
        recorded = self.recorded()
        self.assertEqual(recorded['CHANNEL'], 'nightly')
        self.check(recorded, 'nightly')

    def test_other_refs_build_nothing(self):
        for ref in ('refs/tags/v1.0', 'refs/tags/cli-v1.0.0', 'refs/tags/v1.0.0-rc.1', 'refs/heads/rr/main'):
            with self.subTest(ref=ref):
                result = self.build('tag', ref)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.out / 'built').exists())
                self.assertFalse((self.out / 'release.env').exists())


if __name__ == '__main__':
    unittest.main()
