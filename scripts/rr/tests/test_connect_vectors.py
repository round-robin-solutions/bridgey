"""protocol/test-vectors/connect-v1.json: Python agrees with the Rust core on every derivation."""
import base64
import hashlib
import hmac
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
VECTORS = json.loads((ROOT / "protocol" / "test-vectors" / "connect-v1.json").read_text(encoding="utf-8"))


def b64(text):
    return base64.b64decode(text)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def hkdf(ikm, salt, info, length=32):
    prk = hmac.new(salt or b"\0" * 32, ikm, hashlib.sha256).digest()
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


def hmac256(key, *parts):
    return hmac.new(key, b"".join(parts), hashlib.sha256).digest()


class ConnectVectorsTest(unittest.TestCase):
    def setUp(self):
        self.pair = VECTORS["pair"]
        self.secret = hkdf(b64(self.pair["cLow"]) + b64(self.pair["cHigh"]), b"bridgey-pair-secret-v1",
                           self.pair["idLow"].encode() + b"\0" + self.pair["idHigh"].encode())

    def test_pair_secret_and_derived_values(self):
        self.assertLess(self.pair["idLow"], self.pair["idHigh"])
        self.assertEqual(base64.b64encode(self.secret).decode(), self.pair["pairSecret"])
        self.assertEqual(b64url(hmac256(self.secret, b"bridgey-pair-check-v1")[:8]), self.pair["pairCheckUrl"])
        self.assertEqual(base64.b64encode(hkdf(self.secret, b"", b"bridgey-signal-v1")).decode(), self.pair["sigKey"])
        for date, rdv in self.pair["rdvIdsUrl"].items():
            self.assertEqual(b64url(hmac256(self.secret, b"bridgey-rdv-v1", date.encode())[:16]), rdv)
        net = self.pair["netTagUrl"]
        self.assertEqual(b64url(hmac256(self.secret, b"bridgey-net-v1", net["fingerprint"].encode())[:8]), net["tag"])

    def test_transcript(self):
        t = VECTORS["transcript"]
        fields = ["bridgey-auth-v2", t["sessionId"], t["initiatorDeviceId"], t["responderDeviceId"],
                  t["initiatorEphemeralKey"], t["responderEphemeralKey"], t["exporter"]]
        self.assertEqual(base64.b64encode("\0".join(fields).encode()).decode(), t["bytes"])

    def test_node_auth(self):
        a = VECTORS["nodeAuth"]
        node = b64url_decode(a["nodeUrl"])
        self.assertEqual(len(node), 65)
        self.assertEqual(base64.b64encode(b"bridgey-rdv-auth-v1\0" + b64(a["nonce"]) + node).decode(), a["message"])
        self.assertEqual(b64url(hashlib.sha256(node).digest()[:16]), a["nodeIdUrl"])

    def test_turn_rest_credentials(self):
        r = VECTORS["turnRest"]
        username = f'{r["expiry"]}:{r["sidUrl"][:8]}.{r["side"]}'
        self.assertEqual(username, r["username"])
        tag = hmac.new(r["secret"].encode(), username.encode(), hashlib.sha1).digest()
        self.assertEqual(base64.b64encode(tag).decode(), r["credential"])

    def test_node_auth_v2(self):
        # The single-flight sign-in (hello in the upgrade request): host, 8-byte big-endian ms timestamp, cnonce, node.
        a = VECTORS["nodeAuthV2"]
        node = b64url_decode(a["nodeUrl"])
        message = b"bridgey-rdv-auth-v2\0" + a["host"].encode() + b"\0" + a["ts"].to_bytes(8, "big") + b64(a["cnonce"]) + node
        self.assertEqual(len(b64(a["cnonce"])), 16)
        self.assertEqual(base64.b64encode(message).decode(), a["message"])

    def test_warm_relay_username(self):
        # A node's warm relay username: only the service (it holds the secret) can tie it to the node.
        w = VECTORS["turnWarm"]
        expiry = str(w["expiry"])
        tag = hmac.new(w["secret"].encode(), b"bridgey-warm-v1\0" + w["nodeIdUrl"].encode() + b"\0" + expiry.encode(), hashlib.sha256).digest()[:9]
        username = f"{expiry}:w.{b64url(tag)}"
        self.assertEqual(username, w["username"])
        credential = hmac.new(w["secret"].encode(), username.encode(), hashlib.sha1).digest()
        self.assertEqual(base64.b64encode(credential).decode(), w["credential"])

    def test_sealed_signal(self):
        try:
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        except ImportError:
            self.skipTest("the cryptography package is not installed")
        s = VECTORS["sealed"]
        body = b64url_decode(s["bodyUrl"])
        self.assertEqual(body[0], 1)
        self.assertEqual(body[1:13], b64(s["nonce"]))
        aad = b"bridgey-signal-v1\0" + s["rdvIdUrl"].encode() + b"\0" + str(s["side"]).encode() + b"\0" + s["sidUrl"].encode()
        plain = AESGCM(b64(s["sigKey"])).decrypt(body[1:13], body[13:], aad)
        self.assertEqual(plain.decode(), s["plaintext"])
        self.assertEqual(s["rdvIdUrl"], self.pair["rdvIdsUrl"]["2026-10-27"])


if __name__ == "__main__":
    unittest.main()
