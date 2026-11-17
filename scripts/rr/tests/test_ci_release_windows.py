"""The Windows half of a release hands rr-dev-1 text files it can read: LF lines from ci-release-windows.ps1, and
the shell scripts read a job's release.env without carriage returns either way (a CRLF REVISION stopped a nightly)."""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RR = ROOT / 'scripts' / 'rr'


class CiReleaseWindowsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def env_value(self, path, key):
        script = self.tmp / 'read.sh'
        script.write_text(f'. "{RR / "common.sh"}"\nenv_value "$1" "$2"\n')
        return subprocess.run(['sh', str(script), str(path), key], capture_output=True, text=True, check=True).stdout.removesuffix('\n')

    def test_release_env_reads_the_same_with_crlf_or_lf(self):
        lines = ['NOW=2026-11-17T06:22:00Z', 'VERSION_NAME=1.0.0-nightly.20261117', 'BUILD_NUMBER=263210622',
                 'REVISION=9fdeb651e89dc15fa08cd7bf568d778bdb0b3087']
        for ending in ('\n', '\r\n'):
            with self.subTest(ending=repr(ending)):
                env = self.tmp / 'release.env'
                env.write_bytes(ending.join(lines).encode() + ending.encode())
                self.assertEqual(self.env_value(env, 'REVISION'), '9fdeb651e89dc15fa08cd7bf568d778bdb0b3087')
                self.assertEqual(self.env_value(env, 'BUILD_NUMBER'), '263210622')
                self.assertEqual(self.env_value(env, 'MISSING'), '')

    def test_the_shell_scripts_read_job_env_files_with_env_value(self):
        for name in ('ci-release.sh', 'release.sh'):
            text = (RR / name).read_text()
            self.assertNotRegex(text, r"sed -n 's/\^(REVISION|VERSION_NAME|NOW|BUILD_NUMBER)=//p' \"\$(WIN|MAC)", name)

    def test_the_windows_job_writes_lf_text(self):
        source = (RR / 'ci-release-windows.ps1').read_text()
        self.assertNotIn('Set-Content', source, 'Set-Content writes CRLF on Windows')
        pwsh = shutil.which('pwsh')
        if not pwsh:
            self.skipTest('pwsh is not installed')
        function = re.search(r'function Write-Lines.*?\n}\n', source, re.S).group(0)
        out = self.tmp / 'release.env'
        script = self.tmp / 'write.ps1'
        script.write_text(function + f"Write-Lines '{out}' @('NOW=x', 'REVISION=abc')\n")
        subprocess.run([pwsh, '-NoProfile', '-File', str(script)], check=True, capture_output=True)
        self.assertEqual(out.read_bytes(), b'NOW=x\nREVISION=abc\n')


if __name__ == '__main__':
    unittest.main()
