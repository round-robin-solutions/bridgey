#!/usr/bin/env python3
"""Bridgey Protocol v1 contract: protocol/messages.json is the source, docs/protocol-contract.md shows it.

  python3 protocol/tools/contract.py --check   fail when messages.json is invalid or the doc is stale
  python3 protocol/tools/contract.py --write   regenerate the tables in docs/protocol-contract.md
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MESSAGES = ROOT / "protocol" / "messages.json"
DOC = ROOT / "docs" / "protocol-contract.md"
BEGIN = "<!-- BEGIN GENERATED: protocol/tools/contract.py --write -->"
END = "<!-- END GENERATED -->"
KIND = re.compile(r"^[a-z][a-z0-9]*(\.[a-z0-9_]+)+$")
PLATFORMS = {"android", "macos", "cli", "client"}
# A features.update map carries at most this many keys, each at most this many bytes (docs/protocol.md, Session
# negotiation). Senders send only listed keys, so the list itself must fit.
MAX_FEATURE_KEYS = 128
MAX_FEATURE_KEY_BYTES = 64
# Proposed Bridgey Protocol v1 statuses (docs/protocol-v1.md), from the most to the least frozen.
V1_STATUSES = ("core", "extension", "draft", "deprecated")
_V1_RANK = {"core": 0, "extension": 1, "draft": 2}


def load(path=MESSAGES):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def validate(contract):
    """A list of problems; empty when the contract is consistent."""
    problems = []
    statuses = set(contract["statuses"])
    directions = set(contract["directions"])
    features = {f["key"]: f for f in contract["features"]}
    envelope = set(contract["envelope"])
    seen = set()
    for f in contract["features"]:
        if f["status"] not in statuses:
            problems.append(f"feature {f['key']}: unknown status {f['status']}")
        if not 1 <= len(f["key"].encode()) <= MAX_FEATURE_KEY_BYTES:
            problems.append(f"feature {f['key']}: a key is 1 to {MAX_FEATURE_KEY_BYTES} bytes")
    if len(features) > MAX_FEATURE_KEYS:
        problems.append(f"{len(features)} feature keys: a features.update map carries at most {MAX_FEATURE_KEYS}")
    if len(features) != len(contract["features"]):
        problems.append("a feature key is listed twice")
    for m in contract["messages"]:
        kind = m["kind"]
        if kind in seen:
            problems.append(f"{kind}: listed twice")
        seen.add(kind)
        if not KIND.match(kind) or len(kind.encode()) > contract["envelope"]["kind"]["maxBytes"]:
            problems.append(f"{kind}: not a valid kind")
        if m["status"] not in statuses:
            problems.append(f"{kind}: unknown status {m['status']}")
        if m["direction"] not in directions:
            problems.append(f"{kind}: unknown direction {m['direction']}")
        for key in (m["feature"] or "").split(" | "):
            if key and key not in features:
                problems.append(f"{kind}: unknown feature {key}")
        for field in m["outer"]:
            if field.rstrip("?") not in envelope:
                problems.append(f"{kind}: unknown envelope field {field}")
        if "sessionId" not in m["outer"]:
            problems.append(f"{kind}: every message carries sessionId")
        if m["encrypted"] and not {"nonce", "ciphertext"} <= {f.rstrip("?") for f in m["outer"]}:
            problems.append(f"{kind}: encrypted messages carry nonce and ciphertext")
        if not set(m["implemented"]) <= PLATFORMS:
            problems.append(f"{kind}: unknown platform in implemented")
        if m["status"] == "designed" and m["implemented"]:
            problems.append(f"{kind}: designed messages are not implemented")
        if m["status"] == "edition-draft" and not (m["feature"] or "").endswith("_draft1"):
            problems.append(f"{kind}: edition drafts are gated by a *_draft1 key")
    for m in contract["messages"]:
        for reply in m.get("reply", []):
            if reply not in seen:
                problems.append(f"{m['kind']}: reply {reply} is not listed")
    problems += v1_problems(contract)
    return problems


def v1_problems(contract):
    """The proposed v1 statuses (docs/protocol-v1.md) are complete and agree with the feature keys."""
    problems = []
    features = {f["key"]: f for f in contract["features"]}
    for f in contract["features"]:
        v1 = f.get("v1")
        if v1 not in V1_STATUSES:
            problems.append(f"feature {f['key']}: v1 must be one of {', '.join(V1_STATUSES)}")
        elif f["requiredInMap"] != (v1 == "core"):
            problems.append(f"feature {f['key']}: the keys every map must carry are exactly the core keys")
    drafts = [k for k, f in features.items() if f.get("v1") == "draft"]
    for m in contract["messages"]:
        kind, v1 = m["kind"], m.get("v1")
        if v1 not in V1_STATUSES:
            problems.append(f"{kind}: v1 must be one of {', '.join(V1_STATUSES)}")
            continue
        keys = [k for k in (m["feature"] or "").split(" | ") if k in features]
        if v1 != "deprecated":
            # A kind is never more frozen than the least frozen key that gates it.
            ceiling = max((_V1_RANK.get(features[k].get("v1"), 2) for k in keys), default=0)
            if not keys and v1 != "core" and m["status"] != "designed":
                problems.append(f"{kind}: a kind without a feature key is a session message, v1 core")
            elif _V1_RANK[v1] < ceiling:
                problems.append(f"{kind}: v1 {v1} is more frozen than its feature key")
            elif keys and _V1_RANK[v1] != ceiling and v1 != "draft":
                problems.append(f"{kind}: v1 {v1} differs from its feature key")
        if m["status"] == "designed" and v1 != "draft":
            problems.append(f"{kind}: designed kinds are v1 draft")
        listed = m.get("v1DraftFields", [])
        payload = m.get("payload") or {}
        for field in listed:
            if field not in payload:
                problems.append(f"{kind}: v1DraftFields names {field}, which is not in the payload")
        if listed and v1 not in ("core", "extension"):
            problems.append(f"{kind}: v1DraftFields only applies to core and extension kinds")
        if v1 in ("core", "extension"):
            for field, spec in payload.items():
                gated = [k for k in drafts if re.search(r"\b%s\b" % re.escape(k), spec)]
                if gated and field not in listed:
                    problems.append(f"{kind}: {field} is gated by draft {gated[0]}; list it in v1DraftFields")
                if field in listed and not gated:
                    problems.append(f"{kind}: {field} is in v1DraftFields but names no draft key")
    return problems


# The same scan the Android and macOS contract tests run: string literals used as a message kind.
_K = r"[a-z][a-z0-9]*(?:\.[a-z0-9_]+)+"
_SEND = re.compile(r'\bsend\w*\((?:[^()"]*,\s*)?"(%s)"' % _K)
_KOTLIN = [re.compile(r'kind\s*=\s*"(%s)"' % _K), re.compile(r'kind\s*==\s*"(%s)"' % _K),
           re.compile(r'kind get\(\)\s*=\s*"(%s)"' % _K), _SEND, re.compile(r'^\s*[A-Z_]+\("(%s)"\)' % _K)]
_KOTLIN_BRANCH = re.compile(r'^\s*((?:"%s"\s*,\s*)*"%s")\s*->' % (_K, _K))
_SWIFT = [re.compile(r'kind:\s*"(%s)"' % _K), re.compile(r'kind\s*==\s*"(%s)"' % _K), _SEND]
_SWIFT_CASE = re.compile(r'^\s*case\s+((?:"%s"\s*,\s*)*"%s")\s*:' % (_K, _K))


def scan_kinds(root, platform):
    """Kinds the sources of one platform send or handle, mapped to the first file that uses each."""
    found = {}
    suffix, patterns, branch = (".kt", _KOTLIN, _KOTLIN_BRANCH) if platform == "android" else (".swift", _SWIFT, _SWIFT_CASE)
    block, const = (r"object \w*Kinds\s*\{(.*?)\n\}", r'const val \w+ = "(%s)"') if platform == "android" else \
        (r"enum \w*Kinds?\s*\{(.*?)\n\}", r'static let \w+ = "(%s)"')
    for path in sorted(pathlib.Path(root).rglob("*" + suffix)):
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            for pattern in patterns:
                for match in pattern.finditer(line):
                    found.setdefault(match.group(1), path.name)
            match = branch.match(line)
            if match:
                for kind in re.findall(r'"(%s)"' % _K, match.group(1)):
                    found.setdefault(kind, path.name)
        for match in re.finditer(block, text, re.S):
            for kind in re.findall(const % _K, match.group(1)):
                found.setdefault(kind, path.name)
    return found


SOURCES = {"android": ROOT / "android", "macos": ROOT / "macos" / "Sources"}


def coverage_problems(contract):
    problems = []
    listed = {m["kind"]: m for m in contract["messages"]}
    for platform, root in SOURCES.items():
        roots = [p for p in root.rglob("main") if p.is_dir() and p.parent.name == "src"] if platform == "android" else [root]
        found = {}
        for r in roots:
            found.update(scan_kinds(r, platform))
        for kind, file in sorted(found.items()):
            if kind not in listed:
                problems.append(f"{platform}: {kind} (in {file}) is not in protocol/messages.json")
            elif platform not in listed[kind]["implemented"]:
                problems.append(f"{platform}: {kind} (in {file}) is used but messages.json does not list {platform}")
        for kind, m in sorted(listed.items()):
            if platform in m["implemented"] and kind not in found:
                problems.append(f"{platform}: messages.json lists {kind} but the sources never use it")
    return problems


# Feature keys written as literals in the app sources (the edition's keys all end in _draftN). Every one must be listed,
# so no build advertises a key the contract does not know.
_FEATURE_KEY = re.compile(r'"([a-z][a-z0-9_]*_draft[0-9]+)"')
FEATURE_SOURCES = [(ROOT / "android", ".kt"), (ROOT / "macos" / "Sources", ".swift"), (ROOT / "rust", ".rs"),
                   (ROOT / "windows" / "src", ".cs"), (ROOT / "ios", ".swift")]


def _app_source(path):
    parts = path.parts
    return "build" not in parts and "target" not in parts and not any(p in ("test", "tests", "Tests") or p.endswith("Tests")
                                                                         for p in parts)


def feature_key_problems(contract, sources=None):
    listed = {f["key"] for f in contract["features"]}
    problems = []
    for root, suffix in sources or FEATURE_SOURCES:
        for path in sorted(pathlib.Path(root).rglob("*" + suffix)):
            if not _app_source(path.relative_to(root)):
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            if suffix == ".rs":
                text = text.split("\n#[cfg(test)]\nmod ")[0]
            for key in sorted(set(_FEATURE_KEY.findall(text))):
                if key not in listed:
                    where = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
                    problems.append(f"{where}: feature key {key} is not in protocol/messages.json")
    return problems


def _cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def render(contract):
    lines = [BEGIN, ""]
    lines += [_v1_summary(contract), ""]
    lines += ["### Feature keys", "", "| Key | Status | v1 (proposed) | Required in the map | Missing means |", "| --- | --- | --- | --- | --- |"]
    for f in contract["features"]:
        lines.append(f"| `{f['key']}` | {f['status']} | {f.get('v1', '')} | {'yes' if f['requiredInMap'] else 'no'} | {_cell(f['missingMeans'])} |")
    lines += ["", "### Envelope fields", "", "| Field | Type | Required | Limits and notes |", "| --- | --- | --- | --- |"]
    for name, spec in contract["envelope"].items():
        limits = [f"{k} {spec[k]}" for k in ("minBytes", "maxBytes", "min", "max") if k in spec]
        if "note" in spec:
            limits.append(spec["note"])
        if "status" in spec:
            limits.append(spec["status"])
        lines.append(f"| `{name}` | {spec['type']} | {'yes' if spec['required'] else 'no'} | {_cell('; '.join(limits))} |")
    groups = {}
    for m in contract["messages"]:
        groups.setdefault(m["kind"].split(".")[0], []).append(m)
    lines += ["", "### Messages", ""]
    lines.append(f"{len(contract['messages'])} kinds. Envelope fields ending in `?` are optional. "
                 "\"Replay\" is `messageId` (the shared 256-entry window), `sequence` (a per-feature or per-session "
                 "high-water mark) or none.")
    for group, messages in groups.items():
        lines += ["", f"#### `{group}.*`", "", "| Kind | Status | v1 (proposed) | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for m in messages:
            limit = f"{m['maxPlaintextBytes']:,} B" if "maxPlaintextBytes" in m else "frame"
            lines.append(
                f"| `{m['kind']}` | {m['status']} | {m.get('v1', '')} | {m['direction']} | {_cell(m['feature'] or 'none')} | "
                f"{'yes' if m['encrypted'] else 'no'} | {m.get('replay', 'none')} | {limit} | "
                f"{_cell(', '.join(m['outer']))} | {_cell(', '.join(m['implemented']) or 'not yet')} |")
        for m in messages:
            if not m.get("payload") and not m.get("notes") and not m.get("reply"):
                continue
            lines += ["", f"`{m['kind']}`"]
            if m.get("payload"):
                lines.append("")
                for field, spec in m["payload"].items():
                    lines.append(f"- `{field}`: {spec}")
            if m.get("v1DraftFields"):
                lines += ["", "Outside the frozen v1 shape (gated by a draft key): " + ", ".join(f"`{f}`" for f in m["v1DraftFields"]) + "."]
            if m.get("reply"):
                lines += ["", "Answered by " + ", ".join(f"`{r}`" for r in m["reply"]) + "."]
            if m.get("notes"):
                lines += ["", m["notes"]]
    lines += ["", END]
    return "\n".join(lines)


def _v1_summary(contract):
    def count(entries):
        return ", ".join(f"{sum(1 for e in entries if e.get('v1') == s)} {s}" for s in V1_STATUSES
                         if any(e.get("v1") == s for e in entries))
    return (f"Proposed v1 statuses ([protocol-v1.md](protocol-v1.md), not frozen yet): feature keys {count(contract['features'])}; "
            f"message kinds {count(contract['messages'])}.")


def splice(doc_text, generated):
    start, end = doc_text.index(BEGIN), doc_text.index(END) + len(END)
    return doc_text[:start] + generated + doc_text[end:]


def main(argv):
    contract = load()
    problems = validate(contract)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    current = DOC.read_text(encoding="utf-8")
    wanted = splice(current, render(contract))
    if "--write" in argv:
        DOC.write_text(wanted, encoding="utf-8")
        return 0
    if current != wanted:
        print("docs/protocol-contract.md is stale: run python3 protocol/tools/contract.py --write", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
