#!/usr/bin/env python3
"""Starts the built AppImage (unpacked, as on a system without FUSE) in a separate profile, waits for its window and
saves a screenshot: the libraries, icons and fonts it carries load on this system.

    python3 linux/tests/appimage_smoke.py Bridgey-RR-<version>-linux-<arch>.AppImage screenshot.png
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time


def ctl(path, cmd):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(30)
    s.connect(path)
    s.sendall((cmd + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    return json.loads(data)


def main():
    image, shot = sys.argv[1], os.path.abspath(sys.argv[2])
    profile = tempfile.mkdtemp(prefix="bridgey-appimage-")
    sock = os.path.join(profile, "control.sock")
    env = dict(os.environ, APPIMAGE_EXTRACT_AND_RUN="1", BRIDGEY_DATA_DIR=profile, BRIDGEY_TEST_CONTROL=sock, BRIDGEY_PORT="42790",
               BRIDGEY_DISCOVERY="0", BRIDGEY_CONNECT="0", BRIDGEY_UPDATE_FEED_BASE="http://127.0.0.1:9/none", GSK_RENDERER="cairo")
    log = open(os.path.join(profile, "app.log"), "w")
    proc = subprocess.Popen([image], env=env, stdout=log, stderr=subprocess.STDOUT, cwd=profile)
    try:
        end = time.time() + 60
        while not os.path.exists(sock):
            if time.time() > end or proc.poll() is not None:
                log.flush()
                print(open(os.path.join(profile, "app.log")).read()[-3000:])
                raise SystemExit("appimage_smoke: the AppImage did not start")
            time.sleep(0.3)
        state = ctl(sock, "state")
        assert state["ok"] and state["status"], state
        os.makedirs(os.path.dirname(shot), exist_ok=True)
        assert ctl(sock, f"screenshot {shot}")["ok"]
        warnings = [l for l in open(os.path.join(profile, "app.log")) if "CRITICAL" in l or "Failed to load" in l or "icon" in l.lower() and "warning" in l.lower()]
        if warnings:
            print("appimage_smoke: warnings:\n" + "".join(warnings[:20]))
        print("appimage_smoke: the AppImage starts and draws its window:", shot)
        ctl(sock, "quit")
        proc.wait(10)
    finally:
        if proc.poll() is None:
            proc.kill()


if __name__ == "__main__":
    main()
