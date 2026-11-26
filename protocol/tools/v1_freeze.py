#!/usr/bin/env python3
"""Bridgey Protocol v1 freeze check (docs/protocol-v1.md). Report only until the freeze is approved.

  python3 protocol/tools/v1_freeze.py --check
      list every change to a v1-frozen entry or vector since protocol/v1-baseline.json; exit 1 only when enforced
  python3 protocol/tools/v1_freeze.py --write-baseline
      record what is frozen now (new frozen entries, deprecations, new vectors); refuses to record a breaking change
  python3 protocol/tools/v1_freeze.py --write-baseline --amend "why"
      also record breaking changes, logged with the reason in the baseline's amendments
  python3 protocol/tools/v1_freeze.py --coverage
      core and extension kinds, the vector files that pin them and the test suites that read those files

Enforced when protocol/v1-baseline.json says "frozen": true, or BRIDGEY_PROTOCOL_V1_FROZEN=1 is set.
Frozen means v1 core, extension or deprecated in protocol/messages.json.
"""
import datetime
import hashlib
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MESSAGES = ROOT / "protocol" / "messages.json"
BASELINE = ROOT / "protocol" / "v1-baseline.json"
ENV = "BRIDGEY_PROTOCOL_V1_FROZEN"
FROZEN = ("core", "extension", "deprecated")
# Allowed moves between v1 statuses; anything else that leaves the frozen set is breaking.
ALLOWED = {("core", "deprecated"), ("extension", "deprecated")}
# Not part of an entry's frozen shape: where it is implemented grows over time, v1 and v1DraftFields are compared on
# their own, and the older status label (upstream-v1, edition-draft) is superseded by v1 and may be relabelled.
NOT_SHAPE = ("implemented", "status", "v1", "v1DraftFields")
# A summary of each feature's own decryption rule, which is frozen with that feature; new drafts extend it.
UNFROZEN_TRANSPORT = ("onUndecryptablePayload",)

# Vector groups that pin frozen entries, with the feature keys they pin ("session" for pairing, the envelope and
# features.update). A group counts only while every key it names is frozen. None stands for every top-level key of the
# file but its description. Cases are hashed one by one, so new cases are additions and never break the check.
VECTORS = [
    ("protocol/test-vectors/crypto-v1.properties", None, ["session"]),
    ("protocol/test-vectors/protocol-v1.json", "sessionId", ["session"]),
    ("protocol/test-vectors/protocol-v1.json", "frames", ["session"]),
    ("protocol/test-vectors/protocol-v1.json", "featuresUpdate", ["session"]),
    ("protocol/test-vectors/protocol-v1.json", "batteryUpdate", ["battery"]),
    ("protocol/test-vectors/protocol-v1.json", "clipboardRich", ["clipboard"]),
    ("protocol/test-vectors/protocol-v1.json", "callsRequest", ["calls"]),
    ("protocol/test-vectors/protocol-v1.json", "clipboardOffer", ["clipboard_files_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "remoteInput", ["remote_input_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "browseRef", ["files_browse_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "focusState", ["focus_sync_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "actionsCatalog", ["mac_actions_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "actionsRun", ["mac_actions_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "actionsResult", ["mac_actions_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "cameraRequest", ["camera_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "cameraStatus", ["camera_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "updatesStatus", ["updates_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "updatesStart", ["updates_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "updatesResult", ["updates_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "screenRequest", ["screen_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "screenStatus", ["screen_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "screenStream", ["screen_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "screenFrame", ["screen_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "smsRequest", ["sms_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "smsSend", ["sms_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "smsStatus", ["sms_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "smsMessage", ["sms_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "smsSendStatus", ["sms_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "smsMarkReadResult", ["sms_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "smsBlockedNumbersResult", ["sms_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "settingsPayload", ["settings_sync_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "settingsMerge", ["settings_sync_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "settingsSnapshot", ["settings_sync_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "settingsAsker", ["settings_sync_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "settingsStamp", ["settings_sync_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "connectSetup", ["connect_draft1"]),
    ("protocol/test-vectors/protocol-v1.json", "connectAddresses", ["connect_draft1"]),
    # Sessions recorded between two rust/client peers; the notifications one also carries presence.state.
    ("protocol/test-vectors/session-client-v1.json", None, ["session", "clipboard"]),
    ("protocol/test-vectors/session-client-files-v1.json", None, ["files", "battery", "find_device", "files_fast_draft1"]),
    ("protocol/test-vectors/session-client-notifications-v1.json", None, ["notifications", "sms_codes_draft1"]),
    ("protocol/test-vectors/session-client-quick-v1.json", None, ["links", "media"]),
    ("protocol/test-vectors/session-client-resume-v1.json", None, ["files_resume_draft1"]),
    ("protocol/test-vectors/files-fast-v1.json", None, ["files_fast_draft1"]),
    ("protocol/test-vectors/files-resume-v1.json", None, ["files_resume_draft1"]),
    ("protocol/test-vectors/folders-v1.json", None, ["folders_draft1"]),
    ("protocol/test-vectors/agent-v1.json", None, ["agent_draft1"]),
    ("protocol/test-vectors/agents-mirror-v1.json", None, ["agents_mirror_draft1"]),
    # Peer to peer parts of Connect anywhere. nodeAuth and turn* are between a device and the control service.
    ("protocol/test-vectors/connect-v1.json", "pair", ["connect_draft1"]),
    ("protocol/test-vectors/connect-v1.json", "sealed", ["connect_draft1"]),
    ("protocol/test-vectors/connect-v1.json", "transcript", ["connect_draft1"]),
    ("protocol/test-vectors/device-presence-v1.json", None, ["device_presence_draft1"]),
    ("protocol/test-vectors/call-media-v1.json", None, ["call_quiet_draft1"]),
    ("protocol/test-vectors/dialer-v1.json", None, ["dialer_draft1"]),
    ("protocol/test-vectors/display-v1.json", None, ["screen_control_draft1"]),
    ("protocol/test-vectors/phone-control-v1.json", None, ["phone_control_draft1"]),
    ("rust/proto/test-vectors/screen-control-v1.json", None, ["screen_control_draft1"]),
]


def load_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def _hash(value):
    text = value if isinstance(value, str) else json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _cases(value):
    """One hash per case: named cases by name, other lists by index, anything else as one case."""
    if isinstance(value, list):
        names = [c.get("name") if isinstance(c, dict) else None for c in value]
        if all(isinstance(n, str) for n in names) and len(set(names)) == len(names):
            return {n: _hash(c) for n, c in zip(names, value)}
        return {str(i): _hash(c) for i, c in enumerate(value)}
    return {"": _hash(value)}


def vector_cases(root, file, group):
    path = pathlib.Path(root) / file
    if file.endswith(".properties"):
        pairs = (line.split("=", 1) for line in path.read_text(encoding="utf-8").splitlines() if "=" in line)
        return {k.strip(): _hash(v.strip()) for k, v in pairs}
    data = load_json(path)
    if group is None:
        return {f"{key}/{case}" if case else key: digest for key, value in data.items() if key != "description"
                for case, digest in _cases(value).items()}
    return _cases(data[group]) if group in data else {}


def _frozen_keys(contract):
    return {"session"} | {f["key"] for f in contract["features"] if f.get("v1") in FROZEN}


def _shape(entry):
    shape = {k: v for k, v in entry.items() if k not in NOT_SHAPE}
    if entry.get("v1DraftFields"):
        shape["payload"] = {k: v for k, v in entry["payload"].items() if k not in entry["v1DraftFields"]}
    return shape


def frozen_view(contract, root=ROOT):
    """What the baseline records: everything v1 freezes, as it is in this tree."""
    keys = _frozen_keys(contract)
    vectors = {}
    for file, group, pins in VECTORS:
        if set(pins) <= keys:
            vectors.setdefault(file, {})[group or ""] = vector_cases(root, file, group)
    return {
        "transport": {k: v for k, v in contract["transport"].items() if k not in UNFROZEN_TRANSPORT},
        "envelope": contract["envelope"],
        "features": {f["key"]: {"v1": f["v1"], "shape": _shape(f)} for f in contract["features"] if f.get("v1") in FROZEN},
        "messages": {m["kind"]: {"v1": m["v1"], "shape": _shape(m)} for m in contract["messages"] if m.get("v1") in FROZEN},
        "vectors": vectors,
    }


def _diff(a, b, path=""):
    """Short descriptions of what differs between two JSON values."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            where = f"{path}.{k}" if path else k
            if k not in b:
                out.append(f"{where} removed")
            elif k not in a:
                out.append(f"{where} added")
            else:
                out += _diff(a[k], b[k], where)
        return out
    return [] if a == b else [f"{path or 'value'} changed"]


def compare(baseline, current, contract):
    """(severity, text) for every difference. breaking and unrecorded fail when enforced; info never does."""
    problems = []
    for section in ("transport", "envelope"):
        for change in _diff(baseline.get(section, {}), current[section]):
            problems.append(("breaking", f"{section}: {change}"))
    statuses = {"features": {f["key"]: f.get("v1") for f in contract["features"]},
                "messages": {m["kind"]: m.get("v1") for m in contract["messages"]}}
    for section, label in (("features", "feature"), ("messages", "kind")):
        old, new = baseline.get(section, {}), current[section]
        for name, entry in old.items():
            if name not in new:
                now = statuses[section].get(name)
                if now is None:
                    problems.append(("breaking", f"{label} {name}: removed from protocol/messages.json while v1 {entry['v1']}"))
                else:
                    problems.append(("breaking", f"{label} {name}: v1 {entry['v1']} became {now} (unfrozen)"))
                continue
            if entry["v1"] != new[name]["v1"]:
                move = (entry["v1"], new[name]["v1"])
                problems.append(("unrecorded" if move in ALLOWED else "breaking",
                                 f"{label} {name}: v1 {move[0]} became {move[1]}"))
            for change in _diff(entry["shape"], new[name]["shape"]):
                problems.append(("breaking", f"{label} {name}: {change}"))
        for name in new:
            if name not in old:
                problems.append(("unrecorded", f"{label} {name}: v1 {new[name]['v1']} but not in the baseline"))
    old_vectors, new_vectors = baseline.get("vectors", {}), current["vectors"]
    for file, groups in old_vectors.items():
        for group, cases in groups.items():
            label = f"{file}{'#' + group if group else ''}"
            now = new_vectors.get(file, {}).get(group)
            if now is None:
                problems.append(("breaking", f"vectors {label}: no longer pinned (removed, or its feature left v1)"))
                continue
            for case, digest in cases.items():
                if case not in now:
                    problems.append(("breaking", f"vectors {label}: {case or 'the file'} removed"))
                elif now[case] != digest:
                    problems.append(("breaking", f"vectors {label}: {case or 'the file'} changed"))
            added = [c for c in now if c not in cases]
            if added:
                problems.append(("info", f"vectors {label}: {len(added)} new case(s) not recorded yet"))
    for file, groups in new_vectors.items():
        for group in groups:
            if group not in old_vectors.get(file, {}):
                problems.append(("unrecorded", f"vectors {file}{'#' + group if group else ''}: pinned but not in the baseline"))
    return problems


def enforced(baseline, environ=os.environ):
    return baseline.get("frozen") is True or environ.get(ENV, "").strip().lower() in ("1", "true", "yes")


def check(contract=None, baseline=None, root=ROOT):
    contract = contract if contract is not None else load_json(MESSAGES)
    baseline = baseline if baseline is not None else load_json(BASELINE)
    return compare(baseline, frozen_view(contract, root), contract)


def report(problems, is_enforced):
    mode = "enforced" if is_enforced else (
        f'report only; set "frozen": true in protocol/v1-baseline.json or {ENV}=1 to enforce')
    lines = [f"Bridgey Protocol v1 freeze check ({mode})"]
    if not problems:
        lines.append("  no changes to v1-frozen entries or vectors")
    for severity, text in problems:
        lines.append(f"  {severity}: {text}")
    if any(s == "breaking" for s, _ in problems):
        lines.append("  A breaking change needs a new feature key (docs/protocol-v1.md, Versioning after v1). "
                     "Recording it anyway: python3 protocol/tools/v1_freeze.py --write-baseline --amend \"why\"")
    elif any(s == "unrecorded" for s, _ in problems):
        lines.append("  Record these: python3 protocol/tools/v1_freeze.py --write-baseline")
    return "\n".join(lines)


def write_baseline(amend=None, contract=None, path=BASELINE, root=ROOT, today=None):
    """Writes the baseline; returns the breaking problems it refused to record (empty when written)."""
    contract = contract if contract is not None else load_json(MESSAGES)
    current = frozen_view(contract, root)
    path = pathlib.Path(path)
    old = load_json(path) if path.exists() else None
    amendments = old.get("amendments", []) if old else []
    if old:
        problems = compare(old, current, contract)
        breaking = [t for s, t in problems if s == "breaking"]
        if breaking and not amend:
            return breaking
        if breaking:
            amendments.append({"date": (today or datetime.date.today()).isoformat(), "reason": amend, "changes": breaking})
    baseline = {
        "description": "Bridgey Protocol v1 freeze baseline (docs/protocol-v1.md): every v1 core, extension and deprecated "
                       "entry of protocol/messages.json and a hash of each vector case that pins one, as recorded by "
                       "protocol/tools/v1_freeze.py --write-baseline. Proposal: report only while frozen is false.",
        "frozen": old.get("frozen", False) if old else False,
        "contractVersion": contract["contractVersion"],
        "amendments": amendments,
    }
    baseline.update(current)
    path.write_text(json.dumps(baseline, indent=1, ensure_ascii=False, sort_keys=False) + "\n", encoding="utf-8")
    return []


# Payload vector groups that name no kind in their cases, and the kinds they pin (some only in part).
GROUP_KINDS = {
    "featuresUpdate": ["features.update"], "batteryUpdate": ["battery.update"], "clipboardRich": ["clipboard.rich"],
    "callsRequest": ["calls.request"], "clipboardOffer": ["clipboard.offer"], "focusState": ["focus.state"],
    "browseRef": ["places.files", "places.download", "media.thumbnails", "media.preview", "media.range", "media.page"],
    "actionsCatalog": ["actions.catalog"], "actionsRun": ["actions.run"], "actionsResult": ["actions.result"],
    "cameraRequest": ["camera.request"], "cameraStatus": ["camera.status"], "updatesStatus": ["updates.status"],
    "updatesStart": ["updates.start"], "updatesResult": ["updates.result"], "smsSend": ["sms.send"],
    "smsStatus": ["sms.status"], "smsMessage": ["sms.messages_page", "sms.sync_page"], "smsSendStatus": ["sms.send_status"],
    "smsMarkReadResult": ["sms.mark_read_result"], "smsBlockedNumbersResult": ["sms.blocked_numbers_result"],
    "settingsPayload": ["settings.snapshot", "settings.update"], "connectSetup": ["connect.setup"],
    "connectAddresses": ["connect.addresses"], "agentGrants": ["agent.grants"], "notifyPost": ["notify.post"],
    "askRequest": ["ask.request"], "askAnswer": ["ask.answer"], "clipboardResponse": ["clipboard.response"],
    "codesQuery": ["codes.query"], "codesResult": ["codes.result"], "codesFound": ["codes.found"],
    "codesCandidate": ["codes.candidate"], "codesDetected": ["codes.detected"], "agentsGrantSet": ["agents.grant_set"],
    "agentsState": ["agents.state"], "codesRead": ["codes.read"], "fastFrame": ["files.chunk"],
}
SUITES = {
    "android": ["android/app/src/test", "android/core"],
    "macos": ["macos/Tests"],
    "rust": ["rust"],
    "python": ["scripts/rr/tests"],
}


def _suite_texts(root):
    texts = {}
    for suite, dirs in SUITES.items():
        for d in dirs:
            for path in sorted((pathlib.Path(root) / d).rglob("*")):
                if path.suffix not in (".kt", ".swift", ".rs", ".py") or "/build/" in path.as_posix():
                    continue
                if suite == "android" and "/test/" not in path.as_posix():
                    continue
                text = path.read_text(encoding="utf-8", errors="replace")
                if suite == "rust" and "#[test]" not in text:
                    continue
                texts.setdefault(suite, []).append(text)
    return texts


def coverage(contract=None, root=ROOT):
    """For each core and extension kind: [(vector file#group, suites that read it)]."""
    contract = contract if contract is not None else load_json(MESSAGES)
    texts = _suite_texts(root)
    files = sorted({f for f, _, _ in VECTORS})
    found = {m["kind"]: [] for m in contract["messages"] if m.get("v1") in ("core", "extension")}
    for file in files:
        name = pathlib.Path(file).name
        path = pathlib.Path(root) / file
        raw = path.read_text(encoding="utf-8")
        data = load_json(path) if file.endswith(".json") else {}
        groups = [k for k, v in data.items() if isinstance(v, (list, dict))] or [None]
        for group in groups:
            body = json.dumps(data[group], ensure_ascii=False) if group else raw
            readers = sorted(s for s, ts in texts.items()
                             if any(name in t and (group is None or f'"{group}"' in t or len(groups) == 1) for t in ts))
            kinds = set(GROUP_KINDS.get(group, []))
            kinds |= {k for k in found if f'"{k}"' in body or f'\\"{k}\\"' in body}
            for kind in kinds & set(found):
                found[kind].append((f"{name}#{group}" if group else name, readers))
    return found


def coverage_report(contract=None, root=ROOT):
    contract = contract if contract is not None else load_json(MESSAGES)
    found = coverage(contract, root)
    v1 = {m["kind"]: m["v1"] for m in contract["messages"]}
    lines, none, single = [], [], []
    for kind, hits in found.items():
        suites = sorted({s for _, readers in hits for s in readers if s != "python"})
        lines.append(f"{kind:32} {v1[kind]:10} {', '.join(sorted({h for h, _ in hits})) or '-'}  [{', '.join(suites) or 'no suite'}]")
        if not hits:
            none.append(kind)
        elif len(suites) < 2:
            single.append(kind)
    lines += ["", f"No vectors ({len(none)}): " + ", ".join(none),
              f"Read by fewer than two of android, macos, rust ({len(single)}): " + ", ".join(single)]
    return "\n".join(lines)


def main(argv):
    if "--coverage" in argv:
        print(coverage_report())
        return 0
    if "--write-baseline" in argv:
        amend = argv[argv.index("--amend") + 1] if "--amend" in argv and argv.index("--amend") + 1 < len(argv) else None
        refused = write_baseline(amend)
        if refused:
            print("Not written: these change v1-frozen entries or vectors. Add --amend \"why\" to record them.", file=sys.stderr)
            print("\n".join("  " + t for t in refused), file=sys.stderr)
            return 1
        return 0
    if "--check" in argv:
        baseline = load_json(BASELINE)
        problems = check(baseline=baseline)
        is_enforced = enforced(baseline)
        print(report(problems, is_enforced), file=sys.stderr if problems else sys.stdout)
        return 1 if is_enforced and any(s in ("breaking", "unrecorded") for s, _ in problems) else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
