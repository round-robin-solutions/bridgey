#!/usr/bin/env python3
"""Writes protocol/test-vectors/display-v1.json: Mac screen to phone (screen_control_draft1, docs/protocol.md).

Edit here, then run it: python3 protocol/tools/display_vectors.py. Android (DisplayVectorsTest) and the Mac
(DisplayVectorsTests) check every vector; rust/proto/test-vectors/screen-control-v1.json holds the contract's own
capabilities, geometry and input packets, which both also check.
"""
import hashlib
import hmac
import json
import math
import pathlib
import struct
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "protocol" / "test-vectors" / "display-v1.json"

REQUEST = "3f2e1d0c-4b5a-4968-8776-a5b4c3d2e1f0"
STREAM = "6c1b2a39-4857-4f6e-8d7c-0b1a29384756"
MAX = 9_007_199_254_740_991

CAPS_VIEWER = {"v": 1, "screenViewer": True, "h264Decode": True,
               "inputController": {"pointer": True, "keys": True, "text": True}}
CAPS_SOURCE = {"v": 1, "screenSource": True, "fullDisplaySource": True, "h264Encode": True, "captureRestoreSupported": True,
               "inputHost": {"pointer": True, "keys": True, "text": True}}


def caps(value):
    """The normalised form every decoder returns: all nine fields, both input objects with all five flags."""
    inputs = lambda o: {k: bool((o or {}).get(k, False)) for k in ("pointer", "touch", "keys", "text", "navigation")}
    return {
        "v": 1,
        "screenSource": bool(value.get("screenSource", False)),
        "screenViewer": bool(value.get("screenViewer", False)),
        "fullDisplaySource": bool(value.get("fullDisplaySource", False)),
        "h264Encode": bool(value.get("h264Encode", False)),
        "h264Decode": bool(value.get("h264Decode", False)),
        "inputHost": inputs(value.get("inputHost")),
        "inputController": inputs(value.get("inputController")),
        "captureRequiresPrompt": bool(value.get("captureRequiresPrompt", False)),
        "captureRestoreSupported": bool(value.get("captureRestoreSupported", False)),
    }


GEOMETRY = {"generation": 1, "source": 69734662, "kind": "display", "width": 1920, "height": 1246}


def connection(key: bytes, session_id: str):
    digest = hmac.new(key, b"bridgey-screen-control-connection-v1" + b"\x00" + session_id.encode("utf-8"), hashlib.sha256).digest()
    return list(digest[:16])


def pad_to(base: dict, size: int) -> str:
    """base as compact JSON with a "pad" string making it exactly size bytes."""
    text = json.dumps(dict(base, pad=""), separators=(",", ":"))
    return text.replace('"pad":""', '"pad":"' + "x" * (size - len(text)) + '"')


def start(**changes):
    value = {"version": 1, "streamId": STREAM, "sequence": 1, "requestId": REQUEST, "codec": "h264", "fps": 30,
             "bitrate": 4_000_000, "stream": 3, "transport": 2, "geometry": dict(GEOMETRY), "capabilities": dict(CAPS_SOURCE),
             "control": True, "displayName": "Built-in Retina Display"}
    for key, val in changes.items():
        if val is None:
            value.pop(key, None)
        else:
            value[key] = val
    return value


def start_expect(value):
    return {"streamId": value["streamId"].lower(), "sequence": value["sequence"], "requestId": value["requestId"].lower(),
            "fps": value["fps"], "bitrate": value["bitrate"], "stream": value["stream"], "transport": value["transport"],
            "geometry": value["geometry"], "capabilities": caps(value["capabilities"]), "control": value["control"],
            "displayName": value.get("displayName")}


def frame_hex(stream_id, sequence, frame, part, flags, capture, payload: bytes, version=1):
    header = struct.pack(">BBH16sQIq", version, flags, part, uuid.UUID(stream_id).bytes, sequence, frame, capture)
    return (header + payload).hex()


def capture_size(width, height):
    s = min(1.0, 1920 / max(width, height))
    side = lambda v: max(16, math.floor(v * s / 2) * 2)
    return [side(width), side(height)]


def letterbox(view, video, touch):
    k = min(view[0] / video[0], view[1] / video[1])
    w, h = video[0] * k, video[1] * k
    left, top = (view[0] - w) / 2, (view[1] - h) / 2
    x, y = (touch[0] - left) / w, (touch[1] - top) / h
    if not (0 <= x <= 1 and 0 <= y <= 1):
        return None
    return [x, y]


def mac_point(geometry, bounds, x, y):
    if not (0 <= x <= 1 and 0 <= y <= 1):
        return "reject"
    w, h = geometry
    px, py = math.floor(x * (w - 1) + 0.5), math.floor(y * (h - 1) + 0.5)
    return {"pixel": [px, py], "point": [bounds[0] + (px + 0.5) * bounds[2] / w, bounds[1] + (py + 0.5) * bounds[3] / h]}


def keyboard_eligible(display, window, displays):
    if displays <= 1:
        return True
    if window is None:
        return False
    cx, cy = window[0] + window[2] / 2, window[1] + window[3] / 2
    return display[0] <= cx < display[0] + display[2] and display[1] <= cy < display[1] + display[3]


def main():
    key = bytes(range(32))
    vectors = {
        "format": "bridgey.display.v1",
        "description": (
            "Mac screen to phone (screen_control_draft1). connection: the 16-byte contract nonce both sides derive "
            "from the session key and session ID. request and sourceStream: what the source (Mac) decodes; status, start "
            "and viewerStream: what the viewer (phone) decodes. Expected values are normalised: UUIDs lowercased, "
            "capabilities with every flag, absent optionals null, an unknown stop or control reason as failed. frame: "
            "display.frame plaintexts (the screen.frame layout) as the phone reads them. captureSize, letterbox, macPoint "
            "and keyboardEligible: the geometry rules (fractions compared to 1e-9). Edit protocol/tools/display_vectors.py, "
            "then run it."),
        "connection": [
            {"name": "key 00..1f", "keyHex": key.hex(), "sessionId": "8d6f0e2a-1b3c-4d5e-9f60-718293a4b5c6",
             "expect": connection(key, "8d6f0e2a-1b3c-4d5e-9f60-718293a4b5c6")},
            {"name": "another session ID, same key", "keyHex": key.hex(), "sessionId": "session-2",
             "expect": connection(key, "session-2")},
            {"name": "another key", "keyHex": bytes([0xA5] * 32).hex(), "sessionId": "8d6f0e2a-1b3c-4d5e-9f60-718293a4b5c6",
             "expect": connection(bytes([0xA5] * 32), "8d6f0e2a-1b3c-4d5e-9f60-718293a4b5c6")},
        ],
        "request": [
            {"name": "see the screen", "plaintext": {"version": 1, "requestId": REQUEST, "capabilities": CAPS_VIEWER},
             "expect": {"requestId": REQUEST, "capabilities": caps(CAPS_VIEWER)}},
            {"name": "upper-case request ID", "plaintext": {"version": 1, "requestId": REQUEST.upper(), "capabilities": CAPS_VIEWER},
             "expect": {"requestId": REQUEST, "capabilities": caps(CAPS_VIEWER)}},
            {"name": "unknown fields and capabilities are ignored",
             "plaintext": {"version": 1, "requestId": REQUEST, "future": 1, "capabilities": dict(CAPS_VIEWER, holograms=True)},
             "expect": {"requestId": REQUEST, "capabilities": caps(CAPS_VIEWER)}},
            {"name": "capabilities with no flags", "plaintext": {"version": 1, "requestId": REQUEST, "capabilities": {"v": 1}},
             "expect": {"requestId": REQUEST, "capabilities": caps({})}},
            {"name": "capabilities version 2", "plaintext": {"version": 1, "requestId": REQUEST, "capabilities": {"v": 2, "screenViewer": True}},
             "expect": "reject"},
            {"name": "capabilities without v", "plaintext": {"version": 1, "requestId": REQUEST, "capabilities": {"screenViewer": True}},
             "expect": "reject"},
            {"name": "a flag that is not a boolean", "plaintext": {"version": 1, "requestId": REQUEST, "capabilities": {"v": 1, "screenViewer": "yes"}},
             "expect": "reject"},
            {"name": "capabilities missing", "plaintext": {"version": 1, "requestId": REQUEST}, "expect": "reject"},
            {"name": "requestId not a UUID", "plaintext": {"version": 1, "requestId": "see-1", "capabilities": CAPS_VIEWER}, "expect": "reject"},
            {"name": "version 2", "plaintext": {"version": 2, "requestId": REQUEST, "capabilities": CAPS_VIEWER}, "expect": "reject"},
            {"name": "exactly 1,024 bytes", "plaintextString": pad_to({"version": 1, "requestId": REQUEST, "capabilities": {"v": 1}}, 1024),
             "expect": {"requestId": REQUEST, "capabilities": caps({})}},
            {"name": "over 1,024 bytes", "plaintextString": pad_to({"version": 1, "requestId": REQUEST, "capabilities": {"v": 1}}, 1025),
             "expect": "reject"},
            {"name": "lenient JSON", "plaintextString": "{version:1,requestId:'%s',capabilities:{v:1}}" % REQUEST, "expect": "reject"},
        ],
        "status": [
            *[{"name": status, "plaintext": {"version": 1, "requestId": REQUEST, "status": status},
               "expect": {"requestId": REQUEST, "status": status}}
              for status in ("waiting", "declined", "busy", "disabled", "permission", "locked", "failed")],
            {"name": "unknown status", "plaintext": {"version": 1, "requestId": REQUEST, "status": "maybe"}, "expect": "reject"},
            {"name": "status missing", "plaintext": {"version": 1, "requestId": REQUEST}, "expect": "reject"},
            {"name": "over 512 bytes", "plaintextString": pad_to({"version": 1, "requestId": REQUEST, "status": "waiting"}, 513), "expect": "reject"},
        ],
        "start": [],
        "viewerStream": [],
        "sourceStream": [],
        "frame": [],
        "captureSize": [],
        "letterbox": [],
        "macPoint": [],
        "keyboardEligible": [],
    }
    starts = [
        ("a stream with control", start()),
        ("view only, no display name", start(control=False, displayName=None)),
        ("upper-case IDs", start(streamId=STREAM.upper(), requestId=REQUEST.upper())),
        ("geometry at the largest counters", start(stream=MAX, transport=MAX, geometry=dict(GEOMETRY, generation=MAX, source=MAX))),
    ]
    for name, value in starts:
        vectors["start"].append({"name": name, "plaintext": value, "expect": start_expect(value)})
    rejects = [
        ("codec h265", start(codec="h265")),
        ("fps 0", start(fps=0)),
        ("fps 61", start(fps=61)),
        ("bitrate too low", start(bitrate=99_999)),
        ("stream 0", start(stream=0)),
        ("transport over 2^53-1", start(transport=MAX + 1)),
        ("geometry generation 0", start(geometry=dict(GEOMETRY, generation=0))),
        ("geometry of a window", start(geometry=dict(GEOMETRY, kind="window"))),
        ("geometry with an unknown field", start(geometry=dict(GEOMETRY, scale=2))),
        ("odd width", start(geometry=dict(GEOMETRY, width=1919))),
        ("width under 16", start(geometry=dict(GEOMETRY, width=14))),
        ("width over 32,768", start(geometry=dict(GEOMETRY, width=32_770))),
        ("over 67,108,864 pixels", start(geometry=dict(GEOMETRY, width=8_200, height=8_200))),
        ("capabilities version 2", start(capabilities={"v": 2})),
        ("control missing", start(control=None)),
        ("control not a boolean", start(control="yes")),
        ("display name over 64 bytes", start(displayName="D" * 65)),
        ("requestId missing", start(requestId=None)),
        ("sequence 0", start(sequence=0)),
    ]
    for name, value in rejects:
        vectors["start"].append({"name": name, "plaintext": value, "expect": "reject"})
    vectors["start"].append({"name": "over 2,048 bytes", "plaintextString": pad_to(start(), 2049), "expect": "reject"})
    vectors["start"].append({"name": "exactly 2,048 bytes", "plaintextString": pad_to(start(), 2048), "expect": start_expect(start())})

    base = {"version": 1, "streamId": STREAM, "sequence": 2}
    vs = vectors["viewerStream"]
    vs.append({"name": "stats", "kind": "display.stats",
               "plaintext": dict(base, latencyMs=28, rttMs=6, bitrate=4_000_000, sentBitrate=3_800_000, fps=30, dropped=0),
               "expect": {"streamId": STREAM, "sequence": 2, "latencyMs": 28, "rttMs": 6, "bitrate": 4_000_000, "sentBitrate": 3_800_000, "fps": 30, "dropped": 0}})
    vs.append({"name": "stats, fps over 120", "kind": "display.stats",
               "plaintext": dict(base, latencyMs=28, rttMs=6, bitrate=4_000_000, sentBitrate=3_800_000, fps=121, dropped=0), "expect": "reject"})
    vs.append({"name": "geometry, a new generation", "kind": "display.geometry",
               "plaintext": dict(base, geometry=dict(GEOMETRY, generation=2, width=1600, height=1000)),
               "expect": {"streamId": STREAM, "sequence": 2, "geometry": dict(GEOMETRY, generation=2, width=1600, height=1000)}})
    vs.append({"name": "geometry missing", "kind": "display.geometry", "plaintext": dict(base), "expect": "reject"})
    vs.append({"name": "geometry of a window", "kind": "display.geometry",
               "plaintext": dict(base, geometry=dict(GEOMETRY, generation=2, kind="window")), "expect": "reject"})
    vs.append({"name": "control active", "kind": "display.control",
               "plaintext": dict(base, state="active", session=1, input={"pointer": True, "keys": True, "text": True}),
               "expect": {"streamId": STREAM, "sequence": 2, "state": "active", "session": 1,
                          "input": {"pointer": True, "touch": False, "keys": True, "text": True, "navigation": False}, "reason": None}})
    vs.append({"name": "control active without a session", "kind": "display.control",
               "plaintext": dict(base, state="active", input={"pointer": True}), "expect": "reject"})
    vs.append({"name": "control active without input", "kind": "display.control",
               "plaintext": dict(base, state="active", session=1), "expect": "reject"})
    for state, reason, read in (("ended", "focus", "focus"), ("refused", "busy", "busy"), ("ended", "teleported", "failed"),
                                ("refused", None, "failed")):
        payload = dict(base, state=state)
        if reason:
            payload["reason"] = reason
        vs.append({"name": f"control {state}, reason {reason}", "kind": "display.control", "plaintext": payload,
                   "expect": {"streamId": STREAM, "sequence": 2, "state": state, "session": None, "input": None, "reason": read}})
    vs.append({"name": "control, unknown state", "kind": "display.control", "plaintext": dict(base, state="paused"), "expect": "reject"})
    vs.append({"name": "control from a viewer is not read by the viewer", "kind": "display.control",
               "plaintext": dict(base, action="begin"), "expect": "reject"})
    for reason, read in (("local_stop", "local_stop"), ("source_changed", "source_changed"), ("lost", "failed")):
        vs.append({"name": f"stop {reason}", "kind": "display.stop", "plaintext": dict(base, reason=reason),
                   "expect": {"streamId": STREAM, "sequence": 2, "reason": read}})
    vs.append({"name": "stop without a reason", "kind": "display.stop", "plaintext": dict(base),
               "expect": {"streamId": STREAM, "sequence": 2, "reason": "failed"}})
    vs.append({"name": "stop, sequence 0", "kind": "display.stop", "plaintext": dict(base, sequence=0, reason="user"), "expect": "reject"})
    vs.append({"name": "stop, stream ID not a UUID", "kind": "display.stop", "plaintext": dict(base, streamId="s1", reason="user"), "expect": "reject"})

    ss = vectors["sourceStream"]
    ss.append({"name": "started", "kind": "display.started", "plaintext": dict(base, sequence=1),
               "expect": {"streamId": STREAM, "sequence": 1}})
    ss.append({"name": "ack", "kind": "display.ack", "plaintext": dict(base, frame=12, decodeMs=3),
               "expect": {"streamId": STREAM, "sequence": 2, "frame": 12, "decodeMs": 3, "keyframe": False}})
    ss.append({"name": "ack asking for a key frame", "kind": "display.ack", "plaintext": dict(base, frame=13, decodeMs=0, keyframe=True),
               "expect": {"streamId": STREAM, "sequence": 2, "frame": 13, "decodeMs": 0, "keyframe": True}})
    ss.append({"name": "ack, frame 0", "kind": "display.ack", "plaintext": dict(base, frame=0, decodeMs=3), "expect": "reject"})
    ss.append({"name": "ack, frame over 2^32-1", "kind": "display.ack", "plaintext": dict(base, frame=4_294_967_296, decodeMs=3), "expect": "reject"})
    ss.append({"name": "ack, keyframe not a boolean", "kind": "display.ack", "plaintext": dict(base, frame=1, decodeMs=3, keyframe=1), "expect": "reject"})
    for action in ("begin", "end"):
        ss.append({"name": f"control {action}", "kind": "display.control", "plaintext": dict(base, action=action),
                   "expect": {"streamId": STREAM, "sequence": 2, "action": action}})
    ss.append({"name": "control, unknown action", "kind": "display.control", "plaintext": dict(base, action="take"), "expect": "reject"})
    ss.append({"name": "control from a source is not read by the source", "kind": "display.control",
               "plaintext": dict(base, state="active", session=1, input={}), "expect": "reject"})
    for reason, read in (("user", "user"), ("left_screen", "left_screen"), ("screen_off", "screen_off"), ("bored", "failed")):
        ss.append({"name": f"stop {reason}", "kind": "display.stop", "plaintext": dict(base, reason=reason),
                   "expect": {"streamId": STREAM, "sequence": 2, "reason": read}})
    ss.append({"name": "over 512 bytes", "kind": "display.ack", "plaintextString": pad_to(dict(base, frame=1, decodeMs=1), 513), "expect": "reject"})

    payload = bytes([0, 0, 0, 1, 0x67, 0x42, 0, 0x1F, 0, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65, 0x88, 0x84])
    fv = vectors["frame"]
    fv.append({"name": "a key frame in one part", "hex": frame_hex(STREAM, 3, 1, 0, 0b111, 123_456_789, payload),
               "expect": {"streamId": STREAM, "sequence": 3, "frame": 1, "part": 0, "key": True, "parameterSets": True, "last": True,
                          "captureMicros": 123_456_789, "payloadHex": payload.hex()}})
    fv.append({"name": "a middle part needs no start code", "hex": frame_hex(STREAM, 9, 2, 1, 0, 0, b"\x41\x9a\x02"),
               "expect": {"streamId": STREAM, "sequence": 9, "frame": 2, "part": 1, "key": False, "parameterSets": False, "last": False,
                          "captureMicros": 0, "payloadHex": "419a02"}})
    fv.append({"name": "version 2", "hex": frame_hex(STREAM, 3, 1, 0, 7, 1, payload, version=2), "expect": "reject"})
    fv.append({"name": "part 64", "hex": frame_hex(STREAM, 3, 1, 64, 7, 1, payload), "expect": "reject"})
    fv.append({"name": "frame 0", "hex": frame_hex(STREAM, 3, 0, 0, 7, 1, payload), "expect": "reject"})
    fv.append({"name": "sequence 0", "hex": frame_hex(STREAM, 0, 1, 0, 7, 1, payload), "expect": "reject"})
    fv.append({"name": "part 0 without a start code", "hex": frame_hex(STREAM, 3, 1, 0, 7, 1, b"\x67\x42"), "expect": "reject"})
    fv.append({"name": "header only", "hex": frame_hex(STREAM, 3, 1, 0, 7, 1, b""), "expect": "reject"})

    for name, native in (("Retina 14-inch (3024x1964)", (3024, 1964)), ("1080p external", (1920, 1080)),
                         ("5K (5120x2880)", (5120, 2880)), ("portrait 1440x2560", (1440, 2560)),
                         ("small 1280x800 kept", (1280, 800)), ("odd 1366x768", (1366, 768)), ("tiny 10x10", (10, 10))):
        vectors["captureSize"].append({"name": name, "native": list(native), "expect": capture_size(*native)})

    video = [1920, 1246]
    for name, view, touch in (
        ("portrait phone, centre", [1080, 2340], [540, 1170]),
        ("portrait phone, top edge of the picture", [1080, 2340], [0, (2340 - 1080 * 1246 / 1920) / 2]),
        ("portrait phone, on the top letterbox", [1080, 2340], [540, 100]),
        ("portrait phone, on the bottom letterbox", [1080, 2340], [540, 2300]),
        ("landscape phone (rotated), centre", [2340, 1080], [1170, 540]),
        ("landscape phone, on the left pillarbox", [2340, 1080], [20, 540]),
        ("landscape phone, bottom right corner", [2340, 1080], [1170 + 1080 * 1920 / 1246 / 2, 1080]),
        ("exact fit", [1920, 1246], [960, 623]),
    ):
        vectors["letterbox"].append({"name": name, "view": view, "video": video, "touch": touch,
                                     "expect": letterbox(view, video, touch)})

    for name, geometry, bounds, x, y in (
        ("Retina main display, centre", [1920, 1246], [0, 0, 1512, 982], 0.5, 0.5),
        ("Retina main display, top left", [1920, 1246], [0, 0, 1512, 982], 0.0, 0.0),
        ("Retina main display, bottom right", [1920, 1246], [0, 0, 1512, 982], 1.0, 1.0),
        ("external display to the left (negative origin)", [1920, 1080], [-1920, 0, 1920, 1080], 0.25, 0.75),
        ("external display above and left", [1920, 1080], [-2560, -1440, 2560, 1440], 1.0, 0.0),
        ("5K at 2x captured at 1920", [1920, 1080], [1512, -200, 2560, 1440], 0.5, 0.5),
        ("outside on x", [1920, 1080], [0, 0, 1920, 1080], 1.0000001, 0.5),
        ("negative y", [1920, 1080], [0, 0, 1920, 1080], 0.5, -0.1),
    ):
        vectors["macPoint"].append({"name": name, "geometry": {"width": geometry[0], "height": geometry[1]}, "bounds": bounds,
                                    "x": x, "y": y, "expect": mac_point(geometry, bounds, x, y)})

    display = [0, 0, 1512, 982]
    for name, window, displays in (
        ("one display, no focused window", None, 1),
        ("one display, a window anywhere", [3000, 0, 100, 100], 1),
        ("two displays, window on the shared one", [100, 100, 800, 600], 2),
        ("two displays, window on the other one", [-1800, 100, 800, 600], 2),
        ("two displays, window across, centre on the shared one", [-200, 100, 800, 600], 2),
        ("two displays, no focused window", None, 2),
    ):
        vectors["keyboardEligible"].append({"name": name, "display": display, "window": window, "displays": displays,
                                            "expect": keyboard_eligible(display, window, displays)})

    OUT.write_text(json.dumps(vectors, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
