"""protocol/messages.json is complete, consistent, and docs/protocol-contract.md matches it."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("contract", ROOT / "protocol" / "tools" / "contract.py")
contract = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(contract)


class ProtocolContractTest(unittest.TestCase):
    def setUp(self):
        self.data = contract.load()

    def test_contract_is_consistent(self):
        self.assertEqual(contract.validate(self.data), [])

    def test_doc_tables_are_current(self):
        current = contract.DOC.read_text(encoding="utf-8")
        self.assertEqual(current, contract.splice(current, contract.render(self.data)),
                         "run python3 protocol/tools/contract.py --write")

    def test_every_kind_in_the_sources_is_listed(self):
        self.assertEqual(contract.coverage_problems(self.data), [])

    def test_validation_catches_mistakes(self):
        broken = contract.load()
        broken["messages"].append(dict(broken["messages"][0]))
        broken["messages"].append({"kind": "x.y", "status": "edition-draft", "direction": "either", "feature": "files",
                                   "encrypted": True, "outer": ["sessionId"], "implemented": ["ios"], "reply": ["nope.kind"]})
        problems = "\n".join(contract.validate(broken))
        for expected in ("listed twice", "*_draft1", "nonce and ciphertext", "unknown platform", "reply nope.kind"):
            self.assertIn(expected, problems)

    def test_scan_finds_kinds_in_each_style(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            k = pathlib.Path(tmp, "A.kt")
            k.write_text('send(Message(kind = "a.one"))\n            "a.two", "a.three" -> x()\n'
                         'object FooKinds {\n    const val X = "a.four"\n}\n    FIVE("a.five"),\n'
                         'link.sendWithId("a.six", id)\nval file = "notes.txt"\n')
            self.assertEqual(set(contract.scan_kinds(tmp, "android")), {"a.one", "a.two", "a.three", "a.four", "a.five", "a.six"})
            k.unlink()
            pathlib.Path(tmp, "A.swift").write_text('send(PairingMessage(kind: "b.one"))\n  case "b.two", "b.three":\n'
                                                    'enum FolderKind {\n    static let x = "b.four"\n}\n_ = send(id, "b.five", r)\n'
                                                    'L10n.text("b.six", fallback: "x")\n')
            self.assertEqual(set(contract.scan_kinds(tmp, "macos")), {"b.one", "b.two", "b.three", "b.four", "b.five"})


if __name__ == "__main__":
    unittest.main()
