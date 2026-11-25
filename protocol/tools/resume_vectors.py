#!/usr/bin/env python3
"""Writes protocol/test-vectors/files-resume-v1.json: resuming a file from its last verified chunk (draft
files_resume_draft1, docs/protocol.md "Resuming files", docs/file-resume.md).

rust/client (resume.rs tests) checks every vector today; the Android and macOS suites decode the same vectors when
they build the feature. Only the standard library is needed. Edit here, then run it.
"""
import base64
import hashlib
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parents[1] / "test-vectors" / "files-resume-v1.json"
MIB = 1024 * 1024
SIZE = 3_500_000
SOURCE = bytes((i * 31) % 251 for i in range(SIZE))
T = "6d1f2c3b-4a59-4687-9a1b-2c3d4e5f6a7b"
OTHER_T = "0b1e2d3c-4f5a-4687-9a1b-2c3d4e5f6a7c"
PEER = "7e57d00d-0000-4000-8000-0000000000aa"
OTHER_PEER = "7e57d00d-0000-4000-8000-0000000000bb"
DAY = 24 * 60 * 60 * 1000
BASE = 1_786_550_000_000
b64 = lambda b: base64.b64encode(b).decode()
sha = lambda b: b64(hashlib.sha256(b).digest())
WHOLE = sha(SOURCE)
OFFSETS = [MIB, 2 * MIB, 3 * MIB, SIZE]
P = {n: sha(SOURCE[:n]) for n in OFFSETS + [1_000_000]}
N = 2 * MIB

prefixes = [{"offset": n, "prefixSha256": P[n]} for n in OFFSETS]

resume = []


def rp(name, plaintext=None, expect="invalid", string=None, transfer=T, size=SIZE, write=False):
    case = {"name": name, "transferId": transfer, "size": size}
    if string is not None:
        case["plaintextString"] = string
    else:
        case["plaintext"] = plaintext
    case["expect"] = expect
    if write:
        case["write"] = True
    resume.append(case)


def ok(offset):
    return {"offset": offset, "prefixSha256": P[offset]}


def body(offset=N, prefix=None, **extra):
    return {"version": 1, "transferId": T, "offset": offset, "prefixSha256": P.get(offset, P[N]) if prefix is None else prefix, **extra}


rp("a valid resume", body(), ok(N), write=True)
rp("the whole file was received", body(SIZE), ok(SIZE), write=True)
rp("one block", body(MIB), ok(MIB))
rp("an integral float offset", expect=ok(N), string='{"version":1,"transferId":"%s","offset":2097152.0,"prefixSha256":"%s"}' % (T, P[N]))
rp("unknown fields are ignored", body(note="later drafts may add fields"), ok(N))
rp("offset zero", body(0, P[N]))
rp("an offset that is not a whole number of blocks", body(1_000_000))
rp("one byte short of the whole file", body(SIZE - 1, P[N]))
rp("an offset past the size", body(SIZE + 1, P[N]))
rp("a negative offset", body(-1, P[N]))
rp("a fractional offset", string='{"version":1,"transferId":"%s","offset":1.5,"prefixSha256":"%s"}' % (T, P[N]))
rp("an offset in a string", body(str(N), P[N]))
rp("another transfer", {**body(), "transferId": OTHER_T})
rp("the transfer ID in capitals (IDs match exactly)", {**body(), "transferId": T.upper()})
rp("version 2", {**body(), "version": 2})
rp("no version", {k: v for k, v in body().items() if k != "version"})
rp("no prefix hash", {k: v for k, v in body().items() if k != "prefixSha256"})
rp("a prefix hash of 31 bytes", body(prefix=b64(hashlib.sha256(SOURCE[:N]).digest()[:31])))
rp("a prefix hash that is not base64", body(prefix="not base64!"))
rp("a plaintext over 1,024 bytes", body(padding="x" * 1024))
rp("not an object", string="[1,2,3]")

acks = []


def ap(name, plaintext=None, expect="invalid", string=None, write=False):
    case = {"name": name, "transferId": T, "proposed": N}
    if string is not None:
        case["plaintextString"] = string
    else:
        case["plaintext"] = plaintext
    case["expect"] = expect
    if write:
        case["write"] = True
    acks.append(case)


def ack(offset=N, **extra):
    return {"version": 1, "transferId": T, "offset": offset, **extra}


ap("continue from the receiver's offset", ack(), "resume", write=True)
ap("from byte zero, saying why", ack(0, reason="mismatch"), "restart", write=True)
ap("from byte zero without a reason", ack(0), "restart")
ap("a reason this version does not know", ack(0, reason="something_new"), "restart")
ap("an integral float offset", expect="resume", string='{"version":1,"transferId":"%s","offset":2097152.0}' % T)
ap("another offset", ack(MIB))
ap("one byte past the proposal", ack(N + 1))
ap("a negative offset", ack(-1))
ap("no offset", {"version": 1, "transferId": T})
ap("another transfer", {**ack(), "transferId": OTHER_T})
ap("version 2", {**ack(), "version": 2})
ap("a plaintext over 1,024 bytes", ack(padding="x" * 1024))

decisions = []


def rd(name, resume_at, record=None, offer=None, now=BASE + 60_000, after_restart=False, drops=None):
    rec = {"peer": PEER, "size": SIZE, "sha256": WHOLE, "length": N, "prefixSha256": P[N], "partLength": N,
           "name": "photo.jpg", "updatedMs": BASE, **(record or {})}
    off = {"peer": PEER, "size": SIZE, "sha256": WHOLE, "name": "photo.jpg", **(offer or {})}
    case = {"name": name, "record": rec, "offer": off, "nowMs": now}
    if after_restart:
        case["afterRestart"] = True
    case["expect"] = {"resumeAt": resume_at}
    if drops is not None:
        case["expect"]["dropsRecord"] = drops
    decisions.append(case)


other = sha(b"another file")
rd("the same file from the same device resumes", N, drops=False)
rd("the whole file was kept", SIZE, {"length": SIZE, "prefixSha256": WHOLE, "partLength": SIZE})
rd("one block", MIB, {"length": MIB, "prefixSha256": P[MIB], "partLength": MIB + 5000})
rd("bytes past the record are cut off, not offered", N, {"partLength": SIZE - 1})
rd("another device sends the same file: never this device's partial", None, offer={"peer": OTHER_PEER}, drops=False)
rd("other content under another name leaves the partial alone", None, offer={"sha256": other, "size": 1000, "name": "other.jpg"}, drops=False)
rd("the source changed: same name, other content drops the partial", None, offer={"sha256": other}, drops=True)
rd("the source changed size: same name drops the partial", None, offer={"sha256": other, "size": SIZE + 10}, drops=True)
rd("a tampered partial does not match its record", None, {"flipByte": 1000})
rd("a partial shorter than its record", None, {"partLength": MIB})
rd("a missing partial", None, {"partExists": False})
rd("just inside 24 hours", N, now=BASE + DAY - 1, drops=False)
rd("24 hours after it last grew it has expired", None, now=BASE + DAY, drops=True)
rd("a stamp more than 24 hours in the future counts as expired", None, {"updatedMs": BASE + 60_000 + DAY + 1}, drops=True)
rd("after a restart the record and partial still check out", N, after_restart=True, drops=False)
rd("after a restart an expired record is swept", None, now=BASE + DAY + 5, after_restart=True, drops=True)
rd("after a restart a missing partial is swept", None, {"partExists": False}, after_restart=True, drops=True)
rd("after a restart a partial shorter than its record is swept", None, {"partLength": 1000}, after_restart=True, drops=True)
rd("nothing verified yet: nothing to resume", None, {"length": 0, "prefixSha256": sha(b""), "partLength": 5000})

senders = []


def sd(name, resume_payload, offset, reason, flip=None, length=None):
    case = {"name": name, "transferId": T, "resume": resume_payload}
    if flip is not None:
        case["senderFlipByte"] = flip
    if length is not None:
        case["senderLength"] = length
    case["expect"] = {"offset": offset, "reason": reason}
    senders.append(case)


sd("the receiver's prefix matches this file", body(), N, None)
sd("one block", body(MIB), MIB, None)
sd("the receiver has the whole file", body(SIZE), SIZE, None)
sd("the receiver's prefix hash is of other bytes", body(N, P[MIB]), 0, "mismatch")
sd("the whole file's hash differs", body(SIZE, P[N]), 0, "mismatch")
sd("this file differs inside the prefix", body(), 0, "mismatch", flip=100)
sd("a difference after the offset is not the prefix check's business", body(), N, None, flip=3_200_000)
sd("an offset that is not a whole number of blocks", body(1_000_000), 0, "invalid")
sd("this file is now shorter than the offset", body(3 * MIB), 0, "invalid", length=3_000_000)
sd("offset zero", body(0, P[N]), 0, "invalid")
sd("past the size", body(SIZE + 1, P[N]), 0, "invalid")

retention = []
PEERS = ["7e57d00d-0000-4000-8000-0000000000a%d" % i for i in range(1, 6)]


def rt(name, kept, new_peer, new_updated, evicted):
    peer, length = new_peer if isinstance(new_peer, tuple) else (new_peer, None)
    new = {"peer": peer, "updatedMs": new_updated, **({"length": length} if length else {})}
    retention.append({"name": name, "kept": kept, "new": new, "evicted": evicted})


def k(label, peer, n, updated, in_use=False, length=None):
    return {"label": label, "peer": peer, "n": n, "updatedMs": updated, **({"inUse": True} if in_use else {}), **({"length": length} if length else {})}


GIB = 1024 * MIB


rt("a fifth partial from one device pushes out its oldest", [k("a%d" % i, PEERS[0], i, BASE + i) for i in range(1, 5)], PEERS[0], BASE + 5, ["a1"])
rt("a partial in use is never pushed out", [k("a1", PEERS[0], 1, BASE + 1, True)] + [k("a%d" % i, PEERS[0], i, BASE + i) for i in range(2, 5)],
   PEERS[0], BASE + 5, ["a2"])
rt("other devices' partials do not count against a device", [k("b%d" % i, PEERS[1], i, BASE + i) for i in range(1, 5)] +
   [k("a%d" % i, PEERS[0], 10 + i, BASE + 10 + i) for i in range(1, 4)], PEERS[0], BASE + 20, [])
rt("sixteen in all: the oldest anywhere goes", [k("p%d" % (4 * d + i), PEERS[d], 4 * d + i, BASE + 4 * d + i) for d in range(4) for i in range(1, 5)],
   PEERS[4], BASE + 100, ["p1"])
rt("over 20 GiB in all: the oldest goes", [k("big1", PEERS[0], 1, BASE + 1, length=8 * GIB), k("big2", PEERS[1], 2, BASE + 2, length=8 * GIB)],
   (PEERS[2], 8 * GIB), BASE + 3, ["big1"])
rt("an expired partial goes when another is saved", [k("old", PEERS[0], 1, BASE), k("fresh", PEERS[1], 2, BASE + DAY - 10)], PEERS[2], BASE + DAY, ["old"])

folder_accept = []


def fa(name, partial, expect):
    folder_accept.append({"name": name, "entrySizes": {"7": SIZE, "8": 2 * MIB + 100}, "partial": partial, "expect": expect})


def fp(entry=7, offset=N, prefix=None):
    return {"entry": entry, "offset": offset, "prefixSha256": P[N] if prefix is None else prefix}


fa("the interrupted entry and its verified prefix", fp(), {"entry": 7, "offset": N, "prefixSha256": P[N]})
fa("null: no partial", None, "none")
fa("offset zero", fp(offset=0), "invalid")
fa("an offset past the entry's size", fp(entry=8, offset=3 * MIB), "invalid")
fa("an offset that is not a whole number of blocks", fp(offset=1_000_000), "invalid")
fa("the whole entry", fp(offset=SIZE, prefix=WHOLE), {"entry": 7, "offset": SIZE, "prefixSha256": WHOLE})
fa("an entry the manifest does not have", fp(entry=9), "invalid")
fa("a negative entry", fp(entry=-1), "invalid")
fa("a prefix hash that is not 32 bytes", fp(prefix=b64(b"short")), "invalid")

entry_offers = []


def eo(name, partial, offer, expect):
    entry_offers.append({"name": name, "receiverPartial": partial, "entryOffer": offer, "expect": expect})


eo("the agreed offset: chunks start there", {"entry": 7, "offset": N}, {"entry": 7, "offset": N, "size": SIZE}, {"startAt": N})
eo("no offset: the sender's prefix differed, from byte zero", {"entry": 7, "offset": N}, {"entry": 7, "size": SIZE}, {"startAt": 0, "discardsPartial": True})
eo("another offset fails the entry", {"entry": 7, "offset": N}, {"entry": 7, "offset": MIB, "size": SIZE}, {"entryFailed": "invalid_message"})
eo("an offset for an entry without a partial fails it", {"entry": 7, "offset": N}, {"entry": 8, "offset": MIB, "size": 2 * MIB + 100}, {"entryFailed": "invalid_message"})
eo("an offset with no partial at all fails the entry", None, {"entry": 7, "offset": N, "size": SIZE}, {"entryFailed": "invalid_message"})
eo("other entries are unchanged", {"entry": 7, "offset": N}, {"entry": 8, "size": 2 * MIB + 100}, {"startAt": 0})

out = {
    "description": "Resuming a file from its last verified chunk (draft files_resume_draft1, docs/protocol.md 'Resuming files'). "
                   "source: the file every case uses, byte i is (i * 31) mod 251, with its size and base64 SHA-256. prefixes: base64 SHA-256 of "
                   "the first 'offset' bytes; a running hash continued with the rest gives the whole file's. resumePayload: a files.resume "
                   "plaintext for the transfer 'transferId' of 'size' bytes; expect is the decoded offset and prefix or 'invalid' (the sender then "
                   "answers offset 0, reason invalid); a valid offset is a positive multiple of 1,048,576 (a block) not above the size, or the size "
                   "itself. ackPayload: a files.resume.ack plaintext answering a files.resume of 'proposed' bytes; "
                   "expect is 'resume' (continue from proposed), 'restart' (from byte zero) or 'invalid' (cancel the file, discard the partial). "
                   "'plaintext' is serialised by each platform's own encoder and 'plaintextString' is used byte for byte; 'write': true means "
                   "each platform's own encoder produces the same fields. receiverDecision: a kept partial's record (its on-disk bytes are the "
                   "source's first 'partLength' bytes, with 'flipByte' inverted, absent when 'partExists' is false) and a resumable files.offer "
                   "at 'nowMs'; with 'afterRestart' the record is reloaded and swept first. expect.resumeAt is the offset of the files.resume "
                   "the receiver sends after re-reading and checking its partial, or null for files.accept (byte zero); dropsRecord, when "
                   "present, says whether the record is gone after the decision. senderDecision: the sender's answer to a files.resume from "
                   "its own file (the source with 'senderFlipByte' inverted, cut to 'senderLength'; the offer's size and SHA-256 are that file's): "
                   "the files.resume.ack offset and reason, from the SHA-256 of the file's first 'offset' bytes (kept at every block while "
                   "hashing it for the offer, or read again). "
                   "retention: kept partials (label, peer, updatedMs, inUse, verified length when it matters) and a new one saved at "
                   "new.updatedMs: the labels evicted, in order (expired first, then the oldest not in use over the limits: 4 per device, 16 "
                   "and 20 GiB of verified bytes in all). folderAccept and entryOffer (designed, "
                   "folders only, not built yet): the folders.accept 'partial' object against the manifest's entry sizes, and an entry's "
                   "files.offer 'offset' against the receiver's partial.",
    "limits": {"blockBytes": MIB, "lifetimeMs": DAY, "perDevice": 4, "total": 16, "maxKeptBytes": 20 * GIB, "maxPlaintextBytes": 1024,
               "checkpointEveryBytes": 64 * MIB, "resumableAbove": MIB, "answerWithinSeconds": 120},
    "source": {"pattern": "byte i is (i * 31) mod 251", "size": SIZE, "sha256": WHOLE},
    "prefixes": prefixes,
    "resumePayload": resume,
    "ackPayload": acks,
    "receiverDecision": decisions,
    "senderDecision": senders,
    "retention": retention,
    "folderAccept": folder_accept,
    "entryOffer": entry_offers,
}
OUT.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
print(len(resume), len(acks), len(decisions), len(senders), len(retention), len(folder_accept), len(entry_offers))
