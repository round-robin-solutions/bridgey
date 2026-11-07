"""Exercise tool selection with fake Cargo executables and owned home directories only."""
import json
import os
from pathlib import Path
import shlex
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

    def mac_preparer(self, provide=True, exit_code=0):
        project = self.root / "project"
        scripts = project / "scripts/rr"
        scripts.mkdir(parents=True)
        prepared = self.cargo(self.root / "prepared", "prepared")
        marker = self.root / "preparation.json"
        program = scripts / "prepare.py"
        program.write_text(
            "import json, os, sys\nfrom pathlib import Path\n"
            "Path(" + repr(str(marker)) + ").write_text(json.dumps(sys.argv[1:]))\n"
            + ("destination = Path(os.environ['CARGO_HOME']) / 'bin/cargo'\n"
               "destination.parent.mkdir(parents=True, exist_ok=True)\n"
               "destination.write_text(Path(" + repr(str(prepared)) + ").read_text())\n"
               "destination.chmod(0o700)\n" if provide else "")
            + "raise SystemExit(" + str(exit_code) + ")\n"
        )
        (scripts / "rust-toolchain.sh").write_text(
            "#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(program)) + ' "$@"\n'
        )
        return project, marker

    def run_mac_preparation(self, project, configuration="debug", execute=True, **changes):
        env = {**self.env, **changes}
        env = {key: value for key, value in env.items() if value is not None}
        script = '. "$1"; bridgey_prepare_macos_rust "$2" "$3"'
        if execute:
            script += '; exec "$CARGO_BIN" sentinel'
        return subprocess.run(
            ["/bin/sh", "-eu", "-c", script, "mac-rust-test", str(SCRIPT), str(project), configuration],
            cwd=self.root, env=env, capture_output=True, text=True, timeout=10,
        )

    def test_ci_mac_packaging_prepares_missing_tools_and_resolves_the_new_cargo(self):
        project, marker = self.mac_preparer()
        result = self.run_mac_preparation(project, CI="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(marker.read_text()), ["mac"])
        self.assertEqual(self.captured()["kind"], "prepared")
        self.assertEqual(self.captured()["HOME"], str(self.attempt_home))
        self.assertEqual(self.captured()["CARGO_HOME"], str(self.host_home / ".cargo"))

    def test_mac_packaging_preserves_existing_tools_without_running_the_installer(self):
        self.cargo(self.host_home / ".cargo/bin", "host")
        project, marker = self.mac_preparer(provide=False, exit_code=99)
        result = self.run_mac_preparation(project, CI="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.captured()["kind"], "host")
        self.assertFalse(marker.exists())

    def test_local_debug_and_explicit_core_skip_do_not_install_missing_tools(self):
        project, marker = self.mac_preparer()
        for changes in ({"CI": None}, {"CI": "1", "BRIDGEY_CONNECT_CORE": "skip"}):
            with self.subTest(changes=changes):
                result = self.run_mac_preparation(project, execute=False, **changes)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(marker.exists())

    def test_local_release_requires_the_same_rust_preparation(self):
        project, marker = self.mac_preparer()
        result = self.run_mac_preparation(project, configuration="release", CI=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(marker.read_text()), ["mac"])
        self.assertEqual(self.captured()["kind"], "prepared")

    def test_required_packaging_fails_when_preparation_still_leaves_cargo_missing(self):
        project, marker = self.mac_preparer(provide=False)
        result = self.run_mac_preparation(project, CI="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not provide executable Cargo", result.stderr)
        self.assertTrue(marker.exists())
        self.assertFalse(self.record.exists())

    def test_installer_failure_stops_packaging_before_cargo_runs(self):
        project, marker = self.mac_preparer(provide=False, exit_code=17)
        result = self.run_mac_preparation(project, CI="1")
        self.assertEqual(result.returncode, 17)
        self.assertTrue(marker.exists())
        self.assertFalse(self.record.exists())

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
