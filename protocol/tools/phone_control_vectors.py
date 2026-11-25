#!/usr/bin/env python3
"""Writes protocol/test-vectors/phone-control-v1.json: the Mac controls the phone (phone_control_draft1, docs/protocol.md).

Edit here, then run it: python3 protocol/tools/phone_control_vectors.py. Android (PhoneControlVectorsTest) and the Mac
(PhoneControlVectorsTests) check every vector; the contract's own input packets, touch and navigate included, are in
rust/proto/test-vectors/screen-control-v1.json, which all three check.
"""
import json
import math
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "protocol" / "test-vectors" / "phone-control-v1.json"

STREAM = "0d3c2b1a-5948-4776-a5b4-c3d2e1f00a1b"
MAX = 9_007_199_254_740_991
INPUT_KEYS = ("pointer", "touch", "keys", "text", "navigation")


def inputs(**on):
    return {k: bool(on.get(k, False)) for k in INPUT_KEYS}


def caps(value):
    """The normalised form every decoder returns: all nine fields, both input objects with all five flags."""
    return {
        "v": 1,
        "screenSource": bool(value.get("screenSource", False)),
        "screenViewer": bool(value.get("screenViewer", False)),
        "fullDisplaySource": bool(value.get("fullDisplaySource", False)),
        "h264Encode": bool(value.get("h264Encode", False)),
        "h264Decode": bool(value.get("h264Decode", False)),
        "inputHost": inputs(**(value.get("inputHost") or {})),
        "inputController": inputs(**(value.get("inputController") or {})),
        "captureRequiresPrompt": bool(value.get("captureRequiresPrompt", False)),
        "captureRestoreSupported": bool(value.get("captureRestoreSupported", False)),
    }


def phone_caps(sdk):
    typing = sdk >= 33
    return caps({"screenSource": True, "fullDisplaySource": True, "h264Encode": True, "captureRequiresPrompt": True,
                 "inputHost": inputs(pointer=True, touch=True, navigation=True, keys=typing, text=typing)})


MAC_CAPS = caps({"screenViewer": True, "h264Decode": True,
                 "inputController": inputs(pointer=True, touch=True, keys=True, text=True, navigation=True)})

GEOMETRY = {"generation": 1, "source": 1, "kind": "display", "width": 720, "height": 1600}


def control(**changes):
    value = {"stream": 1, "transport": 3, "geometry": dict(GEOMETRY), "capabilities": phone_caps(36), "allowed": True}
    for key, val in changes.items():
        if val is None:
            value.pop(key, None)
        else:
            value[key] = val
    return value


def start(control_value, width=720, height=1600):
    value = {"version": 1, "streamId": STREAM, "sequence": 1, "requestId": "7e6d5c4b-3a29-4817-8695-a4b3c2d1e0f9",
             "codec": "h264", "width": width, "height": height, "fps": 30, "bitrate": 4_000_000}
    if control_value is not None:
        value["control"] = control_value
    return value


def control_expect(value):
    return {"stream": value["stream"], "transport": value["transport"], "geometry": value["geometry"],
            "capabilities": caps(value["capabilities"]), "allowed": value["allowed"]}


def stream_base(sequence, **fields):
    value = {"version": 1, "streamId": STREAM, "sequence": sequence}
    value.update(fields)
    return value


def negotiated(host, controller):
    if not (host["screenSource"] and host["fullDisplaySource"] and host["h264Encode"]
            and controller["screenViewer"] and controller["h264Decode"]):
        return None
    result = {k: host["inputHost"][k] and controller["inputController"][k] for k in INPUT_KEYS}
    return result if any(result.values()) else None


def mirror_rect(geometry, display):
    """Where Android mirrors the display inside the stream: aspect kept, centred, integer arithmetic as AOSP does."""
    w, h = geometry
    dw, dh = display
    if w * dh < h * dw:
        cw, ch = w, dh * w // dw
    else:
        cw, ch = dw * h // dh, h
    return (w - cw) // 2, (h - ch) // 2, cw, ch


def phone_point(geometry, display, x, y):
    if not (0 <= x <= 1 and 0 <= y <= 1):
        return "reject"
    w, h = geometry
    left, top, cw, ch = mirror_rect(geometry, display)
    px, py = math.floor(x * (w - 1) + 0.5), math.floor(y * (h - 1) + 0.5)
    point_x = min(max((px + 0.5 - left) * display[0] / cw, 0.0), display[0] - 1.0)
    point_y = min(max((py + 0.5 - top) * display[1] / ch, 0.0), display[1] - 1.0)
    return {"pixel": [px, py], "point": [point_x, point_y]}


def scroll_delta(geometry, display, dx, dy):
    _, _, cw, ch = mirror_rect(geometry, display)
    return [dx * display[0] / cw, dy * display[1] / ch]


def main():
    valid = control()
    vectors = {
        "format": "bridgey.phone-control.v1",
        "description": (
            "The Mac controls the phone (phone_control_draft1). startControl: the control object of screen.start as the "
            "Mac decodes it (null: view only; the start itself stays valid). phoneStream: screen.geometry and screen.control "
            "from the phone, decoded by the Mac; write: the phone writes exactly this plaintext. macStream: screen.control "
            "from the Mac, decoded by the phone; write: the Mac writes it. capabilities: what each side sends; negotiated: "
            "the input both may use. phonePoint: a contract position on the phone's display; scrollDelta: stream pixels "
            "to display pixels."
        ),
        "startControl": [
            {"name": "control allowed now", "plaintext": start(valid), "expect": control_expect(valid), "write": True},
            {"name": "service off", "plaintext": start(control(allowed=False)), "expect": control_expect(control(allowed=False)), "write": True},
            {"name": "Android 12: no typing", "plaintext": start(control(capabilities=phone_caps(31))),
             "expect": control_expect(control(capabilities=phone_caps(31))), "write": True},
            {"name": "landscape", "plaintext": start(control(geometry=dict(GEOMETRY, width=1600, height=720)), 1600, 720),
             "expect": control_expect(control(geometry=dict(GEOMETRY, width=1600, height=720)))},
            {"name": "unknown field ignored", "plaintext": start(control(future=True)), "expect": control_expect(valid)},
            {"name": "view only: no control", "plaintext": start(None), "expect": None},
            {"name": "view only: control null", "plaintext": start(None) | {"control": None}, "expect": None},
            {"name": "not an object", "plaintext": start(True), "expect": None},
            {"name": "stream 0", "plaintext": start(control(stream=0)), "expect": None},
            {"name": "transport over 2^53-1", "plaintext": start(control(transport=MAX + 1)), "expect": None},
            {"name": "transport a fraction", "plaintext": start(control(transport=1.5)), "expect": None},
            {"name": "no geometry", "plaintext": start(control(geometry=None)), "expect": None},
            {"name": "geometry generation 0", "plaintext": start(control(geometry=dict(GEOMETRY, generation=0))), "expect": None},
            {"name": "geometry of a window", "plaintext": start(control(geometry=dict(GEOMETRY, kind="window"))), "expect": None},
            {"name": "geometry with an unknown field", "plaintext": start(control(geometry=dict(GEOMETRY, scale=2))), "expect": None},
            {"name": "geometry not the stream size", "plaintext": start(control(geometry=dict(GEOMETRY, width=1080, height=2400))), "expect": None},
            {"name": "capabilities v2", "plaintext": start(control(capabilities=dict(phone_caps(36), v=2))), "expect": None},
            {"name": "no capabilities", "plaintext": start(control(capabilities=None)), "expect": None},
            {"name": "allowed missing", "plaintext": start(control(allowed=None)), "expect": None},
            {"name": "allowed not a boolean", "plaintext": start(control(allowed=1)), "expect": None},
        ],
        "phoneStream": [
            {"name": "geometry after rotation", "kind": "screen.geometry",
             "plaintext": stream_base(40, geometry=dict(GEOMETRY, generation=2, width=1600, height=720)),
             "expect": {"geometry": dict(GEOMETRY, generation=2, width=1600, height=720)}, "write": True},
            {"name": "geometry odd width", "kind": "screen.geometry",
             "plaintext": stream_base(41, geometry=dict(GEOMETRY, generation=2, width=721)), "expect": None},
            {"name": "geometry missing", "kind": "screen.geometry", "plaintext": stream_base(41), "expect": None},
            {"name": "waiting", "kind": "screen.control", "plaintext": stream_base(5, state="waiting"),
             "expect": {"state": "waiting"}, "write": True},
            {"name": "active", "kind": "screen.control",
             "plaintext": stream_base(6, state="active", session=1, input=inputs(pointer=True, touch=True, keys=True, text=True, navigation=True)),
             "expect": {"state": "active", "session": 1, "input": inputs(pointer=True, touch=True, keys=True, text=True, navigation=True)}, "write": True},
            {"name": "active without session", "kind": "screen.control",
             "plaintext": stream_base(6, state="active", input=inputs(touch=True)), "expect": None},
            {"name": "active with a non-boolean input flag", "kind": "screen.control",
             "plaintext": stream_base(6, state="active", session=1, input={"touch": 1}), "expect": None},
            {"name": "ended local stop", "kind": "screen.control", "plaintext": stream_base(7, state="ended", reason="local_stop"),
             "expect": {"state": "ended", "reason": "local_stop"}, "write": True},
            {"name": "refused declined", "kind": "screen.control", "plaintext": stream_base(7, state="refused", reason="declined"),
             "expect": {"state": "refused", "reason": "declined"}, "write": True},
            {"name": "refused permission", "kind": "screen.control", "plaintext": stream_base(7, state="refused", reason="permission"),
             "expect": {"state": "refused", "reason": "permission"}, "write": True},
            {"name": "ended with an unknown reason", "kind": "screen.control", "plaintext": stream_base(7, state="ended", reason="sunspots"),
             "expect": {"state": "ended", "reason": "failed"}},
            {"name": "ended without a reason", "kind": "screen.control", "plaintext": stream_base(7, state="ended"),
             "expect": {"state": "ended", "reason": "failed"}},
            {"name": "available", "kind": "screen.control", "plaintext": stream_base(8, state="available", allowed=True),
             "expect": {"state": "available", "allowed": True}, "write": True},
            {"name": "available without allowed", "kind": "screen.control", "plaintext": stream_base(8, state="available"), "expect": None},
            {"name": "unknown state", "kind": "screen.control", "plaintext": stream_base(8, state="paused"), "expect": None},
            {"name": "sequence 0", "kind": "screen.control", "plaintext": stream_base(0, state="waiting"), "expect": None},
            {"name": "version 2", "kind": "screen.control", "plaintext": stream_base(5, state="waiting") | {"version": 2}, "expect": None},
            {"name": "over 512 bytes", "kind": "screen.control", "plaintext": stream_base(5, state="waiting", pad="x" * 480), "expect": None},
        ],
        "macStream": [
            {"name": "begin", "plaintext": stream_base(3, action="begin", capabilities=MAC_CAPS),
             "expect": {"action": "begin", "capabilities": MAC_CAPS}, "write": True},
            {"name": "begin with sparse capabilities", "plaintext": stream_base(3, action="begin", capabilities={"v": 1, "screenViewer": True, "h264Decode": True, "inputController": {"touch": True}, "future": 1}),
             "expect": {"action": "begin", "capabilities": caps({"screenViewer": True, "h264Decode": True, "inputController": inputs(touch=True)})}},
            {"name": "begin without capabilities", "plaintext": stream_base(3, action="begin"), "expect": None},
            {"name": "begin with capabilities v2", "plaintext": stream_base(3, action="begin", capabilities=dict(MAC_CAPS, v=2)), "expect": None},
            {"name": "end", "plaintext": stream_base(9, action="end"), "expect": {"action": "end"}, "write": True},
            {"name": "unknown action", "plaintext": stream_base(3, action="take_over"), "expect": None},
            {"name": "no action", "plaintext": stream_base(3), "expect": None},
            {"name": "stream ID not a UUID", "plaintext": stream_base(3, action="begin") | {"streamId": "phone"}, "expect": None},
        ],
        "capabilities": [
            {"name": "phone, Android 8", "side": "phone", "sdk": 26, "expect": phone_caps(26)},
            {"name": "phone, Android 12L", "side": "phone", "sdk": 32, "expect": phone_caps(32)},
            {"name": "phone, Android 13", "side": "phone", "sdk": 33, "expect": phone_caps(33)},
            {"name": "phone, Android 16", "side": "phone", "sdk": 36, "expect": phone_caps(36)},
            {"name": "Mac", "side": "mac", "expect": MAC_CAPS},
        ],
        "negotiated": [
            {"name": "Android 16 and the Mac", "host": phone_caps(36), "controller": MAC_CAPS, "expect": negotiated(phone_caps(36), MAC_CAPS)},
            {"name": "Android 12 and the Mac: no typing", "host": phone_caps(31), "controller": MAC_CAPS, "expect": negotiated(phone_caps(31), MAC_CAPS)},
            {"name": "a viewer without touch or pointer", "host": phone_caps(36),
             "controller": caps({"screenViewer": True, "h264Decode": True, "inputController": inputs(navigation=True)}),
             "expect": negotiated(phone_caps(36), caps({"screenViewer": True, "h264Decode": True, "inputController": inputs(navigation=True)}))},
            {"name": "a host that is not a full-display source", "host": dict(phone_caps(36), fullDisplaySource=False), "controller": MAC_CAPS, "expect": None},
        ],
        "phonePoint": [
            {"name": "portrait centre", "geometry": [720, 1600], "display": [1080, 2400], "x": 0.5, "y": 0.5,
             "expect": phone_point((720, 1600), (1080, 2400), 0.5, 0.5)},
            {"name": "portrait top left", "geometry": [720, 1600], "display": [1080, 2400], "x": 0, "y": 0,
             "expect": phone_point((720, 1600), (1080, 2400), 0, 0)},
            {"name": "portrait bottom right", "geometry": [720, 1600], "display": [1080, 2400], "x": 1, "y": 1,
             "expect": phone_point((720, 1600), (1080, 2400), 1, 1)},
            {"name": "landscape, a third across", "geometry": [1600, 720], "display": [2400, 1080], "x": 1 / 3, "y": 0.75,
             "expect": phone_point((1600, 720), (2400, 1080), 1 / 3, 0.75)},
            {"name": "mirrored with bars top and bottom", "geometry": [736, 1600], "display": [1080, 2340], "x": 0.25, "y": 0.9,
             "expect": phone_point((736, 1600), (1080, 2340), 0.25, 0.9)},
            {"name": "on a bar: clamped to the display's edge", "geometry": [736, 1600], "display": [1080, 2340], "x": 0.5, "y": 0,
             "expect": phone_point((736, 1600), (1080, 2340), 0.5, 0)},
            {"name": "mirrored with bars left and right", "geometry": [1600, 736], "display": [2340, 1080], "x": 0.0, "y": 0.5,
             "expect": phone_point((1600, 736), (2340, 1080), 0.0, 0.5)},
            {"name": "outside", "geometry": [720, 1600], "display": [1080, 2400], "x": 1.01, "y": 0.5, "expect": "reject"},
            {"name": "negative", "geometry": [720, 1600], "display": [1080, 2400], "x": 0.5, "y": -0.001, "expect": "reject"},
        ],
        "scrollDelta": [
            {"name": "down a little", "geometry": [720, 1600], "display": [1080, 2400], "dx": 0, "dy": 40,
             "expect": scroll_delta((720, 1600), (1080, 2400), 0, 40)},
            {"name": "left, landscape", "geometry": [1600, 720], "display": [2400, 1080], "dx": -100, "dy": 0,
             "expect": scroll_delta((1600, 720), (2400, 1080), -100, 0)},
            {"name": "mirrored with bars", "geometry": [736, 1600], "display": [1080, 2340], "dx": 10, "dy": -10,
             "expect": scroll_delta((736, 1600), (1080, 2340), 10, -10)},
        ],
    }
    OUT.write_text(json.dumps(vectors, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
