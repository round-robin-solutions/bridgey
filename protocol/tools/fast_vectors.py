#!/usr/bin/env python3
"""Writes protocol/test-vectors/files-fast-v1.json: binary frames and speed.* payloads (draft files_fast_draft1).

Android (FastTransferVectorsTest) and macOS (FastTransferVectorsTests) decode every vector and must get the same
result; vectors with "write": true are also written byte for byte by both platforms from the expected fields and the
fixed nonce. Needs the Python cryptography package (AES-GCM with a fixed nonce). Edit here, then run it.
"""
import base64
import json
import pathlib
import struct

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

OUT = pathlib.Path(__file__).resolve().parents[1] / "test-vectors" / "files-fast-v1.json"
KEY = bytes(range(32))
OTHER_KEY = bytes(range(1, 33))
NONCE = bytes.fromhex("0f0e0d0c0b0a090807060504")
T = "6d1f2c3b-4a59-4687-9a1b-2c3d4e5f6a7b"
MARKER = 0xB1
LABEL = "bridgey-fast-frame-v2"
SENDER = "7e57d00d-0000-4000-8000-0000000000aa"
RECEIVER = "7e57d00d-0000-4000-8000-0000000000bb"
b64 = lambda b: base64.b64encode(b).decode()


def length_prefixed(fields):
    """As SessionSecurity.lengthPrefixed: a 4-byte big-endian length and the UTF-8 bytes of each field."""
    out = b""
    for field in fields:
        data = field.encode()
        out += struct.pack(">I", len(data)) + data
    return out


def aad(sender, kind, ident, sequence):
    return length_prefixed([LABEL, sender, str(kind), ident.decode(), str(sequence)])


def body(kind, ident, sequence, plaintext, key=KEY, nonce=NONCE, aad_kind=None, aad_sequence=None, sender=SENDER):
    ident = ident.encode() if isinstance(ident, str) else ident
    sealed = AESGCM(key).encrypt(nonce, plaintext, aad(sender, kind if aad_kind is None else aad_kind, ident,
                                                       sequence if aad_sequence is None else aad_sequence))
    return bytes([len(ident)]) + ident + struct.pack(">Q", sequence) + nonce + sealed


def frame(kind, payload, length=None):
    return bytes([MARKER, kind]) + struct.pack(">I", len(payload) if length is None else length) + payload


frames = []


def v(name, data, expect, write=False, **extra):
    vector = {"name": name, "frameBase64": b64(data), "expect": expect}
    if write:
        vector["write"] = True
        vector["nonceBase64"] = b64(NONCE)
    vector.update(extra)
    frames.append(vector)


def ok(kind, ident, sequence, plaintext):
    return {"kind": kind, "id": ident, "sequence": sequence, "plaintextBase64": b64(plaintext)}


small = b"Bridgey fast transfers"
v("a file chunk", frame(1, body(1, T, 0, small)), ok(1, T, 0, small), write=True)
v("a later chunk", frame(1, body(1, T, 41, small)), ok(1, T, 41, small), write=True)
v("speed test bytes", frame(2, body(2, T, 7, bytes(64))), ok(2, T, 7, bytes(64)), write=True)
v("the largest sequence", frame(1, body(1, T, 9007199254740991, b"x")), ok(1, T, 9007199254740991, b"x"), write=True)
v("an uppercase transfer ID stays as sent", frame(1, body(1, T.upper(), 0, small)), ok(1, T.upper(), 0, small), write=True)
v("a one-byte ID", frame(1, body(1, "a", 0, small)), ok(1, "a", 0, small), write=True)
v("a 64-byte ID", frame(1, body(1, "i" * 64, 0, small)), ok(1, "i" * 64, 0, small), write=True)
mid = bytes((i * 7) & 0xFF for i in range(4096))
v("a 4 KiB chunk", frame(1, body(1, T, 3, mid)), ok(1, T, 3, mid), write=True)
v("an unknown kind is skipped", frame(9, body(9, T, 0, small)), "skip")
v("an unknown kind with a bad tag is dropped and counted", frame(9, body(9, T, 0, small, key=OTHER_KEY)), "reject")
v("an unknown kind sealed as another kind", frame(9, body(9, T, 0, small, aad_kind=1)), "reject")
v("a tampered ciphertext", frame(1, body(1, T, 0, small)[:-17] + bytes([body(1, T, 0, small)[-17] ^ 1]) + body(1, T, 0, small)[-16:]), "reject")
v("a moved sequence (not what the tag covers)", frame(1, body(1, T, 5, small, aad_sequence=4)), "reject")
v("another kind's tag", frame(1, body(1, T, 0, small, aad_kind=2)), "reject")
v("the wrong key", frame(1, body(1, T, 0, small, key=OTHER_KEY)), "reject")
v("reflected: sealed by the receiving device itself", frame(1, body(1, T, 0, small, sender=RECEIVER)), "reject")
v("a sequence of 2^53", frame(1, body(1, T, 9007199254740992, small)), "reject")
v("an empty ID", frame(1, bytes([0]) + struct.pack(">Q", 0) + NONCE + AESGCM(KEY).encrypt(NONCE, small, aad(SENDER, 1, b"", 0))), "reject")
v("a 65-byte ID", frame(1, body(1, "i" * 65, 0, small)), "reject")
v("an ID with a space", frame(1, body(1, "a b", 0, small)), "reject")
v("an ID with a control byte", frame(1, body(1, "a\x01b", 0, small)), "reject")
v("no ciphertext, only the tag", frame(1, bytes([len(T)]) + T.encode() + struct.pack(">Q", 0) + NONCE + bytes(16)), "reject")
v("a body cut short", frame(1, bytes([len(T)]) + T.encode() + struct.pack(">Q", 0)), "reject")
# Large frames as a head plus zero bytes ('zeroPadTo': the whole frame's length), so the file stays small.
head = bytes([1]) + b"t" + struct.pack(">Q", 0) + NONCE
over_body = 1 + 1 + 8 + 12 + 1048577 + 16
frames.append({"name": "ciphertext for 1 MiB plus one byte", "frameBase64": b64(frame(1, head, length=over_body)), "zeroPadTo": 6 + over_body, "expect": "reject"})
v("a declared length over the limit", frame(1, b"", length=1048678), "reject")
v("a declared length of zero", frame(1, b"", length=0), "reject")

speed = []


def sp(name, kind, plaintext, expect, raw=False):
    speed.append({"name": name, "kind": kind, ("plaintextString" if raw else "plaintext"): plaintext, "expect": expect})


link_mac = {"platform": "macos", "network": "wifi", "band": "5", "linkMbps": 1201, "standard": 6, "widthMhz": 80}
link_phone = {"platform": "android", "network": "wifi", "band": "5", "linkMbps": 2402, "standard": 6, "lockHeld": True, "screenOn": False}
full = lambda link: {"platform": link["platform"], "network": link["network"], "band": link.get("band"), "linkMbps": link.get("linkMbps"),
                     "standard": link.get("standard"), "widthMhz": link.get("widthMhz"), "lockHeld": link.get("lockHeld"), "screenOn": link.get("screenOn")}
sp("start from a Mac", "speed.start", {"version": 1, "testId": T, "seconds": 7, "link": link_mac},
   {"testId": T, "seconds": 7, "link": full(link_mac)})
sp("start with an uppercase test ID reads lowercased", "speed.start", {"version": 1, "testId": T.upper(), "seconds": 2, "link": link_phone},
   {"testId": T, "seconds": 2, "link": full(link_phone)})
sp("start at 15 seconds", "speed.start", {"version": 1, "testId": T, "seconds": 15, "link": {"platform": "android", "network": "hotspot"}},
   {"testId": T, "seconds": 15, "link": full({"platform": "android", "network": "hotspot"})})
sp("start with unknown link fields and an unknown band", "speed.start",
   {"version": 1, "testId": T, "seconds": 7, "link": {"platform": "macos", "network": "ethernet", "band": "60", "ssid": "x", "linkMbps": 0}},
   {"testId": T, "seconds": 7, "link": full({"platform": "macos", "network": "ethernet"})})
sp("start at 16 seconds", "speed.start", {"version": 1, "testId": T, "seconds": 16, "link": link_mac}, "reject")
sp("start at 1 second", "speed.start", {"version": 1, "testId": T, "seconds": 1, "link": link_mac}, "reject")
sp("start without a link", "speed.start", {"version": 1, "testId": T, "seconds": 7}, "reject")
sp("start with an unknown network", "speed.start", {"version": 1, "testId": T, "seconds": 7, "link": {"platform": "macos", "network": "5g"}}, "reject")
sp("start with a test ID that is not a UUID", "speed.start", {"version": 1, "testId": "test-1", "seconds": 7, "link": link_mac}, "reject")
sp("start version 2", "speed.start", {"version": 2, "testId": T, "seconds": 7, "link": link_mac}, "reject")
sp("start over 1 KiB", "speed.start", '{"version":1,"testId":"%s","seconds":7,"link":{"platform":"macos","network":"wifi"},"pad":"%s"}' % (T, "a" * 980), "reject", raw=True)
sp("ready", "speed.ready", {"version": 1, "testId": T, "status": "ready", "link": link_phone}, {"testId": T, "status": "ready", "link": full(link_phone)})
sp("busy, without a link", "speed.ready", {"version": 1, "testId": T, "status": "busy"}, {"testId": T, "status": "busy", "link": None})
sp("disabled", "speed.ready", {"version": 1, "testId": T, "status": "disabled"}, {"testId": T, "status": "disabled", "link": None})
sp("an unknown status", "speed.ready", {"version": 1, "testId": T, "status": "maybe"}, "reject")
sp("turn", "speed.turn", {"version": 1, "testId": T, "bytesPerSecond": 41234567}, {"testId": T, "bytesPerSecond": 41234567})
sp("turn at zero", "speed.turn", {"version": 1, "testId": T, "bytesPerSecond": 0}, {"testId": T, "bytesPerSecond": 0})
sp("turn with a negative rate", "speed.turn", {"version": 1, "testId": T, "bytesPerSecond": -1}, "reject")
sp("turn with a fractional rate", "speed.turn", '{"version":1,"testId":"%s","bytesPerSecond":1.5}' % T, "reject", raw=True)
sp("turn over 10^12", "speed.turn", {"version": 1, "testId": T, "bytesPerSecond": 1000000000001}, "reject")
sp("done", "speed.done", {"version": 1, "testId": T, "bytesPerSecond": 38000000}, {"testId": T, "bytesPerSecond": 38000000})
sp("done without a rate", "speed.done", {"version": 1, "testId": T}, "reject")
sp("result", "speed.result", {"version": 1, "testId": T, "forwardBytesPerSecond": 41000000, "backBytesPerSecond": 38000000, "roundTripMs": 3.5, "loadedRoundTripMs": 31.2},
   {"testId": T, "forward": 41000000, "back": 38000000, "roundTripMs": 3.5, "loadedRoundTripMs": 31.2})
sp("result with only one direction", "speed.result", {"version": 1, "testId": T, "forwardBytesPerSecond": 41000000},
   {"testId": T, "forward": 41000000, "back": None, "roundTripMs": None, "loadedRoundTripMs": None})
sp("result with out-of-range round trips reads them as absent", "speed.result",
   {"version": 1, "testId": T, "forwardBytesPerSecond": 1, "roundTripMs": -1, "loadedRoundTripMs": 60001},
   {"testId": T, "forward": 1, "back": None, "roundTripMs": None, "loadedRoundTripMs": None})
sp("result where a round trip is a boolean reads it as absent", "speed.result",
   {"version": 1, "testId": T, "backBytesPerSecond": 2, "roundTripMs": True},
   {"testId": T, "forward": None, "back": 2, "roundTripMs": None, "loadedRoundTripMs": None})

verdicts = []
EFFICIENCY = (0.5, 0.75)


def half_up(x):
    return int(x + 0.5)


def expected(route, mac, phone):
    """The same rule as both apps: goodput is 50% to 75% of the transmit rate; through one router the hops share airtime.
    Returns (low, high, basis): basis "linkRates" from readable rates, "typical" (Wi-Fi 6 defaults) or "none"."""
    def rng(mbps):
        return half_up(mbps * EFFICIENCY[0] / 8), half_up(mbps * EFFICIENCY[1] / 8)
    if route == "sameRouter":
        a, b = mac.get("linkMbps"), phone.get("linkMbps")
        return (*rng(1 / (1 / a + 1 / b)), "linkRates") if a and b else (30, 45, "typical")
    if route == "macWired":
        return (*rng(phone["linkMbps"]), "linkRates") if phone.get("linkMbps") else (50, 75, "typical")
    if route == "hotspot":
        return (*rng(mac["linkMbps"]), "linkRates") if mac.get("linkMbps") else (50, 90, "typical")
    return (0, 0, "none")


def vd(name, mac, phone, best, route, as_expected, advice):
    low, high, basis = expected(route, mac, phone)
    verdicts.append({"name": name, "mac": mac, "phone": phone, "bestBytesPerSecond": best,
                     "expect": {"route": route, "basis": basis, "low": low, "high": high, "asExpected": as_expected, "advice": advice}})


wifi = lambda platform, mbps, band="5", **kw: {"platform": platform, "network": "wifi", "band": band, "linkMbps": mbps, **kw}
vd("same router, Wi-Fi 6 80 MHz both, as expected", wifi("macos", 1201), wifi("android", 1201), 40e6, "sameRouter", True, ["tryHotspot"])
vd("same router, 160 MHz both (what the work Mac and a OnePlus 11 can reach)", wifi("macos", 2268), wifi("android", 2402), 80e6,
   "sameRouter", True, ["tryHotspot"])
vd("same router, 160 MHz Mac, slow phone on 2.4 GHz", wifi("macos", 2268), wifi("android", 144, band="2.4"), 3e6, "sameRouter", False, ["phone24", "tryHotspot"])
vd("same router, rates unknown", {"platform": "macos", "network": "wifi"}, {"platform": "android", "network": "wifi"}, 10e6,
   "sameRouter", False, ["weakLink", "tryHotspot"])
vd("same router, slow with the screen off", wifi("macos", 1201), wifi("android", 1201, screenOn=False, lockHeld=True), 5e6,
   "sameRouter", False, ["screenOff", "tryHotspot"])
vd("Mac on Ethernet", {"platform": "macos", "network": "ethernet"}, wifi("android", 1201), 60e6, "macWired", True, [])
vd("Mac on the phone's hotspot", wifi("macos", 1201), {"platform": "android", "network": "hotspot", "lockHeld": True, "screenOn": True}, 80e6,
   "hotspot", True, [])
vd("hotspot, Mac rate unknown", {"platform": "macos", "network": "wifi"}, {"platform": "android", "network": "hotspot"}, 20e6, "hotspot", False, ["weakLink"])
vd("loopback (the emulator)", {"platform": "macos", "network": "other"}, {"platform": "android", "network": "other"}, 200e6, "unknown", True, [])
vd("loopback (the emulator), slow: no estimate, so no verdict or advice", {"platform": "macos", "network": "other"},
   {"platform": "android", "network": "other"}, 5e6, "unknown", True, [])
vd("phone on Wi-Fi, Mac on another network (a VPN)", {"platform": "macos", "network": "other"}, wifi("android", 1201), 2e6, "unknown", True, [])

out = {
    "description": "Fast transfers (draft files_fast_draft1, docs/protocol.md 'Fast transfers' and 'Speed test'). The key is bytes 0 to 31, base64 in 'keyBase64'; "
                   "every frame is sent by 'senderDeviceId' and read by 'receiverDeviceId' (the associated data binds the sender). "
                   "fastFrame: 'frameBase64' is one whole binary frame, header included; expect is the decoded kind, id, sequence and plaintext, 'skip' (an unknown kind whose tag "
                   "verifies: dropped whole, the session stays) or 'reject' (a bad length closes the session; anything else is dropped and counted "
                   "like a frame with a bad envelope tag, 16 close the session). 'write': true means both platforms also produce exactly these bytes from the expected "
                   "fields with the nonce in 'nonceBase64'. 'zeroPadTo': N appends zero bytes until the frame is N bytes long. speedPayload: the JSON plaintext of a speed.* message of 'kind'; 'plaintext' is serialised by each platform's own "
                   "encoder, 'plaintextString' is used byte for byte; absent optional values are null in expect; test IDs compare lowercased. speedVerdict: the plain-words "
                   "verdict both apps show for the two links and the better direction's bytes a second; 'basis' says where the estimate comes from "
                   "('linkRates', 'typical' for Wi-Fi 6 when a rate is not readable, or 'none': no estimate, low and high 0).",
    "keyBase64": b64(KEY),
    "senderDeviceId": SENDER,
    "receiverDeviceId": RECEIVER,
    "fastFrame": frames,
    "speedPayload": speed,
    "speedVerdict": verdicts,
}
OUT.write_text(json.dumps(out, indent=1) + "\n")
print(len(frames), len(speed), len(verdicts))
