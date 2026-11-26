"""The Bridgey Protocol v1 freeze check (docs/protocol-v1.md, protocol/tools/v1_freeze.py).

Report only: test_frozen_entries_match_the_baseline prints what changed and fails only when protocol/v1-baseline.json
says "frozen": true or BRIDGEY_PROTOCOL_V1_FROZEN=1 is set. The other tests check that the check itself works.
"""
import copy
import importlib.util
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("v1_freeze", ROOT / "protocol" / "tools" / "v1_freeze.py")
freeze = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(freeze)


class ProtocolV1FreezeTest(unittest.TestCase):
    def setUp(self):
        self.contract = freeze.load_json(freeze.MESSAGES)
        self.baseline = freeze.load_json(freeze.BASELINE)

    def kinds(self, contract):
        return {m["kind"]: m for m in contract["messages"]}

    def problems(self, contract, baseline=None):
        baseline = baseline if baseline is not None else freeze.frozen_view(self.contract)
        return freeze.compare(baseline, freeze.frozen_view(contract), contract)

    def test_frozen_entries_match_the_baseline(self):
        problems = freeze.check(self.contract, self.baseline)
        enforced = freeze.enforced(self.baseline)
        if problems:
            print("\n" + freeze.report(problems, enforced), file=sys.stderr)
        if enforced:
            self.assertEqual([t for s, t in problems if s in ("breaking", "unrecorded")], [],
                             "docs/protocol-v1.md, Versioning after v1")

    def test_baseline_has_its_switch_and_sections(self):
        self.assertIsInstance(self.baseline["frozen"], bool)
        self.assertIsInstance(self.baseline["amendments"], list)
        for section in ("transport", "envelope", "features", "messages", "vectors"):
            self.assertIn(section, self.baseline)

    def test_the_switch_and_the_environment_enforce(self):
        self.assertFalse(freeze.enforced({"frozen": False}, {}))
        self.assertTrue(freeze.enforced({"frozen": True}, {}))
        self.assertTrue(freeze.enforced({"frozen": False}, {freeze.ENV: "1"}))
        self.assertFalse(freeze.enforced({"frozen": False}, {freeze.ENV: "0"}))

    def test_a_change_to_a_frozen_shape_is_breaking(self):
        changed = copy.deepcopy(self.contract)
        kinds = self.kinds(changed)
        kinds["battery.update"]["payload"]["level"] = "changed by a test"
        kinds["features.update"]["outer"].append("deviceId?")
        kinds["clipboard.ack"]["notes"] = "something else"
        kinds["notifications.post"]["payload"]["sound"] = "string, a new field without a key"
        changed["transport"]["maxFrameBytes"] = 131072
        texts = [t for s, t in self.problems(changed) if s == "breaking"]
        for expected in ("kind battery.update: payload.level changed", "kind features.update: outer changed",
                         "kind clipboard.ack: notes changed", "kind notifications.post: payload.sound added",
                         "transport: maxFrameBytes changed"):
            self.assertIn(expected, texts)

    def test_draft_fields_platforms_and_drafts_are_not_frozen(self):
        changed = copy.deepcopy(self.contract)
        kinds = self.kinds(changed)
        kinds["notifications.post"]["payload"]["presentation"] = "optional alert | quiet | silent"
        kinds["clipboard.update"]["implemented"].append("ios")
        kinds["display.frame"]["payload"] = {"anything": "goes"}
        changed["transport"]["onUndecryptablePayload"] += "; a new draft drops it"
        self.assertEqual(self.problems(changed), [])

    def test_status_moves(self):
        changed = copy.deepcopy(self.contract)
        kinds = self.kinds(changed)
        kinds["clipboard.rich"]["v1"] = "draft"
        kinds["focus.state"]["v1"] = "deprecated"
        kinds["dialer.call"]["v1"] = "extension"
        changed["messages"].remove(kinds["ping.ack"])
        problems = self.problems(changed)
        self.assertIn(("breaking", "kind clipboard.rich: v1 core became draft (unfrozen)"), problems)
        self.assertIn(("unrecorded", "kind focus.state: v1 extension became deprecated"), problems)
        self.assertIn(("unrecorded", "kind dialer.call: v1 extension but not in the baseline"), problems)
        self.assertIn(("breaking", "kind ping.ack: removed from protocol/messages.json while v1 extension"), problems)

    def test_vectors_may_grow_but_not_change(self):
        baseline = freeze.frozen_view(self.contract)
        current = copy.deepcopy(baseline)
        frames = current["vectors"]["protocol/test-vectors/protocol-v1.json"]["frames"]
        frames["pairing.cancel"] = "0" * 16
        del frames["files.chunk"]
        frames["a new frame"] = "1" * 16
        problems = freeze.compare(baseline, current, self.contract)
        self.assertIn(("breaking", "vectors protocol/test-vectors/protocol-v1.json#frames: pairing.cancel changed"), problems)
        self.assertIn(("breaking", "vectors protocol/test-vectors/protocol-v1.json#frames: files.chunk removed"), problems)
        self.assertIn(("info", "vectors protocol/test-vectors/protocol-v1.json#frames: 1 new case(s) not recorded yet"), problems)

    def test_only_frozen_features_pin_vectors(self):
        pinned = freeze.frozen_view(self.contract)["vectors"]
        self.assertIn("frames", pinned["protocol/test-vectors/protocol-v1.json"])
        self.assertNotIn("screenStream", pinned["protocol/test-vectors/protocol-v1.json"])
        self.assertNotIn("protocol/test-vectors/dialer-v1.json", pinned)
        self.assertEqual(set(pinned["protocol/test-vectors/connect-v1.json"]), {"pair", "sealed", "transcript"})

    def test_writing_refuses_a_breaking_change_unless_amended(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp, "baseline.json")
            self.assertEqual(freeze.write_baseline(contract=self.contract, path=path), [])
            changed = copy.deepcopy(self.contract)
            self.kinds(changed)["battery.update"]["payload"]["level"] = "changed by a test"
            before = path.read_text()
            refused = freeze.write_baseline(contract=changed, path=path)
            self.assertEqual(refused, ["kind battery.update: payload.level changed"])
            self.assertEqual(path.read_text(), before)
            self.assertEqual(freeze.write_baseline("a test", contract=changed, path=path), [])
            written = freeze.load_json(path)
            self.assertEqual(written["amendments"][-1]["reason"], "a test")
            self.assertEqual(written["amendments"][-1]["changes"], ["kind battery.update: payload.level changed"])
            self.assertFalse(written["frozen"])

    def test_coverage_lists_every_core_and_extension_kind(self):
        found = freeze.coverage(self.contract)
        wanted = {m["kind"] for m in self.contract["messages"] if m["v1"] in ("core", "extension")}
        self.assertEqual(set(found), wanted)
        self.assertTrue(found["pairing.offer"])


if __name__ == "__main__":
    unittest.main()
