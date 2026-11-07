#!/usr/bin/env python3
"""Shared strict call/media payload cases; generated data contains no real call or media content."""

import copy
import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "test-vectors" / "call-media-v1.json"


def vectors():
    state = []
    result = []

    def case(target, name, payload, valid=True, raw=False):
        target.append({"name": name, "plaintextString" if raw else "plaintext": payload, "valid": valid})

    def changed(target, base, name, field, value):
        payload = copy.deepcopy(base)
        payload[field] = value
        case(target, name, payload, False)

    base = {"version": 1, "revision": 1, "calls": ["call_1"], "uncertain": False}
    case(state, "one opaque call", base)
    case(state, "explicit end", {**base, "revision": 2, "calls": []})
    case(state, "lost source without confirmed end", {**base, "calls": [], "uncertain": True})
    case(state, "known call with another source uncertain", {**base, "uncertain": True})
    case(state, "maximum revision and calls", {**base, "revision": 2_147_483_647, "calls": [f"call_{i}" for i in range(16)]})
    case(state, "maximum ID length", {**base, "calls": ["a" * 64]})
    case(state, "ASCII ID alphabet", {**base, "calls": ["aZ09_-" ]})
    for name, field, value in [
        ("version boolean", "version", True),
        ("version string", "version", "1"),
        ("unknown version", "version", 2),
        ("revision zero", "revision", 0),
        ("revision negative", "revision", -1),
        ("revision boolean", "revision", True),
        ("revision decimal", "revision", 1.5),
        ("revision string", "revision", "1"),
        ("revision too large", "revision", 2_147_483_648),
        ("uncertainty number", "uncertain", 1),
        ("uncertainty string", "uncertain", "false"),
        ("uncertainty null", "uncertain", None),
        ("calls not an array", "calls", "call_1"),
        ("calls null", "calls", None),
        ("too many calls", "calls", [f"call_{i}" for i in range(17)]),
        ("duplicate call", "calls", ["call_1", "call_1"]),
        ("empty call ID", "calls", [""]),
        ("long call ID", "calls", ["a" * 65]),
        ("non-string call ID", "calls", [3]),
        ("unicode call ID", "calls", ["café"]),
        ("call ID whitespace", "calls", ["call 1"]),
        ("call ID punctuation", "calls", ["call.1"]),
        ("untrusted payload origin", "origin", "some_other_peer"),
    ]:
        changed(state, base, name, field, value)
    for field in base:
        missing = dict(base)
        del missing[field]
        case(state, f"missing {field}", missing, False)
    state_text = json.dumps(base, separators=(",", ":"))
    case(state, "exact state byte boundary", state_text + " " * (2048 - len(state_text)), raw=True)
    case(state, "state byte boundary exceeded", state_text + " " * (2049 - len(state_text)), False, raw=True)
    case(state, "duplicate version key", '{"version":1,"version":1,"revision":1,"calls":[],"uncertain":false}', False, raw=True)
    case(state, "escaped key accepted", '{"\\u0076ersion":1,"revision":1,"calls":[],"uncertain":false}', raw=True)
    case(state, "escaped duplicate key", '{"\\u0076ersion":1,"version":1,"revision":1,"calls":[],"uncertain":false}', False, raw=True)
    case(state, "two JSON roots", state_text + "{}", False, raw=True)
    case(state, "array root", "[]", False, raw=True)
    case(state, "invalid JSON", '{"version":', False, raw=True)

    base = {"version": 1, "revision": 1, "paused": 1, "muted": 0, "limited": 0, "issues": []}
    case(result, "observed pause", base)
    case(result, "bounded partial outcome", {**base, "paused": 64, "muted": 64, "limited": 64,
        "issues": ["unsupported", "call_audio_protected", "selective_mute_unavailable"]})
    case(result, "all issue codes", {**base, "issues": [
        "permission_needed", "unsupported", "call_audio_protected", "changed_by_user", "session_gone",
        "command_failed", "cancelled", "other_players_limited", "selective_mute_unavailable",
    ]})
    case(result, "last valid revision", {**base, "revision": 2_147_483_647})
    for field in ("paused", "muted", "limited"):
        for name, value in (("negative", -1), ("too large", 65), ("boolean", True), ("decimal", 0.5), ("string", "1")):
            changed(result, base, f"{field} {name}", field, value)
    for name, field, value in [
        ("version boolean", "version", True),
        ("unknown version", "version", 2),
        ("revision zero", "revision", 0),
        ("revision boolean", "revision", True),
        ("revision decimal", "revision", 1.5),
        ("revision too large", "revision", 2_147_483_648),
        ("issues null", "issues", None),
        ("issues not array", "issues", "unsupported"),
        ("unknown issue", "issues", ["everything_is_quiet"]),
        ("non-string issue", "issues", [1]),
        ("duplicate issue", "issues", ["unsupported", "unsupported"]),
        ("too many issues", "issues", ["unsupported"] * 17),
        ("extra metadata", "title", "must_not_be_sent"),
    ]:
        changed(result, base, name, field, value)
    for field in base:
        missing = dict(base)
        del missing[field]
        case(result, f"missing {field}", missing, False)
    result_text = json.dumps(base, separators=(",", ":"))
    case(result, "exact result byte boundary", result_text + " " * (1024 - len(result_text)), raw=True)
    case(result, "result byte boundary exceeded", result_text + " " * (1025 - len(result_text)), False, raw=True)
    case(result, "duplicate count key", '{"version":1,"revision":1,"paused":0,"paused":1,"muted":0,"limited":0,"issues":[]}', False, raw=True)
    case(result, "two result roots", result_text + "{}", False, raw=True)
    return {"format": "bridgey.call-media.v1", "state": state, "result": result}


if __name__ == "__main__":
    payload = vectors()
    OUT.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{len(payload['state'])} state cases, {len(payload['result'])} result cases")
