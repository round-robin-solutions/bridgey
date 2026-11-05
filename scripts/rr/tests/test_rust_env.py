"""Exercise tool selection with fake Cargo executables and owned home directories only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[3] / "scripts/rr/rust-env.sh"


class RustEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.attempt_home = self.root / "attempt-home"
        self.host_home = self.root / "host-home"
        self.bin = self.root / "bin"
        for directory in (self.attempt_home, self.host_home, self.bin):
            directory.mkdir()
        self.record = self.root / "cargo.json"
        self.env = {
            "HOME": str(self.attempt_home), "PATH": str(self.bin),
            "RR_CI_HOST_HOME": str(self.host_home), "RR_CI_CPU": "2",
            "FAKE_RUST_CAPTURE": str(self.record),
        }

    def cargo(self, directory, kind):
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "cargo"
        path.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "record = {key: os.environ.get(key) for key in "
            "('CARGO_HOME', 'RUSTUP_HOME', 'CARGO_BUILD_JOBS', 'PATH', 'HOME')}\n"
            "record.update(kind=" + repr(kind) + ", argv=sys.argv[1:])\n"
            "Path(os.environ['FAKE_RUST_CAPTURE']).write_text(json.dumps(record))\n"
        )
        path.chmod(0o700)
        return path

    def run_helper(self, **changes):
        env = {**self.env, **changes}
        env = {key: value for key, value in env.items() if value is not None}
        return subprocess.run(
            ["/bin/sh", "-eu", "-c", '. "$1"; exec "$CARGO_BIN" sentinel', "rust-env-test", str(SCRIPT)],
            cwd=self.root, env=env, capture_output=True, text=True, timeout=10,
        )

    def captured(self):
        return json.loads(self.record.read_text())

    def test_isolated_ci_home_uses_installed_host_tools_without_changing_home(self):
        self.cargo(self.host_home / ".cargo/bin", "host")
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.captured()
        self.assertEqual(record["kind"], "host")
        self.assertEqual(record["CARGO_HOME"], str(self.host_home / ".cargo"))
        self.assertEqual(record["RUSTUP_HOME"], str(self.host_home / ".rustup"))
        self.assertEqual(record["HOME"], str(self.attempt_home))
        self.assertEqual(record["CARGO_BUILD_JOBS"], "2")
        self.assertEqual(record["argv"], ["sentinel"])
        self.assertIn(str(self.host_home / ".cargo/bin"), record["PATH"].split(os.pathsep))

    def test_explicit_tool_homes_override_ci_host_defaults(self):
        cargo_home = self.root / "chosen-cargo"
        rustup_home = self.root / "chosen-rustup"
        self.cargo(cargo_home / "bin", "chosen-home")
        result = self.run_helper(CARGO_HOME=str(cargo_home), RUSTUP_HOME=str(rustup_home))
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.captured()
        self.assertEqual(record["kind"], "chosen-home")
        self.assertEqual(record["CARGO_HOME"], str(cargo_home))
        self.assertEqual(record["RUSTUP_HOME"], str(rustup_home))

    def test_explicit_cargo_wins_over_path_and_home_choices(self):
        chosen = self.cargo(self.root / "explicit", "explicit")
        self.cargo(self.bin, "path")
        self.cargo(self.host_home / ".cargo/bin", "host")
        result = self.run_helper(CARGO=str(chosen))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.captured()["kind"], "explicit")

    def test_existing_path_choice_stays_ahead_of_the_home_fallback(self):
        self.cargo(self.bin, "path")
        self.cargo(self.host_home / ".cargo/bin", "host")
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.captured()
        self.assertEqual(record["kind"], "path")
        self.assertEqual(record["PATH"].split(os.pathsep)[0], str(self.bin))

    def test_local_home_defaults_and_explicit_job_count_are_preserved(self):
        self.cargo(self.attempt_home / ".cargo/bin", "local")
        result = self.run_helper(RR_CI_HOST_HOME=None, RR_CI_CPU=None, CARGO_BUILD_JOBS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.captured()
        self.assertEqual(record["kind"], "local")
        self.assertEqual(record["CARGO_HOME"], str(self.attempt_home / ".cargo"))
        self.assertEqual(record["RUSTUP_HOME"], str(self.attempt_home / ".rustup"))
        self.assertEqual(record["CARGO_BUILD_JOBS"], "1")

    def test_invalid_ci_allocation_fails_before_starting_cargo(self):
        self.cargo(self.host_home / ".cargo/bin", "host")
        for value in ("0", "two", "1000", "2;echo"):
            with self.subTest(value=value):
                result = self.run_helper(RR_CI_CPU=value)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.record.exists())


if __name__ == "__main__":
    unittest.main()
