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
        # A link must not choose the trust level: an invite naming a Mac or a phone is refused in this version.
        {"name": "platform macos", "json": json.dumps({**invite_json, "p": "macos"})},
        {"name": "platform android", "json": json.dumps({**invite_json, "p": "android"})},
        {"name": "no platform", "json": json.dumps({k: v for k, v in invite_json.items() if k != "p"})},
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
        case("notification reads can be granted separately", {"version": 1, "requestId": U, "deviceId": "agent-id", "key": "notifications", "on": True, "window": "1h"},
             {"requestId": U, "deviceId": "agent-id", "key": "notifications", "on": True, "window": "1h"}),
    ],
}

# The other agent kinds (docs/protocol-v1.md, Gaps). 'write': true means the sender writes exactly that plaintext: the
# CLI for agentHello, agentGrantRequest, clipboardRequest, agentNotificationsQuery and codesCancel, the phone for
# agentRequestResult, notifyResult and agentNotificationsResult, and both for askRef. The receiver keeps expect, or
# drops a reject. Where a group above has no 'write', every case it accepts is what its sender writes.
M = "0d9c8b7a-6f5e-4d3c-2b1a-0f9e8d7c6b5a"


def w(name, plaintext, expect, **extra):
    return case(name, plaintext, expect, write=True, **extra)


agent_map = {key: on for key, on in [
    ("clipboard", True), ("files", True), ("notifications", False), ("battery", True), ("find_device", True), ("ping", True),
    ("links", False), ("media", False), ("calls", False), ("connect_draft1", True), ("agent_draft1", True),
    ("notify_draft1", True), ("ask_draft1", True), ("clipboard_request_draft1", True), ("agent_codes_draft1", True),
    ("codes_detect_draft1", False), ("agent_notifications_draft1", True), ("files_fast_draft1", True),
    ("files_resume_draft1", True),
]}

grants_all = ["files", "clipboard", "clipboard_request", "notify", "ask", "ring", "battery", "codes", "codes_detect", "notifications"]
notification = {"id": "0|com.example.ci|1|null|10123", "packageName": "com.example.ci", "applicationName": "RR CI", "title": "Nightly passed",
                "text": "bridgey 0.3.0\nall lanes green", "postedAt": T}
notification2 = {"id": "0|com.example.mail|4|null|10123", "packageName": "com.example.mail", "applicationName": "Mail", "title": "Rahul",
                 "text": "Lunch?", "postedAt": T - 60000}
vectors.update({
    "agentHello": [
        w("bridgey on Linux", {"version": 1, "platform": "cli", "app": "bridgey 0.3.0", "os": "linux x86_64"}, {"platform": "cli", "app": "bridgey 0.3.0", "os": "linux x86_64"}),
        w("bridgey on a Mac", {"version": 1, "platform": "cli", "app": "bridgey 0.3.0", "os": "macos aarch64"}, {"platform": "cli", "app": "bridgey 0.3.0", "os": "macos aarch64"}),
        case("control and bidi characters are removed", {"version": 1, "platform": "cli", "app": "bridgey\u0007 0.3.0", "os": "linux\u202e x86_64"},
             {"platform": "cli", "app": "bridgey 0.3.0", "os": "linux x86_64"}),
        case("unknown fields are ignored", {"version": 1, "platform": "cli", "app": "bridgey 0.3.0", "os": "linux x86_64", "future": 1},
             {"platform": "cli", "app": "bridgey 0.3.0", "os": "linux x86_64"}),
        case("app of 65 characters", {"version": 1, "platform": "cli", "app": "a" * 65, "os": "linux x86_64"}, "reject"),
        case("no platform", {"version": 1, "app": "bridgey 0.3.0", "os": "linux x86_64"}, "reject"),
        case("empty platform", {"version": 1, "platform": "", "app": "bridgey 0.3.0", "os": "linux x86_64"}, "reject"),
        case("no os", {"version": 1, "platform": "cli", "app": "bridgey 0.3.0"}, "reject"),
        case("version 2", {"version": 2, "platform": "cli", "app": "bridgey 0.3.0", "os": "linux x86_64"}, "reject"),
    ],
    "agentGrantRequest": [
        w("two grants with a note", {"version": 1, "requestId": U, "keys": ["codes", "notify"], "note": "For the nightly build"},
          {"requestId": U, "keys": ["codes", "notify"], "note": "For the nightly build"}),
        w("every grant", {"version": 1, "requestId": U, "keys": grants_all}, {"requestId": U, "keys": grants_all}),
        case("unknown names are skipped", {"version": 1, "requestId": U, "keys": ["codes", "teleport"]}, {"requestId": U, "keys": ["codes"]}),
        case("a name twice is kept once", {"version": 1, "requestId": U, "keys": ["codes", "codes"]}, {"requestId": U, "keys": ["codes"]}),
        case("no keys", {"version": 1, "requestId": U, "keys": []}, "reject"),
        case("11 keys", {"version": 1, "requestId": U, "keys": grants_all + ["codes"]}, "reject"),
        case("only unknown names", {"version": 1, "requestId": U, "keys": ["teleport"]}, "reject"),
        case("a key that is not a string", {"version": 1, "requestId": U, "keys": ["codes", 5]}, "reject"),
        case("note of 121 characters", {"version": 1, "requestId": U, "keys": ["codes"], "note": "n" * 121}, "reject"),
        case("requestId not a UUID", {"version": 1, "requestId": "r1", "keys": ["codes"]}, "reject"),
    ],
    "agentRequestResult": [
        w("ok", {"version": 1, "ref": M, "requestKind": "notify.post", "status": "ok"}, {"ref": M, "requestKind": "notify.post", "status": "ok"}),
        w("not granted names the grant", {"version": 1, "ref": M, "requestKind": "codes.query", "status": "not_granted", "grant": "codes"},
          {"ref": M, "requestKind": "codes.query", "status": "not_granted", "grant": "codes"}),
        w("rate limited says when to retry", {"version": 1, "ref": M, "requestKind": "ask.request", "status": "rate_limited", "retryAfterMs": 120000},
          {"ref": M, "requestKind": "ask.request", "status": "rate_limited", "retryAfterMs": 120000}),
        w("invalid", {"version": 1, "ref": M, "requestKind": "notify.post", "status": "invalid"}, {"ref": M, "requestKind": "notify.post", "status": "invalid"}),
        case("an unknown status is kept", {"version": 1, "ref": M, "requestKind": "notify.post", "status": "later"}, {"ref": M, "requestKind": "notify.post", "status": "later"}),
        case("no ref", {"version": 1, "requestKind": "notify.post", "status": "ok"}, "reject"),
        case("status not a string", {"version": 1, "ref": M, "requestKind": "notify.post", "status": 1}, "reject"),
        case("version 2", {"version": 2, "ref": M, "requestKind": "notify.post", "status": "ok"}, "reject"),
    ],
    "notifyResult": [
        w("posted", {"version": 1, "notifyId": U, "status": "posted"}, {"notifyId": U, "status": "posted"}),
        case("no notifyId", {"version": 1, "status": "posted"}, "reject"),
        case("notifyId not a UUID", {"version": 1, "notifyId": "n1", "status": "posted"}, "reject"),
        case("version 2", {"version": 2, "notifyId": U, "status": "posted"}, "reject"),
    ],
    # ask.posted, ask.dismissed, ask.expired and ask.cancelled from the phone, ask.cancel and ask.status from the agent.
    "askRef": [
        w("an ask", {"version": 1, "askId": U}, {"askId": U}),
        case("unknown fields are ignored", {"version": 1, "askId": U, "future": True}, {"askId": U}),
        case("askId not a UUID", {"version": 1, "askId": "a1"}, "reject"),
        case("no askId", {"version": 1}, "reject"),
        case("version 2", {"version": 2, "askId": U}, "reject"),
    ],
    "clipboardRequest": [
        w("two minutes", {"version": 1, "requestId": U, "expiresAt": T + 120000}, {"requestId": U, "expiresAt": T + 120000}, now=T),
        w("ten minutes, the longest", {"version": 1, "requestId": U, "expiresAt": T + 600000}, {"requestId": U, "expiresAt": T + 600000}, now=T),
        case("expiry now", {"version": 1, "requestId": U, "expiresAt": T}, "reject", now=T),
        case("over ten minutes ahead", {"version": 1, "requestId": U, "expiresAt": T + 600001}, "reject", now=T),
        case("expiresAt a string", {"version": 1, "requestId": U, "expiresAt": "soon"}, "reject", now=T),
        case("requestId not a UUID", {"version": 1, "requestId": "r1", "expiresAt": T + 120000}, "reject", now=T),
    ],
    "agentNotificationsQuery": [
        w("limit 5", {"version": 1, "queryId": U, "limit": 5}, {"queryId": U, "limit": 5}),
        w("limit 20", {"version": 1, "queryId": U, "limit": 20}, {"queryId": U, "limit": 20}),
        case("no limit reads as 20", {"version": 1, "queryId": U}, {"queryId": U, "limit": 20}),
        case("limit 0", {"version": 1, "queryId": U, "limit": 0}, "reject"),
        case("limit 21", {"version": 1, "queryId": U, "limit": 21}, "reject"),
        case("limit a string", {"version": 1, "queryId": U, "limit": "5"}, "reject"),
        case("queryId not a UUID", {"version": 1, "queryId": "q1", "limit": 5}, "reject"),
    ],
    # 'limit' is what the agent asked for; expect keeps the snapshot, or reject.
    "agentNotificationsResult": [
        w("two notifications", {"version": 1, "queryId": U, "status": "ok", "notifications": [notification, notification2], "truncated": False},
          {"queryId": U, "status": "ok", "notifications": [notification, notification2], "truncated": False}, limit=20),
        w("more on the phone than fit", {"version": 1, "queryId": U, "status": "ok", "notifications": [notification], "truncated": True},
          {"queryId": U, "status": "ok", "notifications": [notification], "truncated": True}, limit=1),
        w("none", {"version": 1, "queryId": U, "status": "ok", "notifications": [], "truncated": False},
          {"queryId": U, "status": "ok", "notifications": [], "truncated": False}, limit=20),
        w("unavailable", {"version": 1, "queryId": U, "status": "unavailable", "notifications": [], "truncated": False},
          {"queryId": U, "status": "unavailable", "notifications": [], "truncated": False}, limit=20),
        case("more than asked", {"version": 1, "queryId": U, "status": "ok", "notifications": [notification, notification2], "truncated": False}, "reject", limit=1),
        case("another query", {"version": 1, "queryId": U2, "status": "ok", "notifications": [], "truncated": False}, "reject", limit=20),
        case("text of 2,049 characters", {"version": 1, "queryId": U, "status": "ok", "notifications": [{**notification, "text": "t" * 2049}], "truncated": False}, "reject", limit=20),
        case("postedAt negative", {"version": 1, "queryId": U, "status": "ok", "notifications": [{**notification, "postedAt": -1}], "truncated": False}, "reject", limit=20),
        case("unknown status", {"version": 1, "queryId": U, "status": "later", "notifications": [], "truncated": False}, "reject", limit=20),
        case("truncated missing", {"version": 1, "queryId": U, "status": "ok", "notifications": []}, "reject", limit=20),
        case("version 2", {"version": 2, "queryId": U, "status": "ok", "notifications": [], "truncated": False}, "reject", limit=20),
    ],
    "codesCancel": [
        w("a held query", {"version": 1, "queryId": U}, {"queryId": U}),
        case("queryId not a UUID", {"version": 1, "queryId": "q1"}, "reject"),
        case("version 2", {"version": 2, "queryId": U}, "reject"),
    ],
    # The features.update an agent sends: what it can do. files_fast_draft1 is core in protocol v1, so an agent shows it
    # like every v1 device and its files go in binary frames; it also resumes files. rust/cli checks it advertises
    # exactly the newest case (codes_detect_draft1 is true only with a code model). The cases are frozen with agent
    # devices: when the map changes, add a case for the new map and keep the old ones, which older installs still send.
    "agentFeatures": [
        w("bridgey with binary frames and resume, no code model", {"version": 1, "features": agent_map}, agent_map),
    ],
})

OUT.write_text(json.dumps(vectors, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"wrote {OUT}")
