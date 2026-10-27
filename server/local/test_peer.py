#!/usr/bin/env python3
"""A headless Bridgey peer for Connect anywhere live tests (not shipped, not a product).

It speaks the real session protocol (pairing, the six-digit code, pinned identities, AES-GCM
payloads, features.update, connect.setup and connect.addresses, heartbeats) and runs the Connect
anywhere core (libbridgey_connect) through its C functions, so an app on a phone or an emulator can
pair with it over a TCP socket and then reach it through the relay. Because it is a test harness it
confirms the pairing code itself; the apps never do (SECURITY.md).

    python3 server/local/test_peer.py --lib rust/target/release/libbridgey_connect.so \\
        --state /tmp/peer.json --control ws://100.121.85.33:18450/v1/ws --relay-only \\
        [--dial 127.0.0.1:42470] [--seconds 300]

Needs the `cryptography` package. Prints one JSON line per event.
"""
import argparse
import base64
import ctypes
import hashlib
import hmac
import json
import os
import socket
import sys
import threading
import time
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

REQUIRED_FEATURES = ("clipboard", "files", "notifications", "battery", "find_device")
STARTED = time.monotonic()
LOCK = threading.Lock()


def log(event, **fields):
    with LOCK:
        print(json.dumps({"t": round(time.monotonic() - STARTED, 3), "event": event, **fields}), flush=True)


def b64(data):
    return base64.b64encode(data).decode()


def unb64(text):
    return base64.b64decode(text)


def public_raw(key):
    return key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def load_public(raw):
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw)


def hmac256(key, data):
    return hmac.new(key, data, hashlib.sha256).digest()


def hkdf(ikm, salt, info, length=32):
    prk = hmac256(salt or b"\0" * 32, ikm)
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac256(prk, block + info + bytes([counter]))
        out += block
        counter += 1
    return out[:length]


class State:
    """Identity, trusted devices and pair secrets, kept in a JSON file between runs."""

    def __init__(self, path, name, device_id):
        self.path = path
        if os.path.exists(path):
            data = json.load(open(path))
        else:
            data = {"deviceId": device_id, "name": name, "trusted": {}, "secrets": {}, "addresses": {},
                    "identity": ec.generate_private_key(ec.SECP256R1()).private_bytes(
                        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode(),
                    "node": ec.generate_private_key(ec.SECP256R1()).private_bytes(
                        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()}
        self.data = data
        self.identity = serialization.load_pem_private_key(data["identity"].encode(), None)
        self.node = serialization.load_pem_private_key(data["node"].encode(), None)
        self.save()

    @property
    def device_id(self):
        return self.data["deviceId"]

    def save(self):
        with open(self.path, "w") as f:
            json.dump(self.data, f)
        os.chmod(self.path, 0o600)


class Session:
    """One newline JSON session, over TCP or a tunnel's loopback bridge."""

    def __init__(self, peer, sock, initiated, tunnel=None):
        self.peer = peer
        self.sock = sock
        self.initiated = initiated
        self.tunnel = tunnel
        self.id = str(uuid.uuid4()) if initiated else ""
        self.eph = ec.generate_private_key(ec.SECP256R1())
        self.local_eph = b64(public_raw(self.eph))
        self.remote_eph = ""
        self.remote_id = ""
        self.remote_name = ""
        self.key = None
        self.local_confirmed = False
        self.remote_confirmed = False
        self.authenticated = False
        self.contribution = None
        self.send_lock = threading.Lock()

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()

    def send(self, message):
        line = json.dumps(message, separators=(",", ":")) + "\n"
        with self.send_lock:
            self.sock.sendall(line.encode())

    def send_encrypted(self, kind, payload):
        nonce = os.urandom(12)
        ciphertext = AESGCM(self.key).encrypt(nonce, json.dumps(payload, separators=(",", ":")).encode(), None)
        self.send({"kind": kind, "sessionId": self.id, "messageId": str(uuid.uuid4()), "nonce": b64(nonce), "ciphertext": b64(ciphertext)})

    def decrypt(self, message):
        return json.loads(AESGCM(self.key).decrypt(unb64(message["nonce"]), unb64(message["ciphertext"]), None))

    def transcript(self):
        local, remote = self.peer.state.device_id, self.remote_id
        if self.initiated:
            fields = [local, remote, self.local_eph, self.remote_eph]
        else:
            fields = [remote, local, self.remote_eph, self.local_eph]
        if self.tunnel:
            return "\0".join(["bridgey-auth-v2", self.id] + fields + [self.tunnel["exporter"]]).encode()
        return "\0".join(["bridgey-auth-v1", self.id] + fields).encode()

    def material(self):
        shared = self.eph.exchange(ec.ECDH(), load_public(unb64(self.remote_eph)))
        prk = hmac256(hashlib.sha256(self.id.encode()).digest(), shared)
        output = hmac256(prk, b"bridgey-pairing-v1\x01")
        code = str(int.from_bytes(output[:4], "big") % 1_000_000).zfill(6)
        return code, output

    def confirm(self):
        identity_key = b64(public_raw(self.peer.state.identity))
        proof = hmac256(self.key, f"bridgey-confirm-v1\0{self.id}\0{self.peer.state.device_id}\0{identity_key}".encode())
        signature = self.peer.state.identity.sign(self.transcript(), ec.ECDSA(hashes.SHA256()))
        self.local_confirmed = True
        self.send({"kind": "pairing.confirm", "sessionId": self.id, "deviceId": self.peer.state.device_id,
                   "identityKey": identity_key, "proof": b64(proof), "signature": b64(signature)})
        self.complete()

    def complete(self):
        if not (self.local_confirmed and self.remote_confirmed) or self.authenticated:
            return
        self.authenticated = True
        self.peer.authenticated(self)
        features = {key: True for key in REQUIRED_FEATURES}
        features["connect_draft1"] = True
        self.send_encrypted("features.update", {"version": 1, "features": features})

    def run(self):
        if self.initiated:
            offer = {"kind": "pairing.offer", "sessionId": self.id, "deviceId": self.peer.state.device_id,
                     "deviceName": self.peer.state.data["name"], "publicKey": self.local_eph}
            if self.tunnel and self.tunnel.get("peer"):
                offer["targetDeviceId"] = self.tunnel["peer"]
            self.send(offer)
        reader = self.sock.makefile("rb")
        reason = "closed"
        try:
            for raw in reader:
                self.receive(json.loads(raw))
        except Exception as error:  # a test harness: report and end the session
            reason = f"error: {error}"
        finally:
            try:
                self.sock.close()
            except OSError:
                pass
            self.peer.ended(self, reason)

    def receive(self, m):
        kind = m.get("kind")
        if kind == "pairing.offer" and not self.initiated:
            self.id, self.remote_id, self.remote_name, self.remote_eph = m["sessionId"], m["deviceId"], m.get("deviceName", ""), m["publicKey"]
            self.send({"kind": "pairing.answer", "sessionId": self.id, "deviceId": self.peer.state.device_id,
                       "deviceName": self.peer.state.data["name"], "publicKey": self.local_eph})
            self.agree()
        elif kind == "pairing.answer" and self.initiated:
            self.remote_id, self.remote_name, self.remote_eph = m["deviceId"], m.get("deviceName", ""), m["publicKey"]
            self.agree()
        elif kind == "pairing.confirm":
            identity_key = m["identityKey"]
            pinned = self.peer.state.data["trusted"].get(m["deviceId"], {}).get("identityKey")
            expected = hmac256(self.key, f"bridgey-confirm-v1\0{self.id}\0{m['deviceId']}\0{identity_key}".encode())
            try:
                load_public(unb64(identity_key)).verify(unb64(m["signature"]), self.transcript(), ec.ECDSA(hashes.SHA256()))
                signed = True
            except Exception:
                signed = False
            ok = m["deviceId"] == self.remote_id and (pinned is None or pinned == identity_key) and \
                hmac.compare_digest(expected, unb64(m["proof"])) and signed
            log("confirm_received", remote=self.remote_id[:8], transcript="v2" if self.tunnel else "v1", verified=ok)
            if not ok:
                self.close()
                return
            self.peer.trust(self.remote_id, self.remote_name, identity_key)
            self.remote_confirmed = True
            self.complete()
        elif kind == "heartbeat.ping":
            self.send({"kind": "heartbeat.pong", "sessionId": self.id, "messageId": m.get("messageId")})
        elif kind == "features.update":
            features = self.decrypt(m)["features"]
            log("features", remote=self.remote_id[:8], connect=features.get("connect_draft1") is True)
            if features.get("connect_draft1") is True:
                self.send_addresses()
        elif kind == "connect.addresses":
            payload = self.decrypt(m)
            self.peer.learn(self.remote_id, payload)
            mine = self.peer.pair_check(self.remote_id)
            lower = self.peer.state.device_id < self.remote_id
            log("connect_addresses", remote=self.remote_id[:8], count=len(payload.get("addrs", [])), check_match=mine is not None and mine == payload.get("pairCheck"))
            same = mine is not None and mine == payload.get("pairCheck")
            if not same and lower and self.contribution is None:
                self.contribution = os.urandom(32)
                self.send_encrypted("connect.setup", {"version": 1, "contribution": b64(self.contribution), "rotate": mine is not None})
        elif kind == "connect.setup":
            payload = self.decrypt(m)
            theirs = unb64(payload["contribution"])
            mine = self.contribution
            if mine is None:
                mine = os.urandom(32)
                self.send_encrypted("connect.setup", {"version": 1, "contribution": b64(mine), "rotate": payload.get("rotate", False)})
            self.contribution = None
            local, remote = self.peer.state.device_id, self.remote_id
            low, high = (local, remote) if local < remote else (remote, local)
            c_low, c_high = (mine, theirs) if local < remote else (theirs, mine)
            secret = hkdf(c_low + c_high, b"bridgey-pair-secret-v1", low.encode() + b"\0" + high.encode())
            self.peer.set_secret(remote, secret)
            self.send_encrypted("connect.setup.ack", {"version": 1})
            log("pair_secret_set", remote=remote[:8])
        elif kind == "pairing.cancel":
            self.close()

    def agree(self):
        code, self.key = self.material()
        trusted = self.remote_id in self.peer.state.data["trusted"]
        if self.tunnel and not trusted:
            log("tunnel_untrusted", remote=self.remote_id[:8])
            self.close()
            return
        log("code", code=code, remote=self.remote_id[:8], trusted=trusted, over="tunnel" if self.tunnel else "tcp")
        self.confirm()

    def send_addresses(self):
        reply = self.peer.core_command({"c": "addresses"})
        if not reply or not reply.get("ok"):
            return
        payload = {"version": 1, "port": reply["port"], "addrs": reply["addrs"][:16]}
        check = self.peer.pair_check(self.remote_id)
        if check:
            payload["pairCheck"] = check
        self.send_encrypted("connect.addresses", payload)


class Peer:
    def __init__(self, args):
        self.state = State(args.state, args.name, args.device_id)
        self.sessions = {}
        self.lib = ctypes.CDLL(args.lib)
        self.lib.bridgey_connect_start.restype = ctypes.c_void_p
        self.lib.bridgey_connect_start.argtypes = [ctypes.c_char_p]
        self.lib.bridgey_connect_command.restype = ctypes.c_void_p
        self.lib.bridgey_connect_command.argtypes = [ctypes.c_uint64, ctypes.c_char_p]
        self.lib.bridgey_connect_next_event.restype = ctypes.c_void_p
        self.lib.bridgey_connect_next_event.argtypes = [ctypes.c_uint64, ctypes.c_uint32]
        self.lib.bridgey_connect_free.argtypes = [ctypes.c_void_p]
        self.lib.bridgey_connect_stop.argtypes = [ctypes.c_uint64]
        node = self.state.node.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        config = {"port": args.udp_port, "controlUrl": args.control, "app": "bridgey-test-peer/0.1",
                  "nodeKey": base64.urlsafe_b64encode(node).rstrip(b"=").decode(), "relayOnly": args.relay_only}
        reply = json.loads(self.take(self.lib.bridgey_connect_start(json.dumps(config).encode())))
        if not reply.get("ok"):
            sys.exit(f"core did not start: {reply}")
        self.handle = reply["handle"]
        log("started", device=self.state.device_id[:8], udp=reply.get("udpPort"))
        self.sync()

    def take(self, pointer):
        if not pointer:
            return None
        text = ctypes.string_at(pointer).decode()
        self.lib.bridgey_connect_free(pointer)
        return text

    def core_command(self, command):
        text = self.take(self.lib.bridgey_connect_command(self.handle, json.dumps(command).encode()))
        return json.loads(text) if text else None

    def sync(self):
        peers = []
        for device_id, secret in self.state.data["secrets"].items():
            side = 0 if self.state.device_id < device_id else 1
            addresses = [{"a": a["a"], "p": self.state.data["addresses"].get(device_id, {}).get("port", 42458), "kind": a["kind"]}
                         for a in self.state.data["addresses"].get(device_id, {}).get("addrs", [])]
            connected = any(s.authenticated and s.remote_id == device_id for s in self.sessions.values())
            peers.append({"id": device_id, "side": side, "pairSecret": secret, "addresses": addresses, "connected": connected})
        self.core_command({"c": "peers", "peers": peers})

    def trust(self, device_id, name, identity_key):
        self.state.data["trusted"][device_id] = {"name": name, "identityKey": identity_key}
        self.state.save()

    def set_secret(self, device_id, secret):
        self.state.data["secrets"][device_id] = b64(secret)
        self.state.save()
        self.sync()

    def learn(self, device_id, payload):
        self.state.data["addresses"][device_id] = {"port": payload.get("port", 42458), "addrs": payload.get("addrs", [])}
        self.state.save()
        self.sync()

    def pair_check(self, device_id):
        secret = self.state.data["secrets"].get(device_id)
        if not secret:
            return None
        return base64.urlsafe_b64encode(hmac256(unb64(secret), b"bridgey-pair-check-v1")[:8]).rstrip(b"=").decode()

    def authenticated(self, session):
        log("authenticated", remote=session.remote_id[:8], over="tunnel" if session.tunnel else "tcp",
            route=(session.tunnel or {}).get("route"), relay=(session.tunnel or {}).get("relay"))
        self.sync()

    def ended(self, session, reason):
        self.sessions.pop(id(session), None)
        log("session_ended", remote=session.remote_id[:8], over="tunnel" if session.tunnel else "tcp", reason=reason)
        self.sync()

    def start_session(self, sock, initiated, tunnel=None):
        session = Session(self, sock, initiated, tunnel)
        self.sessions[id(session)] = session
        threading.Thread(target=session.run, daemon=True).start()

    def dial(self, address):
        host, port = address.rsplit(":", 1)
        sock = socket.create_connection((host, int(port)), timeout=10)
        sock.settimeout(None)
        log("dialled", address=address)
        self.start_session(sock, initiated=True)

    def listen(self, port):
        server = socket.create_server(("127.0.0.1", port))

        def accept():
            while True:
                sock, _ = server.accept()
                log("accepted")
                self.start_session(sock, initiated=False)

        threading.Thread(target=accept, daemon=True).start()

    def drop_tcp(self, everything=False):
        for session in list(self.sessions.values()):
            if everything or not session.tunnel:
                log("dropping_tcp", remote=session.remote_id[:8])
                session.close()

    def events(self, seconds, drop_tcp_after=None, control_dir=None):
        deadline = time.monotonic() + seconds
        dropped = False
        while time.monotonic() < deadline:
            if drop_tcp_after is not None and not dropped and time.monotonic() - STARTED >= drop_tcp_after:
                dropped = True
                self.drop_tcp()
            for name, everything in (("drop-tcp", False), ("drop-all", True)):
                path = os.path.join(control_dir, name) if control_dir else None
                if path and os.path.exists(path):
                    os.remove(path)
                    self.drop_tcp(everything)
            text = self.take(self.lib.bridgey_connect_next_event(self.handle, 500))
            if not text:
                continue
            event = json.loads(text)
            kind = event.get("e")
            if kind == "sign":
                signature = self.state.node.sign(unb64(event["data"]), ec.ECDSA(hashes.SHA256()))
                self.core_command({"c": "sign.result", "id": event["id"], "sig": b64(signature)})
            elif kind == "tunnel":
                log("tunnel", route=event["route"], relay=event.get("relay"), quic_client=event["quicClient"], rtt_ms=event.get("rttMs"))
                sock = socket.create_connection(("127.0.0.1", event["port"]))
                sock.sendall((event["token"] + "\n").encode())
                self.start_session(sock, initiated=event["quicClient"], tunnel=event)
            else:
                log("core", **{k: v for k, v in event.items() if k != "e"}, kind=kind)
        self.lib.bridgey_connect_stop(self.handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--lib", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--name", default="Connect test peer")
    parser.add_argument("--device-id", default="ffffffff-ffff-4fff-bfff-ffffffffffff")
    parser.add_argument("--control", default="")
    parser.add_argument("--relay-only", action="store_true")
    parser.add_argument("--udp-port", type=int, default=0)
    parser.add_argument("--dial", help="host:port of an app's TCP listener, to pair over TCP first")
    parser.add_argument("--listen", type=int, help="accept one TCP session on 127.0.0.1:<port> (peer to peer tests)")
    parser.add_argument("--drop-tcp-after", type=float, help="close TCP sessions after this many seconds, to move to a tunnel")
    parser.add_argument("--control-dir", help="touch drop-tcp or drop-all in this directory to end sessions")
    parser.add_argument("--seconds", type=int, default=300)
    args = parser.parse_args()
    peer = Peer(args)
    if args.listen:
        peer.listen(args.listen)
    if args.dial:
        peer.dial(args.dial)
    peer.events(args.seconds, args.drop_tcp_after, args.control_dir)


if __name__ == "__main__":
    main()
