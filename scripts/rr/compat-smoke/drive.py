#!/usr/bin/env python3
"""Small adb UI driver for the Bridgey compatibility smoke. Usage: drive.py <serial> <cmd> [args]."""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")


def adb(serial, *args, capture=True, timeout=60):
    return subprocess.run([ADB, "-s", serial, *args], stdin=subprocess.DEVNULL,
                          capture_output=capture, timeout=timeout)


def nodes(serial):
    for _ in range(3):
        adb(serial, "shell", "uiautomator", "dump", "/sdcard/ui.xml")
        out = adb(serial, "exec-out", "cat", "/sdcard/ui.xml").stdout.decode("utf-8", "replace")
        if "<hierarchy" in out:
            break
        time.sleep(1)
    else:
        return []
    root = ET.fromstring(out[out.index("<hierarchy"):])
    result = []
    for n in root.iter("node"):
        label = n.get("text") or n.get("content-desc") or ""
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        if label and m:
            x1, y1, x2, y2 = map(int, m.groups())
            result.append((label, (x1 + x2) // 2, (y1 + y2) // 2))
    return result


def boxes(serial):
    """Visible text nodes with their bounds: (label, x1, y1, x2, y2)."""
    adb(serial, "shell", "uiautomator", "dump", "/sdcard/ui.xml")
    out = adb(serial, "exec-out", "cat", "/sdcard/ui.xml").stdout.decode("utf-8", "replace")
    if "<hierarchy" not in out:
        return []
    root = ET.fromstring(out[out.index("<hierarchy"):])
    result = []
    for n in root.iter("node"):
        label = n.get("text") or ""
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        if label.strip() and m:
            result.append((label, *map(int, m.groups())))
    return result


def layout_problems(serial, w):
    """Text nodes that overlap each other or run off the screen (w: current screenshot width)."""
    items = boxes(serial)
    issues = []
    for label, x1, y1, x2, y2 in items:
        if x1 < 0 or x2 > w + 1:
            issues.append(f"off-screen x: '{label[:40]}' [{x1},{x2}] width {w}")
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            a, b = items[i], items[j]
            ix = min(a[3], b[3]) - max(a[1], b[1])
            iy = min(a[4], b[4]) - max(a[2], b[2])
            if ix <= 4 or iy <= 4:
                continue
            area = ix * iy
            small = min((a[3] - a[1]) * (a[4] - a[2]), (b[3] - b[1]) * (b[4] - b[2])) or 1
            contained = (a[1] <= b[1] and a[2] <= b[2] and a[3] >= b[3] and a[4] >= b[4]) or \
                        (b[1] <= a[1] and b[2] <= a[2] and b[3] >= a[3] and b[4] >= a[4])
            if area / small > 0.25 and not contained:
                issues.append(f"overlap: '{a[0][:30]}' / '{b[0][:30]}'")
    return issues


def find(serial, text, exact=True):
    for label, x, y in nodes(serial):
        if (label == text) if exact else (text.lower() in label.lower()):
            return x, y
    return None


def tap_text(serial, text, timeout=10, exact=True, scroll=True):
    deadline = time.time() + timeout
    swipes = 0
    while time.time() < deadline:
        pos = find(serial, text, exact)
        if pos:
            adb(serial, "shell", "input", "tap", str(pos[0]), str(pos[1]))
            time.sleep(1.2)
            return True
        if scroll and swipes < 6:
            swipe_up(serial)
            swipes += 1
        else:
            time.sleep(1)
    return False


def size(serial):
    out = adb(serial, "shell", "wm", "size").stdout.decode()
    w, h = re.findall(r"(\d+)x(\d+)", out)[-1]
    return int(w), int(h)


def swipe_up(serial):
    w, h = size(serial)
    adb(serial, "shell", "input", "swipe", str(w // 2), str(int(h * 0.75)), str(w // 2), str(int(h * 0.3)), "300")
    time.sleep(0.8)


def main():
    serial, cmd, *rest = sys.argv[1:]
    if cmd == "texts":
        for label, x, y in nodes(serial):
            print(f"{x},{y}\t{label}")
    elif cmd == "tap":
        ok = tap_text(serial, rest[0], exact=not (len(rest) > 1 and rest[1] == "contains"))
        print("tapped" if ok else "NOT FOUND", rest[0])
        sys.exit(0 if ok else 2)
    elif cmd == "shot":
        with open(rest[0], "wb") as f:
            f.write(adb(serial, "exec-out", "screencap", "-p").stdout)
    elif cmd == "swipe":
        swipe_up(serial)
    else:
        sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
