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
PLATFORMS = {"android", "macos"}


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


def _cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def render(contract):
    lines = [BEGIN, ""]
    lines += ["### Feature keys", "", "| Key | Status | Required in the map | Missing means |", "| --- | --- | --- | --- |"]
    for f in contract["features"]:
        lines.append(f"| `{f['key']}` | {f['status']} | {'yes' if f['requiredInMap'] else 'no'} | {_cell(f['missingMeans'])} |")
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
        lines += ["", f"#### `{group}.*`", "", "| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for m in messages:
            limit = f"{m['maxPlaintextBytes']:,} B" if "maxPlaintextBytes" in m else "frame"
            lines.append(
                f"| `{m['kind']}` | {m['status']} | {m['direction']} | {_cell(m['feature'] or 'none')} | "
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
            if m.get("reply"):
                lines += ["", "Answered by " + ", ".join(f"`{r}`" for r in m["reply"]) + "."]
            if m.get("notes"):
                lines += ["", m["notes"]]
    lines += ["", END]
    return "\n".join(lines)


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
