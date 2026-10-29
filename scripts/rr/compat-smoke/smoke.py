#!/usr/bin/env python3
"""Bridgey compatibility smoke on one booted emulator. Usage: smoke.py <serial> <outdir> <apk>."""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import drive  # noqa: E402

PKG = "in.roundrobin.bridgey"
ACT = PKG + "/dev.bridgey.android.MainActivity"
SECTIONS = ["Devices and permissions", "Clipboard", "Notifications", "Calls", "Files",
            "Media and quick actions", "Remote control", "Privacy", "Updates", "General", "About"]


def main():
    serial, out, apk = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    log = open(os.path.join(out, "steps.txt"), "w")
    problems = []
    n = [0]

    def a(*args, timeout=120):
        return drive.adb(serial, *args, timeout=timeout)

    def step(msg):
        print(msg, flush=True)
        log.write(msg + "\n")
        log.flush()

    layout = []

    def shot(name):
        n[0] += 1
        png = a("exec-out", "screencap", "-p").stdout
        with open(os.path.join(out, f"{n[0]:02d}-{name}.png"), "wb") as f:
            f.write(png)
        width = int.from_bytes(png[16:20], "big") if png[:4] == b"\x89PNG" else 10 ** 6
        for issue in drive.layout_problems(serial, width):
            layout.append(f"{n[0]:02d}-{name}: {issue}")

    def texts():
        return [t for t, _, _ in drive.nodes(serial)]

    def tap(text, required=True):
        ok = drive.tap_text(serial, text, timeout=12) or scroll_back_and_tap(text)
        step(("tap " if ok else "MISSING ") + text)
        if not ok and required:
            problems.append(f"could not find '{text}'")
        return ok

    def scroll_back_and_tap(text):
        w, h = drive.size(serial)
        for _ in range(8):
            a("shell", "input", "swipe", str(w // 2), str(int(h * 0.3)), str(w // 2), str(int(h * 0.75)), "300")
            time.sleep(0.6)
            pos = drive.find(serial, text)
            if pos:
                a("shell", "input", "tap", str(pos[0]), str(pos[1]))
                time.sleep(1.2)
                return True
        return False

    def back():
        a("shell", "input", "keyevent", "BACK")
        time.sleep(1.2)

    def rotate(landscape):
        a("shell", "settings", "put", "system", "accelerometer_rotation", "0")
        a("shell", "settings", "put", "system", "user_rotation", "1" if landscape else "0")
        time.sleep(2.5)

    def launch():
        a("shell", "am", "start", "-W", "-a", "android.intent.action.MAIN", "-c",
          "android.intent.category.LAUNCHER", "-n", ACT)
        time.sleep(3)

    sdk = a("shell", "getprop", "ro.build.version.sdk").stdout.decode().strip()
    step(f"API {sdk}")
    a("uninstall", PKG)
    r = a("install", "-r", apk, timeout=300)
    step("install: " + r.stdout.decode().strip().splitlines()[-1] if r.stdout else "install: ?")
    if r.returncode != 0:
        problems.append("install failed: " + r.stderr.decode()[-300:])
    a("logcat", "-c")
    a("logcat", "-b", "crash", "-c")
    rotate(False)
    launch()
    shot("welcome")
    tap("Get started quickly")
    for _ in range(8):
        t = texts()
        shot("setup")
        if "You're set" in t:
            break
        if "Pair later" in t:
            tap("Pair later")
        elif "Skip" in t:
            tap("Skip")
        elif "Next" in t:
            tap("Next")
        else:
            problems.append("setup stuck: " + " | ".join(t[:8]))
            break
    if "Start" in texts():
        tap("Start")
    shot("home")
    rotate(True)
    shot("home-landscape")
    rotate(False)
    tap("Settings")
    shot("settings")
    for s in SECTIONS:
        if tap(s):
            shot("page-" + s.split()[0].lower())
            drive.swipe_up(serial)
            shot("page-" + s.split()[0].lower() + "-more")
            if s == "Privacy":
                if tap("Permissions"):
                    shot("permissions")
                    drive.swipe_up(serial)
                    shot("permissions-more")
                    rotate(True)
                    shot("permissions-landscape")
                    t = texts()
                    if not any("Permission" in x for x in t):
                        problems.append("Permissions page lost after rotation")
                    rotate(False)
                    back()
            if s == "General":
                rotate(True)
                shot("general-landscape")
                rotate(False)
            back()
    # Kill and restore: leave the app on Settings > Privacy, kill the process in the background, relaunch.
    tap("Privacy")
    a("shell", "input", "keyevent", "HOME")
    time.sleep(2)
    # The connection service keeps the process alive, so `am kill` is a no-op; kill it as root
    # (google_apis images allow adb root), the way the low-memory killer would.
    old = a("shell", "pidof", PKG).stdout.decode().strip()
    a("root")
    time.sleep(3)
    a("wait-for-device")
    if old:
        a("shell", "kill", "-9", old)
    time.sleep(3)
    pid = a("shell", "pidof", PKG).stdout.decode().strip()
    step(f"process death: pid {old} -> '{pid}' (a new pid means the sticky service restarted)")
    if pid == old:
        problems.append("process was not killed")
    launch()
    t = texts()
    shot("restored")
    step("restored screen: " + " | ".join(t[:4]))
    restored = "Privacy" in t[:4] or any(x == "Privacy" for x in t[:3])
    if not restored:
        problems.append("state not restored after process death: " + " | ".join(t[:4]))
    svc = a("shell", "dumpsys", "activity", "services", PKG).stdout.decode()
    step("services: " + ", ".join(sorted({l.split()[-1].rstrip('}') for l in svc.splitlines() if 'ServiceRecord{' in l})))
    crash = a("logcat", "-d", "-b", "crash").stdout.decode("utf-8", "replace")
    main_log = a("logcat", "-d").stdout.decode("utf-8", "replace")
    with open(os.path.join(out, "crash.txt"), "w") as f:
        f.write(crash)
    fatal = [l for l in main_log.splitlines() if ("FATAL EXCEPTION" in l or "ANR in" in l or "Process: " + PKG in l)]
    bridgey_errors = [l for l in main_log.splitlines() if " E " in l and ("Bridgey" in l or PKG in l)]
    with open(os.path.join(out, "errors.txt"), "w") as f:
        f.write("\n".join(fatal + bridgey_errors))
    if PKG in crash or fatal:
        problems.append(f"crash or ANR in logcat ({len(fatal)} lines)")
    step(f"bridgey error lines: {len(bridgey_errors)}")
    rotate(False)
    a("unroot")
    with open(os.path.join(out, "layout.txt"), "w") as f:
        f.write("\n".join(layout))
    step(f"layout findings: {len(layout)} (see layout.txt)")
    step("RESULT " + ("PASS" if not problems else "ISSUES: " + "; ".join(problems)))


if __name__ == "__main__":
    main()
