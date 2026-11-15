"""protocol/test-vectors/dialer-v1.json is what protocol/tools/dialer_vectors.py writes (no hand edits)."""
import importlib.util
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]


class DialerVectorsTest(unittest.TestCase):
    def test_checked_in_vectors_match_the_generator(self):
        spec = importlib.util.spec_from_file_location("dialer_vectors", ROOT / "protocol/tools/dialer_vectors.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        checked_in = json.loads((ROOT / "protocol/test-vectors/dialer-v1.json").read_text(encoding="utf-8"))
        self.assertEqual(checked_in, json.loads(json.dumps(module.out)), "run python3 protocol/tools/dialer_vectors.py")

    def test_every_group_has_valid_and_rejected_cases(self):
        vectors = json.loads((ROOT / "protocol/test-vectors/dialer-v1.json").read_text(encoding="utf-8"))
        for group in ("request", "status", "contacts", "recents", "callResult"):
            cases = vectors[group]
            self.assertTrue(any(c["expect"] == "reject" for c in cases), group)
            self.assertTrue(any(c["expect"] != "reject" for c in cases), group)


if __name__ == "__main__":
    unittest.main()
