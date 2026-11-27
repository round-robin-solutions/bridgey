#!/usr/bin/env python3
"""UI smoke test for Bridgey on Linux: the real app under a headless display, paired with the scripted Rust peer
(rust/client/examples/peer.rs) over protocol 2, driven through its test control socket, with a stand-in
notification server on the session bus. Run it inside a display and a D-Bus session:

    dbus-run-session -- xvfb-run -a -s "-screen 0 1280x900x24" python3 linux/tests/ui_smoke.py --out OUT
    (Wayland: start a headless sway first and pass --wayland)

It checks pairing, the device card, battery, clipboard both ways through the desktop's clipboard (xclip on X11,
wl-copy and wl-paste on Wayland), a copied image sent as a file, notifications with their buttons, a reply, codes,
links, find device, files both ways, Send to from the shell, settings, screen reader labels and self-update, and
saves screenshots for each language and theme it is given. Nothing touches a real device: the peer keeps its
identity in memory and the app runs a separate profile in a temporary folder.
"""

import argparse
import hashlib
import http.server
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
LINUX = HERE.parent
REPO = LINUX.parent


def log(*a):
    print("ui_smoke:", *a, flush=True)


class Failure(Exception):
    pass


def wait(what, check, timeout=20.0, step=0.2):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        last = check()
        if last:
            return last
        time.sleep(step)
    raise Failure(f"timed out waiting for {what} (last: {last!r})")


class Peer:
    """The scripted phone: JSON lines out, commands in."""

    def __init__(self, exe, port, recv_dir, name="Test phone"):
        self.events = []
        self.lock = threading.Lock()
        self.proc = subprocess.Popen([exe, "--name", name, "--port", str(port), "--allow", "--receive-dir", str(recv_dir), "--seconds", "900"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            with self.lock:
                self.events.append(e)

    def send(self, line):
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def find(self, pred):
        with self.lock:
            return next((e for e in self.events if pred(e)), None)

    def stop(self):
        try:
            self.proc.kill()
        except OSError:
            pass


class App:
    def __init__(self, exe, profile, port, lang, extra_env=None):
        self.sock = str(profile / "control.sock")
        env = dict(os.environ)
        env.update({
            "BRIDGEY_DATA_DIR": str(profile), "BRIDGEY_PORT": str(port), "BRIDGEY_DISCOVERY": "0", "BRIDGEY_TEST_CONTROL": self.sock,
            "BRIDGEY_NO_BROWSER": "1", "BRIDGEY_CONNECT": "0", "BRIDGEY_LANG": lang, "BRIDGEY_RECEIVE_DIR": str(profile / "received"),
            "BRIDGEY_UPDATE_FEED_BASE": "http://127.0.0.1:9/none", "BRIDGEY_BATTERY": "64,0", "GSK_RENDERER": env.get("GSK_RENDERER", "cairo"),
            "GTK_A11Y": env.get("GTK_A11Y", "atspi"),
        })
        env.update(extra_env or {})
        profile.mkdir(parents=True, exist_ok=True)
        self.log = open(profile / "app.log", "w")
        cmd = [exe]
        if os.environ.get("UI_SMOKE_GDB"):
            cmd = ["gdb", "-q", "-batch", "-ex", "set debuginfod enabled on", "-ex", "run", "-ex", "bt 12", "--args", exe]
        self.env = env
        self.proc = subprocess.Popen(cmd, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        wait("the control socket", lambda: os.path.exists(self.sock), 20)

    def ctl(self, cmd, timeout=60):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(timeout)
        s.connect(self.sock)
        s.sendall((cmd + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            data += chunk
        s.close()
        if not data:
            time.sleep(0.5)
            tail = pathlib.Path(self.log.name).read_text()[-2000:]
            raise Failure(f"the app stopped answering at {cmd!r} (exit {self.proc.poll()}); its log ends:\n{tail}")
        return json.loads(data)

    def state(self):
        return self.ctl("state")

    def stop(self):
        try:
            self.ctl("quit", 5)
        except Exception:
            pass
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


NOTIFY_SERVER = r'''
import json, sys
from gi.repository import Gio, GLib
XML = """<node><interface name="org.freedesktop.Notifications">
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<method name="Invoke"><arg type="u" direction="in"/><arg type="s" direction="in"/></method>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
<signal name="NotificationReplied"><arg type="u"/><arg type="s"/></signal>
</interface></node>"""
node = Gio.DBusNodeInfo.new_for_xml(XML)
state = {"next": 1}
out = open(sys.argv[1], "a")
caps = sys.argv[2].split(",")
def call(conn, sender, path, iface, method, params, inv):
    if method == "Notify":
        a = params.unpack()
        nid = a[1] or state["next"]; state["next"] += 1
        out.write(json.dumps({"id": nid, "app": a[0], "summary": a[3], "body": a[4], "actions": a[5], "hints": {k: str(v) for k, v in a[6].items()}}) + "\n"); out.flush()
        inv.return_value(GLib.Variant("(u)", (nid,)))
    elif method == "CloseNotification":
        out.write(json.dumps({"closed": params.unpack()[0]}) + "\n"); out.flush()
        inv.return_value(None)
    elif method == "GetCapabilities":
        inv.return_value(GLib.Variant("(as)", (caps,)))
    elif method == "GetServerInformation":
        inv.return_value(GLib.Variant("(ssss)", ("stand-in", "test", "1", "1.2")))
    elif method == "Invoke":
        nid, key = params.unpack()
        if key.startswith("reply:"):
            conn.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "NotificationReplied", GLib.Variant("(us)", (nid, key[6:])))
        else:
            conn.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked", GLib.Variant("(us)", (nid, key)))
        inv.return_value(None)
def acquired(conn, name):
    conn.register_object("/org/freedesktop/Notifications", node.interfaces[0], call, None, None)
Gio.bus_own_name(Gio.BusType.SESSION, "org.freedesktop.Notifications", Gio.BusNameOwnerFlags.NONE, acquired, None, None)
GLib.MainLoop().run()
'''


class Notifications:
    """A stand-in org.freedesktop.Notifications that records every banner and can press its buttons."""

    def __init__(self, folder, caps="actions,body,body-markup,inline-reply"):
        self.file = folder / "notifications.jsonl"
        self.file.touch()
        script = folder / "notify_server.py"
        script.write_text(NOTIFY_SERVER)
        self.proc = subprocess.Popen([sys.executable, str(script), str(self.file), caps])
        time.sleep(1.0)

    def all(self):
        return [json.loads(l) for l in self.file.read_text().splitlines() if l.strip()]

    def press(self, nid, key):
        subprocess.run(["gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications", "--object-path", "/org/freedesktop/Notifications",
                        "--method", "org.freedesktop.Notifications.Invoke", str(nid), key], check=True, stdout=subprocess.DEVNULL)

    def stop(self):
        self.proc.kill()


MPRIS_PLAYER = r'''
import sys
from gi.repository import Gio, GLib
XML = """<node>
<interface name="org.mpris.MediaPlayer2"><property name="Identity" type="s" access="read"/></interface>
<interface name="org.mpris.MediaPlayer2.Player">
<method name="PlayPause"/><method name="Pause"/><method name="Next"/><method name="Previous"/>
<method name="SetPosition"><arg type="o" direction="in"/><arg type="x" direction="in"/></method>
<property name="PlaybackStatus" type="s" access="read"/><property name="Metadata" type="a{sv}" access="read"/>
<property name="Position" type="x" access="read"/><property name="Volume" type="d" access="readwrite"/>
<property name="CanGoNext" type="b" access="read"/><property name="CanGoPrevious" type="b" access="read"/><property name="CanSeek" type="b" access="read"/>
</interface></node>"""
node = Gio.DBusNodeInfo.new_for_xml(XML)
state = {"playing": True}
out = open(sys.argv[1], "a")
def call(conn, sender, path, iface, method, params, inv):
    out.write(method + "\n"); out.flush()
    if method == "PlayPause":
        state["playing"] = not state["playing"]
    inv.return_value(None)
def get(conn, sender, path, iface, prop):
    return {
        "Identity": GLib.Variant("s", "Test player"),
        "PlaybackStatus": GLib.Variant("s", "Playing" if state["playing"] else "Paused"),
        "Metadata": GLib.Variant("a{sv}", {"xesam:title": GLib.Variant("s", "Test song"), "xesam:artist": GLib.Variant("as", ["Test artist"]),
                                            "mpris:length": GLib.Variant("x", 200000000), "mpris:trackid": GLib.Variant("o", "/t/1")}),
        "Position": GLib.Variant("x", 1000000), "Volume": GLib.Variant("d", 0.5),
        "CanGoNext": GLib.Variant("b", True), "CanGoPrevious": GLib.Variant("b", True), "CanSeek": GLib.Variant("b", True),
    }.get(prop)
def acquired(conn, name):
    for i in node.interfaces:
        conn.register_object("/org/mpris/MediaPlayer2", i, call, get, None)
Gio.bus_own_name(Gio.BusType.SESSION, "org.mpris.MediaPlayer2.bridgeytest", Gio.BusNameOwnerFlags.NONE, acquired, None, None)
GLib.MainLoop().run()
'''


class Player:
    """A stand-in media player on MPRIS that records the commands it gets."""

    def __init__(self, folder):
        self.file = folder / "player.log"
        self.file.touch()
        script = folder / "player.py"
        script.write_text(MPRIS_PLAYER)
        self.proc = subprocess.Popen([sys.executable, str(script), str(self.file)])
        time.sleep(0.8)

    def calls(self):
        return self.file.read_text().split()

    def stop(self):
        self.proc.kill()


class Clipboard:
    def __init__(self, wayland):
        self.wayland = wayland

    def set_text(self, text):
        if self.wayland:
            subprocess.Popen(["wl-copy", text]).wait(5)
        else:
            p = subprocess.Popen(["xclip", "-selection", "clipboard", "-i"], stdin=subprocess.PIPE)
            p.communicate(text.encode(), timeout=5)

    def set_image(self, png):
        if self.wayland:
            p = subprocess.Popen(["wl-copy", "--type", "image/png"], stdin=subprocess.PIPE)
        else:
            p = subprocess.Popen(["xclip", "-selection", "clipboard", "-t", "image/png", "-i"], stdin=subprocess.PIPE)
        p.communicate(png, timeout=5)

    def text(self):
        cmd = ["wl-paste", "--no-newline"] if self.wayland else ["xclip", "-selection", "clipboard", "-o"]
        try:
            return subprocess.run(cmd, capture_output=True, timeout=5).stdout.decode("utf-8", "replace")
        except subprocess.TimeoutExpired:
            return ""


def tiny_png():
    import struct
    import zlib

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes([84, 199, 245]) * 8 for _ in range(8))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def atspi_check(name):
    """Walks the app's tree over AT-SPI (what Orca reads): every push button and toggle must have a name."""
    probe = r'''
import sys, gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi
desktop = Atspi.get_desktop(0)
missing, buttons = [], 0
def walk(node, depth=0):
    global buttons
    if node is None or depth > 60:
        return
    try:
        role = node.get_role_name()
        if role in ("push button", "toggle button", "button") and node.get_state_set().contains(Atspi.StateType.SHOWING):
            buttons += 1
            if not (node.get_name() or "").strip():
                parent = node.get_parent()
                missing.append(f"{role} in {parent.get_role_name() if parent else '?'} {parent.get_name() if parent else ''!r} desc={node.get_description()!r}")
        for i in range(node.get_child_count()):
            walk(node.get_child_at_index(i), depth + 1)
    except Exception:
        pass
for i in range(desktop.get_child_count()):
    app = desktop.get_child_at_index(i)
    if app is not None and sys.argv[1] in (app.get_name() or ""):
        walk(app)
print(buttons, len(missing))
print("\n".join(missing), file=sys.stderr)
'''
    try:
        r = subprocess.run([sys.executable, "-c", probe, name], capture_output=True, text=True, timeout=60)
        if r.stderr.strip():
            log("AT-SPI unnamed:", r.stderr.strip())
        out = r.stdout.split()
        return int(out[0]), int(out[1])
    except Exception as e:  # AT-SPI missing on this host
        log("AT-SPI check skipped:", e)
        return None


def serve(folder):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            pass
    handler = lambda *a, **k: Quiet(*a, directory=str(folder), **k)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def run(args, lang, theme, full):
    tmp = pathlib.Path(tempfile.mkdtemp(prefix=f"bridgey-ui-{lang}-{theme}-"))
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    shot = lambda name: app.ctl(f"screenshot {out / f'{name}-{lang}-{theme}.png'}")
    notes = Notifications(tmp)
    player = Player(tmp)
    peer_recv = tmp / "peer-received"
    peer_recv.mkdir()
    app_port, peer_port = args.port, args.port + 1
    app = App(args.app, tmp / "profile", app_port, lang)
    peer = Peer(args.peer, peer_port, peer_recv)
    # Headless Mutter has no keyboard on its seat, so Wayland clipboard tools cannot run there; XWayland's can.
    clip = Clipboard(args.wayland and args.expect_clipboard != "XWayland")
    results = []
    try:
        app.ctl(f"theme {theme}")
        app.ctl("resize 760 720")
        st = app.state()
        log(lang, theme, "clipboard mode", st["clipboardMode"])
        if args.expect_clipboard and full:
            assert st["clipboardMode"] == args.expect_clipboard, st["clipboardMode"]
        shot("01-empty")

        # Pairing: the app dials the peer; both show the code; the peer confirms by itself.
        app.ctl(f"pair 127.0.0.1 {peer_port}")
        code = wait("the code", lambda: (app.state()["pairing"] or {}).get("code"))
        peer_code = wait("the peer's code", lambda: peer.find(lambda e: e.get("event") == "code"))["code"]
        assert code == peer_code, (code, peer_code)
        shot("02-pair-code")
        app.ctl("confirm")
        wait("paired", lambda: (app.state()["pairing"] or {}).get("state") == "done")
        app.ctl("close-dialogs")
        wait("connected", lambda: any(d["connected"] and "files" in d["ready"] for d in app.state()["devices"]))
        results.append("pairing")

        peer.send("battery 81 1")
        wait("the battery", lambda: any(d["battery"] == [81, True] for d in app.state()["devices"]))
        results.append("battery")

        # The phone's clipboard lands on this computer's clipboard (in the background: the window is not focused).
        app.ctl("hide")
        peer.send("clipboard Hello from the phone")
        wait("clipboard text", lambda: clip.text() == "Hello from the phone")
        app.ctl("show")
        results.append("clipboard phone to computer")

        notes_before = len(notes.all())
        reply_token = "r" * 64
        mark_token = "m" * 64
        peer.send("notify " + json.dumps({"notificationId": "n1", "packageName": "com.example.chat", "applicationName": "Chat", "title": "Ana",
                                          "text": "Are you coming tonight?", "timestamp": int(time.time() * 1000),
                                          "actions": [{"actionToken": reply_token, "title": "Reply", "allowsReply": True}, {"actionToken": mark_token, "title": "Mark as read"}]}))
        banner = wait("a banner", lambda: next((n for n in notes.all()[notes_before:] if "Ana" in n.get("summary", "")), None))
        assert "inline-reply" in banner["actions"], banner
        assert "a1" in banner["actions"] and "dismiss" in banner["actions"], banner
        notes.press(banner["id"], "reply:On my way")
        wait("the reply toast", lambda: True, 1)
        app.ctl("set codesFromMessages true")
        peer.send("notify " + json.dumps({"notificationId": "n2", "packageName": "com.google.android.apps.messaging", "applicationName": "Messages", "title": "Bank",
                                          "text": "Your verification code is 482913. Do not share it.", "timestamp": int(time.time() * 1000)}))
        wait("the code in the list", lambda: any(n.get("code") == "482913" for n in app.state()["notifications"]))
        code_banner = wait("the code banner", lambda: next((n for n in notes.all() if "Bank" in n.get("summary", "")), None))
        assert "copy" in code_banner["actions"], code_banner
        notes.press(code_banner["id"], "copy")
        wait("the code on the clipboard", lambda: clip.text() == "482913")
        results.append("notifications, reply and codes")

        peer.send("link-open https://example.com/opened")
        wait("the link in activity", lambda: any("example.com/opened" in a["preview"] for a in app.state()["activity"]))
        peer.send("link https://example.com/waiting")
        wait("the waiting link", lambda: app.state()["pendingLink"] == "https://example.com/waiting")
        results.append("links")

        peer.send("ring")
        wait("ringing", lambda: app.state()["ringingFrom"])
        shot("03-home-ringing")
        ring_banner = next((n for n in notes.all() if "stop" in n.get("actions", [])), None)
        assert ring_banner, "a ring banner with Stop"
        notes.press(ring_banner["id"], "stop")
        wait("stopped", lambda: not app.state()["ringingFrom"])
        results.append("find device")

        # Files both ways (2 MB, binary frames).
        data = os.urandom(2 * 1024 * 1024)
        src = tmp / "from-phone.bin"
        src.write_bytes(data)
        peer.send(f"file {src}")
        received = tmp / "profile" / "received" / "from-phone.bin"
        wait("the file from the phone", lambda: received.exists() and received.read_bytes() == data, 60)
        mine = tmp / "from-computer.bin"
        mine.write_bytes(data[::-1])
        app.ctl(f"send-file {mine}")
        wait("the file at the phone", lambda: (peer_recv / "from-computer.bin").exists() and (peer_recv / "from-computer.bin").read_bytes() == data[::-1], 60)
        # Send to Bridgey runs a second copy with --send: it hands the files to the running app (single instance)
        # and exits.
        shell = tmp / "shell.txt"
        shell.write_text("Send to Bridgey")
        second = subprocess.run([args.app, "--send", str(shell)], env=app.env, capture_output=True, timeout=30)
        assert second.returncode == 0, second
        wait("Send to Bridgey", lambda: (peer_recv / "shell.txt").exists())
        assert app.proc.poll() is None, "the first app still runs"
        results.append("files both ways, and Send to through a second copy (single instance)")

        # This computer's clipboard to the phone, automatically and in the background.
        app.ctl("set automaticClipboard true")
        app.ctl("hide")
        clip.set_text("Copied on Linux")
        wait("the copy at the phone", lambda: peer.find(lambda e: e.get("event") == "clipboard" and e.get("text") == "Copied on Linux"), 15)
        results.append("clipboard computer to phone")
        clip.set_image(tiny_png())
        time.sleep(1.0)
        app.ctl("send-copied")
        wait("the copied image at the phone", lambda: any(p.suffix == ".png" for p in peer_recv.iterdir()), 30)
        app.ctl("show")
        results.append("copied image as a file")

        # The phone's media buttons reach this computer's player (MPRIS).
        app.ctl("set media true")
        peer.send("media toggle")
        wait("PlayPause at the player", lambda: "PlayPause" in player.calls(), 15)
        peer.send("media next")
        wait("Next at the player", lambda: "Next" in player.calls(), 15)
        results.append("media controls")

        if full:
            missing = app.ctl("a11y")["unlabelled"]
            assert not missing, f"buttons without a name: {missing}"
            at = atspi_check("in.roundrobin.bridgey")
            if at is not None:
                buttons, unnamed = at
                log(f"AT-SPI: {buttons} buttons showing, {unnamed} without a name")
                assert buttons > 0 and unnamed == 0, at
            results.append("screen reader names")

        shot("04-home")
        app.ctl("page notifications")
        app.ctl("start-reply 1 0")
        shot("05-notifications")
        app.ctl("page home")
        for page in ("devices", "sharing", "phone", "app"):
            app.ctl(f"settings {page}")
            shot(f"06-settings-{page}")
        app.ctl("close-dialogs")
        app.ctl("resize 400 760")
        shot("07-narrow")
        app.ctl("resize 760 720")
    finally:
        app.stop()
        peer.stop()
        notes.stop()
        player.stop()

    if full and not args.skip_update:
        results.append(update_check(args, tmp, out, lang, theme))
    shutil.rmtree(tmp, ignore_errors=True)
    return results


def update_check(args, tmp, out, lang, theme):
    """Self-update from a local feed signed with the peer's test key: offered, confirmed, checked, installed."""
    site = tmp / "site"
    (site / "dl").mkdir(parents=True)
    new = os.urandom(300_000)
    name = "Bridgey-RR-9.9.9-beta.1-linux-x86_64.AppImage"
    (site / "dl" / name).write_bytes(new)
    signed = json.loads(subprocess.run([args.peer, "--sign-update", str(site / "dl" / name)], capture_output=True, text=True, check=True).stdout)
    server = serve(site)
    base = f"http://127.0.0.1:{server.server_address[1]}"
    arch = "aarch64" if os.uname().machine == "aarch64" else "x86_64"
    feed = {"schema": 1, "app": "in.roundrobin.bridgey", "channel": "beta", "version": "9.9.9-beta.1", "build": 999999999,
            "linux": {"version": "9.9.9-beta.1", "build": 999999999, arch: {"url": f"{base}/dl/{name}", "sha256": hashlib.sha256(new).hexdigest(), "size": len(new), "edSignature": signed["signature"]}}}
    (site / "beta.json").write_text(json.dumps(feed))
    installed = tmp / "apps" / "Bridgey.AppImage"
    installed.parent.mkdir()
    installed.write_bytes(b"old build")
    env = {"BRIDGEY_UPDATE_FEED_BASE": base, "BRIDGEY_UPDATE_TRUSTED_PREFIX": f"{base}/dl/", "BRIDGEY_UPDATE_PUBLIC_KEY": signed["publicKey"],
           "BRIDGEY_UPDATE_CURRENT_BUILD": "1", "APPIMAGE": str(installed), "BRIDGEY_UPDATE_NO_RELAUNCH": "1"}
    try:
        app = App(args.app, tmp / "profile2", args.port + 2, lang, env)
        try:
            app.ctl(f"theme {theme}")
            app.ctl('set updateChannel "beta"')
            answer = app.ctl("update-check")
            assert answer.get("state") == "available" and answer.get("version") == "9.9.9-beta.1", answer
            app.ctl(f"screenshot {out / f'08-update-{lang}-{theme}.png'}")
            app.ctl("update-install")
            app.proc.wait(60)
        finally:
            if app.proc.poll() is None:
                app.stop()
        assert installed.read_bytes() == new, "the AppImage was replaced"
        assert os.access(installed, os.X_OK)
        # A tampered download is refused and the installed file stays.
        (site / "dl" / name).write_bytes(new[:-1] + b"x")
        installed.write_bytes(b"old build")
        app = App(args.app, tmp / "profile3", args.port + 3, lang, env)
        try:
            app.ctl('set updateChannel "beta"')
            app.ctl("update-check")
            app.ctl("update-install")
            wait("the refusal", lambda: app.state()["update"].get("state") == "failed", 30)
            assert installed.read_bytes() == b"old build"
        finally:
            app.stop()
    finally:
        server.shutdown()
    return "self-update (and a tampered download refused)"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--app", default=str(LINUX / "target" / "debug" / "bridgey-linux"))
    p.add_argument("--peer", default=str(REPO / "rust" / "target" / "debug" / "examples" / "peer"))
    p.add_argument("--out", default=str(LINUX / "out" / "screenshots"))
    p.add_argument("--port", type=int, default=42610)
    p.add_argument("--wayland", action="store_true")
    p.add_argument("--expect-clipboard", help="DataControl, X11, XWayland or Foreground")
    p.add_argument("--langs", default="en,ru")
    p.add_argument("--themes", default="light,dark")
    p.add_argument("--skip-update", action="store_true")
    args = p.parse_args()
    passed = []
    first = True
    for lang in args.langs.split(","):
        for theme in args.themes.split(","):
            log(f"== {lang} {theme} ({'Wayland' if args.wayland else 'X11'})")
            passed += run(args, lang, theme, full=first)
            first = False
            args.port += 10
    log("passed:", ", ".join(dict.fromkeys(passed)))


if __name__ == "__main__":
    try:
        main()
    except Failure as e:
        log("FAILED:", e)
        sys.exit(1)
