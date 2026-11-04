#!/usr/bin/env python3
"""Writes protocol/test-vectors/agent-v1.json: golden vectors for agent devices (docs/protocol.md, agent devices).

The Android app, the Mac app and the bridgey command each decode the payloads they receive and check the
invite derivations. Edit here, then run it. Stdlib only.
"""
import base64
import hashlib
import hmac
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parents[1] / "test-vectors" / "agent-v1.json"
U = "01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d21"
U2 = "01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d22"
T = 1798000000000


def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def hkdf(ikm, salt, info, length=32):
    prk = hmac.new(salt or b"\0" * 32, ikm, hashlib.sha256).digest()
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


def case(name, plaintext, expect, **extra):
    v = {"name": name, "plaintext": plaintext, "expect": expect}
    v.update(extra)
    return v


secret = bytes(range(1, 33))
invite_json = {"v": 1, "s": b64u(secret), "c": "wss://connect.roundrobin.in/v1/ws", "n": "Contabo Europe", "p": "cli", "x": 1798000600}
invite_text = json.dumps(invite_json, separators=(",", ":"))
exporter = base64.b64encode(bytes(range(100, 132))).decode()
transcript = "\0".join(["bridgey-auth-v2", "sess-1", "phone-id", "agent-id", "BAAA", "BBBB", exporter, base64.b64encode(hashlib.sha256(secret).digest()).decode()])

invite = {
    "secret": base64.b64encode(secret).decode(),
    "json": invite_text,
    "link": "bridgey://pair#" + b64u(invite_text.encode()),
    "rdv": b64u(hmac.new(secret, b"bridgey-invite-rdv-v1", hashlib.sha256).digest()[:16]),
    "sigKey": base64.b64encode(hkdf(secret, b"", b"bridgey-invite-signal-v1")).decode(),
    "inviteHash": base64.b64encode(hashlib.sha256(secret).digest()).decode(),
    "transcript": {"sessionId": "sess-1", "initiatorId": "phone-id", "responderId": "agent-id", "initiatorKey": "BAAA",
                   "responderKey": "BBBB", "exporter": exporter, "expected": base64.b64encode(transcript.encode()).decode()},
    "invalid": [
        {"name": "version 2", "json": json.dumps({**invite_json, "v": 2})},
        {"name": "secret of 31 bytes", "json": json.dumps({**invite_json, "s": b64u(secret[:31])})},
        {"name": "no control URL", "json": json.dumps({k: v for k, v in invite_json.items() if k != "c"})},
        {"name": "expiry not a number", "json": json.dumps({**invite_json, "x": "soon"})},
        {"name": "name over 64 characters", "json": json.dumps({**invite_json, "n": "n" * 65})},
    ],
}

grant_on = {"key": "notify", "state": "on", "window": "1h", "grantedAt": T, "expiresAt": T + 3600000}
vectors = {
    "description": "Agent devices (docs/protocol.md, agent devices). expect 'reject' means drop the message; otherwise the fields a decoder keeps.",
    "invite": invite,
    "agentGrants": [
        case("every grant", {"version": 1, "grants": [grant_on, {"key": "files", "state": "on", "window": "forever", "grantedAt": T, "scope": "Download/Bridgey/Contabo Europe"},
                                                      {"key": "codes", "state": "waiting"}, {"key": "ring", "state": "off"}]},
             {"grants": [grant_on, {"key": "files", "state": "on", "window": "forever", "grantedAt": T, "scope": "Download/Bridgey/Contabo Europe"},
                         {"key": "codes", "state": "waiting"}, {"key": "ring", "state": "off"}]}),
        case("unknown grant keys and fields are skipped", {"version": 1, "grants": [{"key": "teleport", "state": "on"}, {**grant_on, "future": 1}]}, {"grants": [grant_on]}),
        case("unknown state reads as off", {"version": 1, "grants": [{"key": "battery", "state": "maybe"}]}, {"grants": [{"key": "battery", "state": "off"}]}),
        case("version 2 is ignored", {"version": 2, "grants": []}, "reject"),
        case("grants not an array", {"version": 1, "grants": {}}, "reject"),
    ],
    "notifyPost": [
        case("full", {"version": 1, "notifyId": U, "title": "Nightly passed", "body": "bridgey 0.1.0", "priority": "high", "tag": "ci", "from": "RR CI"},
             {"notifyId": U, "title": "Nightly passed", "body": "bridgey 0.1.0", "priority": "high", "tag": "ci", "from": "RR CI"}),
        case("minimal", {"version": 1, "notifyId": U, "title": "Hi", "priority": "normal"}, {"notifyId": U, "title": "Hi", "priority": "normal"}),
        case("control and bidi characters are removed", {"version": 1, "notifyId": U, "title": "A\u202eB\u0007C", "priority": "normal"},
             {"notifyId": U, "title": "ABC", "priority": "normal"}),
        case("empty title", {"version": 1, "notifyId": U, "title": "", "priority": "normal"}, "reject"),
        case("title of 121 characters", {"version": 1, "notifyId": U, "title": "t" * 121, "priority": "normal"}, "reject"),
        case("body of 1,001 characters", {"version": 1, "notifyId": U, "title": "t", "body": "b" * 1001, "priority": "normal"}, "reject"),
        case("unknown priority", {"version": 1, "notifyId": U, "title": "t", "priority": "urgent"}, "reject"),
        case("notifyId not a UUID", {"version": 1, "notifyId": "x", "title": "t", "priority": "normal"}, "reject"),
    ],
    "askRequest": [
        case("two options", {"version": 1, "askId": U, "title": "Deploy rr-web?", "body": "3 migrations", "options": [{"id": "approve", "label": "Approve"}, {"id": "deny", "label": "Deny"}],
                             "allowText": False, "requireUnlock": True, "expiresAt": T + 1200000, "from": "RR CI"},
             {"askId": U, "title": "Deploy rr-web?", "body": "3 migrations", "options": [{"id": "approve", "label": "Approve"}, {"id": "deny", "label": "Deny"}],
              "allowText": False, "requireUnlock": True, "expiresAt": T + 1200000, "from": "RR CI"}, now=T),
        case("text only", {"version": 1, "askId": U, "title": "Headline?", "options": [], "allowText": True, "textHint": "One line", "requireUnlock": False, "expiresAt": T + 3600000},
             {"askId": U, "title": "Headline?", "options": [], "allowText": True, "textHint": "One line", "requireUnlock": False, "expiresAt": T + 3600000}, now=T),
        case("no option and no text", {"version": 1, "askId": U, "title": "t", "options": [], "allowText": False, "requireUnlock": False, "expiresAt": T + 60000}, "reject", now=T),
        case("three options with text", {"version": 1, "askId": U, "title": "t", "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}, {"id": "c", "label": "C"}],
                                          "allowText": True, "requireUnlock": False, "expiresAt": T + 60000}, "reject", now=T),
        case("four options", {"version": 1, "askId": U, "title": "t", "options": [{"id": x, "label": x} for x in "abcd"], "allowText": False, "requireUnlock": False, "expiresAt": T + 60000}, "reject", now=T),
        case("option id with a capital", {"version": 1, "askId": U, "title": "t", "options": [{"id": "Yes", "label": "Yes"}], "allowText": False, "requireUnlock": False, "expiresAt": T + 60000}, "reject", now=T),
        case("duplicate option ids", {"version": 1, "askId": U, "title": "t", "options": [{"id": "a", "label": "A"}, {"id": "a", "label": "B"}], "allowText": False, "requireUnlock": False, "expiresAt": T + 60000}, "reject", now=T),
        case("label of 21 characters", {"version": 1, "askId": U, "title": "t", "options": [{"id": "a", "label": "l" * 21}], "allowText": False, "requireUnlock": False, "expiresAt": T + 60000}, "reject", now=T),
        case("expiry over 24 hours ahead", {"version": 1, "askId": U, "title": "t", "options": [{"id": "a", "label": "A"}], "allowText": False, "requireUnlock": False, "expiresAt": T + 86400001}, "reject", now=T),
        case("expiry in the past", {"version": 1, "askId": U, "title": "t", "options": [{"id": "a", "label": "A"}], "allowText": False, "requireUnlock": False, "expiresAt": T - 1}, "reject", now=T),
    ],
    "askAnswer": [
        case("option", {"version": 1, "askId": U, "option": "approve", "answeredAt": T}, {"askId": U, "option": "approve", "answeredAt": T}),
        case("text", {"version": 1, "askId": U, "text": "Ship it", "answeredAt": T}, {"askId": U, "text": "Ship it", "answeredAt": T}),
        case("neither", {"version": 1, "askId": U, "answeredAt": T}, "reject"),
        case("text of 1,001 characters", {"version": 1, "askId": U, "text": "x" * 1001, "answeredAt": T}, "reject"),
    ],
    "clipboardResponse": [
        case("sent", {"version": 1, "requestId": U, "status": "sent", "text": "hello"}, {"requestId": U, "status": "sent", "text": "hello"}),
        case("declined", {"version": 1, "requestId": U, "status": "declined"}, {"requestId": U, "status": "declined"}),
        case("sent without text", {"version": 1, "requestId": U, "status": "sent"}, "reject"),
        case("over 32 KiB", {"version": 1, "requestId": U, "status": "sent", "text": "x" * 32769}, "reject"),
    ],
    "codesQuery": [
        case("wait for HDFC", {"version": 1, "queryId": U, "service": "HDFC Bank", "sinceMs": 600000, "newerThan": T, "waitMs": 120000, "latestOnly": True},
             {"queryId": U, "service": "HDFC Bank", "sinceMs": 600000, "newerThan": T, "waitMs": 120000, "latestOnly": True}),
        case("everything recent", {"version": 1, "queryId": U, "sinceMs": 900000, "waitMs": 0, "latestOnly": False},
             {"queryId": U, "sinceMs": 900000, "waitMs": 0, "latestOnly": False}),
        case("since over an hour", {"version": 1, "queryId": U, "sinceMs": 3600001, "waitMs": 0, "latestOnly": False}, "reject"),
        case("wait over 10 minutes", {"version": 1, "queryId": U, "sinceMs": 0, "waitMs": 600001, "latestOnly": False}, "reject"),
    ],
    "codesResult": [
        case("two codes", {"version": 1, "queryId": U, "readers": 1, "timedOut": False, "codes": [
            {"code": "482913", "service": "HDFC Bank", "source": "sms", "app": "messages", "postedAt": T, "latest": True, "replaced": False, "via": ["sms", "email:gmail"]},
            {"code": "119204", "service": "HDFC Bank", "source": "sms", "app": "messages", "postedAt": T - 60000, "latest": False, "replaced": True, "via": ["sms"]}]},
             {"queryId": U, "readers": 1, "timedOut": False, "codes": [
                 {"code": "482913", "service": "HDFC Bank", "source": "sms", "app": "messages", "postedAt": T, "latest": True, "replaced": False, "via": ["sms", "email:gmail"]},
                 {"code": "119204", "service": "HDFC Bank", "source": "sms", "app": "messages", "postedAt": T - 60000, "latest": False, "replaced": True, "via": ["sms"]}]}),
        case("timed out", {"version": 1, "queryId": U, "readers": 0, "timedOut": True, "codes": []}, {"queryId": U, "readers": 0, "timedOut": True, "codes": []}),
        case("unknown source", {"version": 1, "queryId": U, "readers": 1, "timedOut": False, "codes": [
            {"code": "482913", "service": "X", "source": "fax", "app": "x", "postedAt": T, "latest": True, "replaced": False, "via": []}]}, "reject"),
    ],
    "codesFound": [
        case("sms", {"version": 1, "foundId": U2, "code": "482913", "service": "HDFC Bank", "serviceKey": "hdfc bank", "source": "sms", "app": "messages", "notificationId": "0|com.google.android.apps.messaging|7|null|10123", "postedAt": T},
             {"foundId": U2, "code": "482913", "service": "HDFC Bank", "serviceKey": "hdfc bank", "source": "sms", "app": "messages", "notificationId": "0|com.google.android.apps.messaging|7|null|10123", "postedAt": T}),
        case("prefixed code from Gmail", {"version": 1, "foundId": U2, "code": "G-482913", "service": "Google", "serviceKey": "google", "source": "email", "app": "gmail", "notificationId": "n1", "postedAt": T},
             {"foundId": U2, "code": "G-482913", "service": "Google", "serviceKey": "google", "source": "email", "app": "gmail", "notificationId": "n1", "postedAt": T}),
        case("code of 3 characters", {"version": 1, "foundId": U2, "code": "123", "service": "X", "serviceKey": "x", "source": "sms", "app": "messages", "notificationId": "n", "postedAt": T}, "reject"),
        case("code of 13 characters", {"version": 1, "foundId": U2, "code": "1234567890123", "service": "X", "serviceKey": "x", "source": "sms", "app": "messages", "notificationId": "n", "postedAt": T}, "reject"),
        case("unknown app", {"version": 1, "foundId": U2, "code": "482913", "service": "X", "serviceKey": "x", "source": "email", "app": "yahoo", "notificationId": "n", "postedAt": T}, "reject"),
    ],
    "codesCandidate": [
        case("a text message", {"version": 1, "candidateId": U, "source": "sms", "app": "messages", "sender": "AX-HDFCBK-S", "text": "OTP is 482913 for your login. Do not share.", "postedAt": T},
             {"candidateId": U, "source": "sms", "app": "messages", "sender": "AX-HDFCBK-S", "text": "OTP is 482913 for your login. Do not share.", "postedAt": T}),
        case("600 UTF-16 units of Hindi", {"version": 1, "candidateId": U, "source": "sms", "app": "messages", "sender": "Bank", "text": "\u0915" * 594 + " 48291", "postedAt": T},
             {"candidateId": U, "source": "sms", "app": "messages", "sender": "Bank", "text": "\u0915" * 594 + " 48291", "postedAt": T}),
        case("text of 601 UTF-16 units", {"version": 1, "candidateId": U, "source": "sms", "app": "messages", "sender": "Bank", "text": "x" * 595 + " 48291", "postedAt": T}, "reject"),
        case("empty text", {"version": 1, "candidateId": U, "source": "sms", "app": "messages", "sender": "Bank", "text": "", "postedAt": T}, "reject"),
        case("sender of 65 characters", {"version": 1, "candidateId": U, "source": "sms", "app": "messages", "sender": "s" * 65, "text": "OTP 482913", "postedAt": T}, "reject"),
        case("mail app with sms", {"version": 1, "candidateId": U, "source": "sms", "app": "gmail", "sender": "Bank", "text": "OTP 482913", "postedAt": T}, "reject"),
        case("candidateId not a UUID", {"version": 1, "candidateId": "c1", "source": "sms", "app": "messages", "sender": "Bank", "text": "OTP 482913", "postedAt": T}, "reject"),
        case("version 2", {"version": 2, "candidateId": U, "source": "sms", "app": "messages", "sender": "Bank", "text": "OTP 482913", "postedAt": T}, "reject"),
    ],
    "codesDetected": [
        case("found", {"version": 1, "candidateId": U, "outcome": "found", "code": "482913"}, {"candidateId": U, "outcome": "found", "code": "482913"}),
        case("none", {"version": 1, "candidateId": U, "outcome": "none"}, {"candidateId": U, "outcome": "none"}),
        case("failed with a reason", {"version": 1, "candidateId": U, "outcome": "failed", "reason": "model_missing"}, {"candidateId": U, "outcome": "failed", "reason": "model_missing"}),
        case("found without a code", {"version": 1, "candidateId": U, "outcome": "found"}, "reject"),
        case("code with a space", {"version": 1, "candidateId": U, "outcome": "found", "code": "482 913"}, "reject"),
        case("code of 13 characters", {"version": 1, "candidateId": U, "outcome": "found", "code": "1234567890123"}, "reject"),
        case("none with a code", {"version": 1, "candidateId": U, "outcome": "none", "code": "482913"}, "reject"),
        case("unknown outcome", {"version": 1, "candidateId": U, "outcome": "maybe"}, "reject"),
    ],
    "agentsGrantSet": [
        case("on for today", {"version": 1, "requestId": U, "deviceId": "agent-id", "key": "codes", "on": True, "window": "today"},
             {"requestId": U, "deviceId": "agent-id", "key": "codes", "on": True, "window": "today"}),
        case("off", {"version": 1, "requestId": U, "deviceId": "agent-id", "key": "codes", "on": False}, {"requestId": U, "deviceId": "agent-id", "key": "codes", "on": False}),
        case("on without a window", {"version": 1, "requestId": U, "deviceId": "agent-id", "key": "codes", "on": True}, "reject"),
        case("notifications cannot be granted", {"version": 1, "requestId": U, "deviceId": "agent-id", "key": "notifications", "on": True, "window": "1h"}, "reject"),
    ],
}

OUT.write_text(json.dumps(vectors, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"wrote {OUT}")
