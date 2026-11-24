"""The Android half of a release on a GitHub-hosted runner: scripts/rr/build-android-unsigned.sh records the version it
built in, and scripts/rr/ci-release.sh signs that APK on rr-dev-1 only when the revision and version are this release's,
building it there as before when the hosted job's files are absent."""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def write_exe(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.repo = self.tmp / 'repo'
        shutil.copytree(ROOT / 'scripts' / 'rr', self.repo / 'scripts' / 'rr',
                        ignore=shutil.ignore_patterns('tests', '__pycache__'))
        shutil.copy(ROOT / 'rr-edition.properties', self.repo / 'rr-edition.properties')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                        'commit', '-q', '--allow-empty', '-m', 'fixture'], check=True)
        self.head = subprocess.run(['git', '-C', str(self.repo), 'rev-parse', 'HEAD'],
                                   capture_output=True, text=True, check=True).stdout.strip()

    def derived(self, *args):
        out = subprocess.run(['python3', str(self.repo / 'scripts' / 'rr' / 'rrrelease.py'), 'version', *args],
                             capture_output=True, text=True, check=True).stdout
        return dict(line.split('=', 1) for line in out.splitlines())


class BuildAndroidUnsignedTests(Fixture):
    def setUp(self):
        super().setUp()
        rr = self.repo / 'scripts' / 'rr'
        # In place of the real build: the flags and version it was given, which the real one stamps into the APK.
        write_exe(rr / 'build-android.sh',
                  '#!/bin/sh\nset -eu\n[ "$1" = --unsigned ] || exit 9\nmkdir -p "$(dirname "$2")"\n'
                  'printf "%s %s\\n" "$BRIDGEY_VERSION_NAME" "$BRIDGEY_BUILD_NUMBER" > "$2"\n')
        write_exe(rr / 'android-deps.sh', '#!/bin/sh\nset -eu\necho "+--- a:b:1" > "$1"\n')
        self.out = self.tmp / 'out'

    def build(self, mode, ref=None, out=True):
        env = {k: v for k, v in os.environ.items() if k not in ('RR_CI_REF', 'RR_CI_RELEASE_NOW')}
        env['RR_CI_RELEASE_NOW'] = '2026-11-24T18:00:00Z'
        if ref:
            env['RR_CI_REF'] = ref
        args = ['sh', str(self.repo / 'scripts' / 'rr' / 'build-android-unsigned.sh'), mode]
        if out:
            args.append(str(self.out))
        return subprocess.run(args, env=env, capture_output=True, text=True)

    def test_a_beta_tag_records_the_version_built_in(self):
        result = self.build('tag', 'refs/tags/v1.0.0-beta.3')
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = (self.out / 'release.env').read_bytes()
        self.assertNotIn(b'\r', raw)
        recorded = dict(line.split('=', 1) for line in raw.decode().splitlines())
        self.assertEqual(recorded['NOW'], '2026-11-24T18:00:00Z')
        self.assertEqual(recorded['REVISION'], self.head)
        again = self.derived('beta', '--version', '1.0.0-beta.3', '--now', recorded['NOW'])
        for key in ('CHANNEL', 'VERSION_NAME', 'BUILD_NUMBER', 'TAG'):
            self.assertEqual(recorded[key], again[key], key)
        built = (self.out / 'app-release-unsigned.apk').read_text().split()
        self.assertEqual(built, [recorded['VERSION_NAME'], recorded['BUILD_NUMBER']])
        self.assertTrue((self.out / 'android-dependencies.txt').read_text().startswith('+--- '))

    def test_a_nightly_goes_to_the_default_folder(self):
        result = self.build('nightly', out=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        folder = self.repo / 'rrci-release-out' / 'android'
        self.assertTrue((folder / 'app-release-unsigned.apk').is_file())
        self.assertEqual(dict(l.split('=', 1) for l in (folder / 'release.env').read_text().splitlines())['CHANNEL'], 'nightly')

    def test_other_refs_build_nothing(self):
        for ref in ('refs/tags/v1.0', 'refs/tags/v1.0.0-rc.1', 'refs/heads/rr/main'):
            with self.subTest(ref=ref):
                result = self.build('tag', ref)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.out / 'release.env').exists())

    def test_no_release_env_when_the_build_fails(self):
        write_exe(self.repo / 'scripts' / 'rr' / 'build-android.sh', '#!/bin/sh\nexit 1\n')
        result = self.build('tag', 'refs/tags/v1.0.0-beta.3')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.out / 'release.env').exists())


class CiReleaseTests(Fixture):
    """ci-release.sh with gh, release.sh and sign-android.sh replaced by recorders."""

    def setUp(self):
        super().setUp()
        rr = self.repo / 'scripts' / 'rr'
        self.calls = self.tmp / 'calls'
        write_exe(rr / 'release.sh', f'#!/bin/sh\nprintf "release %s\\n" "$*" >> "{self.calls}"\n')
        write_exe(rr / 'sign-android.sh',
                  f'#!/bin/sh\nset -eu\nprintf "sign %s %s %s %s\\n" "$1" "$2" "$BRIDGEY_VERSION_NAME" "$BRIDGEY_BUILD_NUMBER" >> "{self.calls}"\n'
                  'cp "$1" "$2"\n')
        self.bin = self.tmp / 'bin'
        # gh: the revision is on rr/main; a tag lookup is never needed for a nightly.
        write_exe(self.bin / 'gh', '#!/bin/sh\necho identical\n')
        self.home = self.tmp / 'home'
        (self.home / '.config' / 'bridgey-rr').mkdir(parents=True)
        (self.home / '.config' / 'bridgey-rr' / 'github-token').write_text('test-token')
        (self.home / 'Android' / 'Sdk').mkdir(parents=True)
        self.jdk = self.tmp / 'jdk'
        write_exe(self.jdk / 'bin' / 'java', '#!/bin/sh\necho 17\n')
        self.inputs = self.tmp / 'inputs'
        self.now = '2026-11-24T18:00:00Z'
        self.version = self.derived('nightly', '--now', self.now)

    def job(self, name, revision=None, now=None, apk=True, **override):
        d = self.inputs / name
        d.mkdir(parents=True)
        v = dict(self.version, **override)
        lines = [f'NOW={now or self.now}', f'CHANNEL={v["CHANNEL"]}', f'VERSION_NAME={v["VERSION_NAME"]}',
                 f'BUILD_NUMBER={v["BUILD_NUMBER"]}', f'TAG={v["TAG"]}', f'REVISION={revision or self.head}']
        (d / 'release.env').write_text('\n'.join(lines) + '\n')
        if name.endswith('android'):
            if apk:
                (d / 'app-release-unsigned.apk').write_text('apk')
            (d / 'android-dependencies.txt').write_text('+--- a:b:1\n')
        return d

    def run_release(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith('RR_CI_')}
        env.update(PATH=f'{self.bin}:{env["PATH"]}', RR_CI_HOST_HOME=str(self.home), RR_CI_INPUT_DIR=str(self.inputs),
                   JAVA_HOME=str(self.jdk))
        result = subprocess.run(['sh', str(self.repo / 'scripts' / 'rr' / 'ci-release.sh'), 'nightly'],
                                env=env, capture_output=True, text=True)
        calls = self.calls.read_text().splitlines() if self.calls.exists() else []
        return result, calls

    def test_the_hosted_apk_is_signed_and_published_with_its_listing(self):
        self.inputs.mkdir()
        android = self.job('nightly-android')
        result, calls = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        sign = [c for c in calls if c.startswith('sign ')]
        self.assertEqual(len(sign), 1)
        self.assertIn(f'{android}/app-release-unsigned.apk', sign[0])
        self.assertTrue(sign[0].endswith(f'{self.version["VERSION_NAME"]} {self.version["BUILD_NUMBER"]}'))
        release = [c for c in calls if c.startswith('release ')][0]
        self.assertIn(f'--now {self.now}', release)
        self.assertIn('/app-release.apk', release)
        self.assertIn(f'--android-deps {android}/android-dependencies.txt', release)

    def test_with_the_mac_job_both_must_carry_one_version(self):
        self.inputs.mkdir()
        self.job('nightly-macos')
        self.job('nightly-android')
        result, calls = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        release = [c for c in calls if c.startswith('release ')][0]
        self.assertIn('--macos-artifacts', release)
        self.assertIn('--apk', release)

    def test_another_revision_or_version_is_refused(self):
        cases = {'revision': dict(revision='0' * 40), 'build': dict(BUILD_NUMBER='1'),
                 'version': dict(VERSION_NAME='1.0.0-nightly.20200101')}
        for name, change in cases.items():
            with self.subTest(name):
                shutil.rmtree(self.inputs, ignore_errors=True)
                self.calls.unlink(missing_ok=True)
                self.inputs.mkdir()
                self.job('nightly-macos')
                self.job('nightly-android', **change)
                result, calls = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_without_the_hosted_files_the_apk_is_built_here(self):
        self.inputs.mkdir()
        self.job('nightly-android', apk=False)
        result, calls = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse([c for c in calls if c.startswith('sign ')])
        release = [c for c in calls if c.startswith('release ')][0]
        self.assertNotIn('--apk', release)
        self.assertIn('--mac-host', release)


if __name__ == '__main__':
    unittest.main()
