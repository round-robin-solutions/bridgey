#!/usr/bin/env python3
"""Cross-version acceptance between the apps themselves (docs/acceptance-1.0.md): an older build of one app paired with
the newer build of the other, both ways round, on a Mac that runs the Android emulator.

  python3 scripts/rr/accept-cross.py --mac-old OLD.app --mac-new NEW.app --apk-old OLD.apk --apk-new NEW.apk \\
      --peer STRESS_DRIVER --out DIR [--serial emulator-5554] [--cases old-android,old-mac]

Each case installs the stress build fresh on the emulator and makes a throwaway Mac test instance (its own bundle ID,
port, Bonjour type, preferences and private pasteboard; the synthetic screen, so macOS is never asked for anything).
The Mac pairs with the phone through the emulator's port redirect, then texts go both ways (each read back on the
other app) and files go both ways (SHA-256 at the receiving app). Then the older side is upgraded in place to the
newer build: the two must reconnect without pairing again and move texts and files once more. Everything both apps
made is removed at the end. Writes DIR/cross.json; exits 1 on any failure. Both apps are driven only through the
stress runners' control programs (stress-mac.sh and stress-android.sh `control`).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BID = "in.roundrobin.bridgey.test.cross"
MAC_PORT = 42499
SERVICE = "_bridgeycx._tcp"
FORWARD = 42496
MIB = 1 << 20


def props(key):
    for line in open(os.path.join(ROOT, "rr-edition.properties")):
        if line.startswith(key + "="):
            value = line.split("=", 1)[1].strip()
    return value


class Run:
    def __init__(self, args):
        self.args = args
        self.adb = shutil.which("adb") or os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
        self.app_id = props("EDITION_APP_ID") + ".stress"
        self.work = os.path.join(args.work, "cross")
        self.mac_app = os.path.join(self.work, "app", "Bridgey Cross.app")
        self.failures = []
        self.cases = []
        self.home = os.path.expanduser("~")

    # Control programs -------------------------------------------------------------------------------------------

    def env(self, new_app="", new_apk=""):
        env = dict(os.environ)
        env.update({"ANDROID_SERIAL": self.args.serial, "STRESS_APP_ID": self.app_id, "STRESS_ADB": self.adb, "STRESS_NEW_APK": new_apk,
                    "STRESS_APP": self.mac_app, "STRESS_RECV": os.path.join(self.work, "app-received"), "STRESS_APPSRC": os.path.join(self.work, "app-src"),
                    "STRESS_BIN": self.args.peer, "STRESS_NEW_APP": new_app, "STRESS_MAC_BID": BID, "STRESS_MAC_PORT": str(MAC_PORT),
                    "STRESS_MAC_SERVICE": SERVICE, "RR_ROOT": ROOT})
        return env

    def control(self, side, verb, *rest, new_app="", new_apk="", timeout=300):
        script = os.path.join(HERE, "stress-mac.sh" if side == "mac" else "stress-android.sh")
        out = subprocess.run(["sh", script, "control", verb, *rest], env=self.env(new_app, new_apk), capture_output=True, text=True, timeout=timeout)
        line = next((l for l in reversed(out.stdout.splitlines()) if l.strip().startswith("{")), "")
        try:
            value = json.loads(line)
        except ValueError:
            value = {"ok": False, "error": (out.stderr.strip().splitlines() or ["no answer"])[-1]}
        return value

    def adb_run(self, *a, check=False):
        return subprocess.run([self.adb, "-s", self.args.serial, *a], capture_output=True, text=True, stdin=subprocess.DEVNULL, check=check)

    def sha(self, size, seed):
        return subprocess.run([self.args.peer, "sha", str(size), str(seed)], capture_output=True, text=True, check=True).stdout.strip()

    # Set-up and clean-up ----------------------------------------------------------------------------------------

    def clean_mac(self):
        subprocess.run(["pkill", "-9", "-f", self.mac_app + "/Contents/MacOS/BridgeyMac"], capture_output=True)
        for service in (BID + ".trust", BID + ".identity"):
            while subprocess.run(["security", "delete-generic-password", "-s", service], capture_output=True).returncode == 0:
                pass
        subprocess.run(["defaults", "delete", BID], capture_output=True)
        lib = os.path.join(self.home, "Library")
        for path in (os.path.join(lib, "Application Support", BID), os.path.join(lib, "Caches", BID), os.path.join(lib, "Preferences", BID + ".plist"),
                     os.path.join(lib, "HTTPStorages", BID), os.path.join(lib, "Saved Application State", BID + ".savedState"),
                     "/tmp/%s-control" % BID, self.work):
            shutil.rmtree(path, ignore_errors=True) if os.path.isdir(path) else (os.path.exists(path) and os.remove(path))

    def clean_android(self):
        self.control("android", "clean")
        self.adb_run("uninstall", self.app_id)
        self.adb_run("emu", "redir", "del", "tcp:%d" % FORWARD)

    def setup(self, apk, mac_src):
        self.clean_mac()
        self.clean_android()
        for d in ("app-src", "app-received", "app"):
            os.makedirs(os.path.join(self.work, d), exist_ok=True)
        os.makedirs("/tmp/%s-control" % BID, exist_ok=True)
        self.adb_run("install", "-r", "-g", apk, check=True)
        real = props("EDITION_APP_ID")
        listed = self.adb_run("shell", "pm", "list", "packages", real).stdout
        for line in listed.splitlines():
            pkg = line.strip().replace("package:", "")
            if pkg and pkg != self.app_id:
                # Every Bridgey build listens on the same port in the device: stopped for the run, data untouched.
                self.adb_run("shell", "am", "force-stop", pkg)
        self.adb_run("emu", "redir", "del", "tcp:%d" % FORWARD)
        if "OK" not in self.adb_run("emu", "redir", "add", "tcp:%d:42458" % FORWARD).stdout:
            raise RuntimeError("the emulator would not redirect port %d" % FORWARD)
        env = self.env()
        subprocess.run(["sh", os.path.join(HERE, "stress-instance.sh"), mac_src, self.mac_app], env=env, check=True)
        for args in (["setup.completedVersion", "-int", "1"], ["settings.onboarding.completed", "-bool", "true"], ["SUEnableAutomaticChecks", "-bool", "false"],
                     ["settings.receiveFolderPath", os.path.join(self.work, "app-received")], ["settings.global.files", "-bool", "true"],
                     ["settings.global.clipboard", "-bool", "true"], ["settings.deviceName", "-string", "Cross Mac"]):
            subprocess.run(["defaults", "write", BID, *args], check=True)
        for side in ("android", "mac"):
            answer = self.control(side, "start")
            if not answer.get("ok"):
                raise RuntimeError("%s did not start: %s" % (side, answer))

    # Checks -----------------------------------------------------------------------------------------------------

    def wait(self, what, fn, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            value = fn()
            if value:
                return value
            time.sleep(1)
        return None

    def connected(self):
        android = self.control("android", "status")
        try:
            mac = json.load(open("/tmp/%s-control/status.json" % BID))
        except (OSError, ValueError):
            mac = {}
        return android.get("ok") and android.get("sessions", 0) >= 1 and len(mac.get("sessions", [])) >= 1

    def pair(self, case):
        t0 = time.time()
        if not self.control("android", "pair-prepare").get("ok"):
            return case["fail"]("Android would not allow pairing")
        self.control("mac", "pair-dial", "127.0.0.1:%d" % FORWARD)

        def done():
            self.control("android", "pair-confirm")
            return self.connected()
        if not self.wait("pairing", done, 90):
            return case["fail"]("the apps did not pair and connect in 90 s")
        case["metrics"]["pair_seconds"] = round(time.time() - t0, 1)
        self.control("android", "clipboard-on")

    def traffic(self, case, label):
        # Texts both ways, each read back on the receiving app.
        for i in range(2):
            text = "cross %s mac to phone %d %d" % (label, i, int(time.time() * 1000) % 100000)
            self.control("mac", "clip-send", text)
            got = self.wait("clip", lambda: (self.control("android", "clip-status").get("text") == text), 15)
            if not got:
                case["fail"]("%s: the phone did not get the Mac's text %r" % (label, text))
            text = "cross %s phone to mac %d %d" % (label, i, int(time.time() * 1000) % 100000)
            self.control("android", "clip-send", text)
            got = self.wait("clip", lambda: (self.control("mac", "clip-status").get("text") == text), 15)
            if not got:
                case["fail"]("%s: the Mac did not get the phone's text %r" % (label, text))
        # Files both ways, checked at the receiving app.
        for size in (3 * MIB + 1, 40 * MIB + 7):
            seed = (size * 7919 + len(label)) % (1 << 62)
            for direction in ("mac-to-phone", "phone-to-mac"):
                name = "stress-cross-%s-%s-%d.bin" % (label, direction, size)
                sender, receiver = ("mac", "android") if direction == "mac-to-phone" else ("android", "mac")
                t0 = time.time()
                sent = self.control(sender, "send", "%s:%d:%d" % (name, size, seed))
                if not sent.get("ok"):
                    case["fail"]("%s: %s could not send %s: %s" % (label, sender, name, sent))
                    continue
                expected = self.sha(size, seed)

                def arrived():
                    files = self.control(receiver, "received", name).get("files") or []
                    return files and not files[0].get("missing") and files[0].get("size") == size and files[0]
                got = self.wait("file", arrived, 180)
                if not got:
                    case["fail"]("%s: %s did not arrive whole on the %s" % (label, name, receiver))
                elif got.get("sha256") != expected:
                    case["fail"]("%s: %s arrived with SHA-256 %s, expected %s" % (label, name, got.get("sha256"), expected))
                else:
                    case["rounds"].append({"label": label, "direction": direction, "size": size, "seconds": round(time.time() - t0, 1)})
        self.control("android", "clean")
        self.control("mac", "clean")

    def run_case(self, name):
        a = self.args
        case = {"name": name, "ok": False, "failures": [], "metrics": {}, "rounds": []}
        case["fail"] = lambda msg: case["failures"].append(msg)
        apk, mac_src = (a.apk_old, a.mac_new) if name == "old-android" else (a.apk_new, a.mac_old)
        print("== %s: Android %s, Mac %s" % (name, os.path.basename(os.path.dirname(apk)) or apk, os.path.basename(os.path.dirname(mac_src)) or mac_src), flush=True)
        try:
            self.setup(apk, mac_src)
            case["metrics"]["android_before"] = self.adb_run("shell", "dumpsys", "package", self.app_id).stdout.split("versionName=")[1].split()[0]
            case["metrics"]["mac_before"] = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", self.mac_app + "/Contents/Info.plist"],
                                                           capture_output=True, text=True).stdout.strip()
            self.pair(case)
            if not case["failures"]:
                self.traffic(case, "paired")
                t0 = time.time()
                if name == "old-android":
                    up = self.control("android", "upgrade", new_apk=a.apk_new)
                else:
                    up = self.control("mac", "upgrade", new_app=a.mac_new)
                case["metrics"]["upgrade"] = up
                if not up.get("ok"):
                    case["fail"]("the upgrade failed: %s" % up)
                elif not self.wait("reconnect", self.connected, 120):
                    case["fail"]("the apps did not reconnect within 120 s of the upgrade")
                else:
                    case["metrics"]["reconnect_seconds"] = round(time.time() - t0, 1)
                    pairing = self.control("android", "snapshot", os.path.join(self.work, "android-after.json"))
                    trusted = json.load(open(os.path.join(self.work, "android-after.json"))).get("trusted", []) if pairing.get("ok") else []
                    case["metrics"]["android_trusted_after"] = len(trusted)
                    if len(trusted) != 1:
                        case["fail"]("the phone trusts %d devices after the upgrade, expected the one Mac" % len(trusted))
                    self.traffic(case, "upgraded")
        except Exception as e:  # noqa: BLE001 - one case's failure must not stop the clean-up
            case["fail"]("stopped: %s" % e)
        finally:
            if not a.keep:
                self.clean_mac()
                self.clean_android()
        del case["fail"]
        case["ok"] = not case["failures"]
        print("   %s %s" % ("ok" if case["ok"] else "FAILED", case["failures"]), flush=True)
        self.cases.append(case)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for k in ("--mac-old", "--mac-new", "--apk-old", "--apk-new", "--peer", "--out"):
        p.add_argument(k, required=True)
    p.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL", "emulator-5554"))
    p.add_argument("--cases", default="old-android,old-mac")
    p.add_argument("--work", default=os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "bridgey-accept-cross"))
    p.add_argument("--keep", action="store_true")
    args = p.parse_args()
    if not args.serial.startswith("emulator-"):
        sys.exit("cross-version runs install with every permission granted: an emulator only")
    os.makedirs(args.out, exist_ok=True)
    run = Run(args)
    started = time.time()
    for name in args.cases.split(","):
        run.run_case(name)
    doc = {"tool": "bridgey-accept-cross", "ok": all(c["ok"] for c in run.cases), "started": int(started), "finished": int(time.time()), "cases": run.cases}
    with open(os.path.join(args.out, "cross.json"), "w") as f:
        json.dump(doc, f, indent=1)
    print("cross: %s (%s)" % ("ok" if doc["ok"] else "FAILED", os.path.join(args.out, "cross.json")))
    return 0 if doc["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
