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

    def test_every_feature_key_in_the_sources_is_listed(self):
        self.assertEqual(contract.feature_key_problems(self.data), [])

    def test_feature_maps_fit_the_size_rule(self):
        broken = contract.load()
        broken["features"] += [dict(broken["features"][-1], key=f"k{i}_draft1") for i in range(contract.MAX_FEATURE_KEYS)]
        broken["features"].append(dict(broken["features"][-1], key="x" * 60 + "_draft1"))
        problems = "\n".join(contract.validate(broken))
        self.assertIn("carries at most 128", problems)
        self.assertIn("a key is 1 to 64 bytes", problems)

    def test_feature_key_scan(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            pathlib.Path(tmp, "main").mkdir()
            pathlib.Path(tmp, "main", "A.kt").write_text('features["sms_draft1"] = true\nput("mystery_draft2", true)\n')
            pathlib.Path(tmp, "test").mkdir()
            pathlib.Path(tmp, "test", "B.kt").write_text('put("only_in_tests_draft1", true)\n')
            found = contract.feature_key_problems(self.data, [(pathlib.Path(tmp), ".kt")])
        self.assertEqual(len(found), 1)
        self.assertIn("mystery_draft2", found[0])

    def test_agent_ingress_uses_the_complete_protocol_role_gate(self):
        # Dispatch must use the same set as admission, so a newly allowed request cannot be
        # silently dropped between the authenticated session and the Hub.
        source = (ROOT / "android/app/src/main/java/dev/bridgey/android/PairingCoordinator.kt").read_text()
        start = source.index("    private fun receive(current: Session, message: Message)")
        end = source.index("    private fun ", start + 1)
        dispatch = source[start:end]
        self.assertIn("in dev.bridgey.android.agents.AGENT_TO_PHONE_KINDS -> receiveAgentMessage(current, message)", dispatch)

    def test_validation_catches_mistakes(self):
        broken = contract.load()
        broken["messages"].append(dict(broken["messages"][0]))
        broken["messages"].append({"kind": "x.y", "status": "edition-draft", "direction": "either", "feature": "files",
                                   "encrypted": True, "outer": ["sessionId"], "implemented": ["ios"], "reply": ["nope.kind"]})
        kinds = {m["kind"]: m for m in broken["messages"]}
        kinds["clipboard.rich"]["v1"] = "extension"
        # Under a core key maps may omit, an optional extension kind is allowed (the speed test).
        kinds["speed.start"]["v1"] = "extension"
        kinds["notifications.post"]["v1DraftFields"] = ["presentation"]
        problems = "\n".join(contract.validate(broken))
        for expected in ("listed twice", "*_draft1", "nonce and ciphertext", "unknown platform", "reply nope.kind",
                         "x.y: v1 must be one of", "clipboard.rich: v1 extension differs from its feature key",
                         "notifications.post: eventId is gated by draft notification_routing_draft1"):
            self.assertIn(expected, problems)
        self.assertNotIn("speed.start: v1 extension differs", problems)

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
