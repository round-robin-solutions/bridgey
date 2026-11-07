"""Mandatory scoped Rust contract checks, dispatched by the existing owned Python CI task.

This does not install Rust or run native capture/input. Missing installed tools or an empty
test selection fail the gate. Cargo output is bounded in the unittest failure message;
the worker owns the process group and overall job deadline.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


class ScreenControlCoreTests(unittest.TestCase):
    def test_shared_rust_screen_control_contract(self):
        cpu = os.environ.get("RR_CI_CPU", "1")
        self.assertRegex(cpu, r"^[0-9]{1,3}$", "RR_CI_CPU must be a positive integer")
        self.assertGreater(int(cpu), 0, "RR_CI_CPU must be a positive integer")
        with tempfile.TemporaryDirectory(prefix="bridgey-screen-control-target-") as target:
            env = dict(os.environ)
            env.update(
                CARGO_TARGET_DIR=target,
                CARGO_BUILD_JOBS=cpu,
                CARGO_INCREMENTAL="0",
                CARGO_PROFILE_DEV_DEBUG="0",
                CARGO_PROFILE_TEST_DEBUG="0",
                RUSTUP_AUTO_INSTALL="0",
                RUSTUP_NO_UPDATE_CHECK="1",
            )
            result = subprocess.run(
                [
                    "/bin/sh", "-eu", "-c",
                    '. "$1"; '
                    'command -v "$CARGO_BIN" >/dev/null || '
                    '{ echo "Installed Cargo is required for the shared screen/control contract" >&2; exit 127; }; '
                    'exec "$CARGO_BIN" test --locked --quiet --manifest-path "$2" '
                    '-p bridgey-connect-proto screen_control:: -- --nocapture',
                    "bridgey-screen-control-check",
                    str(ROOT / "scripts/rr/rust-env.sh"),
                    str(ROOT / "rust/Cargo.toml"),
                ],
                cwd=ROOT, env=env, capture_output=True, text=True,
            )
            output = result.stdout + "\n" + result.stderr
            self.assertEqual(result.returncode, 0, output[-65_536:])
            counts = re.findall(r"test result: ok\. ([0-9]+) passed;", output)
            self.assertTrue(any(int(count) > 0 for count in counts),
                            "Cargo selected no screen/control tests:\n" + output[-65_536:])
            print("Shared Rust screen/control contract: " + ", ".join(counts) + " tests passed.")


if __name__ == "__main__":
    unittest.main()
