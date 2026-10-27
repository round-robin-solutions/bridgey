#!/usr/bin/env python3
"""Prints the protocol 2 entries of protocol/test-vectors/crypto-v1.properties (commitment, code, envelope tag)
from the protocol 1 fixture. Independent of both apps. Usage: crypto_v2_vectors.py <crypto-v1.properties>."""
import base64, hashlib, hmac, struct, sys
from cryptography.hazmat.primitives.asymmetric import ec
props = dict(l.split("=", 1) for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if "=" in l)
sid = props["sessionId"]
privA = int.from_bytes(base64.b64decode(props["privateKeyA"]), "big")
pubB = base64.b64decode(props["publicKeyB"])
ka = ec.derive_private_key(privA, ec.SECP256R1())
shared = ka.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), pubB))
prk = hmac.new(hashlib.sha256(sid.encode()).digest(), shared, hashlib.sha256).digest()
key = hmac.new(prk, b"bridgey-pairing-v1\x01", hashlib.sha256).digest()
assert base64.b64encode(key).decode() == props["expectedKey"], "v1 key mismatch"
def lp(fields):
    out = b""
    for f in fields:
        if f is None:
            out += b"\xff\xff\xff\xff"
        else:
            b = f.encode("utf-8"); out += struct.pack(">I", len(b)) + b
    return out
A, B = props["publicKeyA"], props["publicKeyB"]
commit = base64.b64encode(hashlib.sha256(lp(["bridgey-commit-v2", sid, A])).digest()).decode()
sas = hmac.new(prk, lp(["bridgey-sas-v2", A, B]) + b"\x01", hashlib.sha256).digest()
code = str(int.from_bytes(sas[:4], "big") % 1000000).zfill(6)
ekey = hmac.new(key, b"bridgey-envelope-v2", hashlib.sha256).digest()
# Sample frame: clipboard.update from deviceId (android-fixture-device), fields in Message order.
msg = dict(kind="clipboard.update", sessionId=sid, messageId="0d9c8b7a-6f5e-4d3c-2b1a-0f9e8d7c6b5a", nonce=props["aesNonce"], ciphertext=props["aesCiphertext"], sequence="7")
order = ["kind","sessionId","deviceId","deviceName","publicKey","identityKey","proof","signature","messageId","nonce","ciphertext","transferId","sequence","targetDeviceId","commitment","protocolVersion"]
tag = base64.b64encode(hmac.new(ekey, lp(["bridgey-envelope-v2", props["deviceId"]] + [msg.get(k) for k in order]), hashlib.sha256).digest()).decode()
print(f"expectedCommitmentA={commit}")
print(f"expectedSasCodeV2={code}")
print(f"expectedEnvelopeKey={base64.b64encode(ekey).decode()}")
print(f"envelopeMessageId={msg['messageId']}")
print(f"envelopeSequence=7")
print(f"expectedEnvelopeTag={tag}")
