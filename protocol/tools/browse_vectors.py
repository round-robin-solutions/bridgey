#!/usr/bin/env python3
"""Writes protocol/test-vectors/browse-v1.json: golden vectors for browsing the phone's files (files_browse_draft1,
docs/protocol.md "Draft: phone files, media and folders both ways").

The phone writes places.files_page, places.download_started, media.thumbnails_batch, media.preview_part and
media.range_part, and the Mac reads them; the Mac writes media.list and media.cancel, and the phone reads them.
Cases marked "write" are exactly what the sender's encoder writes for those inputs; every case is decoded by the
receiver. expect "reject" means the receiver refuses the message; otherwise it lists what the receiver keeps. A kept
image or file part keeps its data as sent (the same bytes), so expect leaves data out.
Edit here, then run it. Stdlib only.
"""
import base64
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parents[1] / "test-vectors" / "browse-v1.json"
R = "5f0e8d7c-6b5a-4c3d-9e2f-1a0b9c8d7e6f"
FT = "3c2b1a09-8f7e-4d6c-b5a4-938271605f4e"
PLACE = "q3Jx0bVv1eG7tq8Wm2l5wA"
T = 1790000000000


def b64(data):
    return base64.b64encode(bytes(data)).decode()


def pattern(count):
    return bytes(i % 256 for i in range(count))


def case(name, plaintext, expect, write=False):
    v = {"name": name, "plaintext": plaintext, "expect": expect}
    if write:
        v["write"] = True
    return v


def without(obj, *keys):
    return {k: v for k, v in obj.items() if k not in keys}


# places.files_page (phone to Mac). expect: what the Mac keeps, nulls written out; size and mimeType are null for folders.
def entry(name, dir=False, size=None, modified=None, mime=None, thumb=False):
    return {"name": name, "dir": dir, "size": size, "modified": modified, "mimeType": mime, "thumb": thumb}


def files_page(entries, place="default", path="Trip", folders=None, files=None, cursor=None, writable=False):
    return {"version": 1, "requestId": R, "placeId": place, "path": path, "entries": entries,
            "folderCount": sum(1 for e in entries if e["dir"]) if folders is None else folders,
            "fileCount": sum(1 for e in entries if not e["dir"]) if files is None else files,
            "nextCursor": cursor, "writable": writable}


def page_expect(p, entries=None):
    return {"entries": p["entries"] if entries is None else entries, "folderCount": p["folderCount"], "fileCount": p["fileCount"],
            "nextCursor": p["nextCursor"], "writable": p["writable"]}


trip = files_page([entry("Beach", dir=True, modified=T), entry("IMG_0001.jpg", size=2048, modified=T + 1000, mime="image/jpeg", thumb=True),
                   entry("notes.txt", size=12, mime="text/plain")])
root = files_page([], place=PLACE, path="", writable=True)
mixed = files_page([entry("data.bin"), entry("Résumé 2026.pdf", size=90000, modified=T - 1000000000, mime="application/pdf", thumb=True),
                    entry("n" * 251 + ".txt", size=1, mime="text/plain")], path="Documents/Work")
full = files_page([entry(f"f{i:03}", size=1) for i in range(200)], path="")
more = files_page([entry("Beach", dir=True, modified=T)], folders=3, files=250, cursor="o200")
odd = files_page([entry("ok.txt", size=1, mime="text/plain"), entry("a\u0007b", size=1), entry("x" * 256, size=1)])
places_files_page = [
    case("folders first, then files", trip, page_expect(trip), write=True),
    case("an empty place root that takes uploads", root, page_expect(root), write=True),
    case("unknown size and type, a provider thumbnail and a name of 255 bytes", mixed, page_expect(mixed), write=True),
    case("200 entries", full, page_expect(full), write=True),
    case("more to come: the counts are the whole folder's", more, page_expect(more)),
    # The Mac lists only entries it can ask for again (one existing component); the counts stay as sent.
    case("entries the Mac cannot address are skipped", odd, page_expect(odd, entries=[odd["entries"][0]])),
    case("201 entries", files_page([entry(f"f{i:03}", size=1) for i in range(201)], path=""), "reject"),
    case("version 2", {**trip, "version": 2}, "reject"),
    case("dir not a boolean", {**trip, "entries": [{**trip["entries"][0], "dir": "yes"}]}, "reject"),
    case("no entries", without(trip, "entries"), "reject"),
]

# places.download_started (phone to Mac).
def started(root_name, files, folders, total, transfer=FT):
    return {"version": 1, "requestId": R, "folderTransferId": transfer, "rootName": root_name, "fileCount": files, "folderCount": folders, "totalSize": total}


places_download_started = [case(n, p, without(p, "version", "requestId"), write=True) for n, p in [
    ("one photo", started("IMG_5.jpg", 1, 0, 2048)),
    ("a folder with subfolders", started("Trip", 12, 2, 9000)),
    ("over 4 GiB", started("Videos", 3, 0, 5000000000)),
]] + [
    case("folderTransferId in capitals", started("Trip", 1, 0, 1, transfer=FT.upper()), "reject"),
    case("folderTransferId not a UUID", started("Trip", 1, 0, 1, transfer="t1"), "reject"),
    case("no totalSize", without(started("Trip", 1, 0, 1), "totalSize"), "reject"),
    case("fileCount a string", {**started("Trip", 1, 0, 1), "fileCount": "1"}, "reject"),
]

# media.list (Mac to phone). The Mac leaves cursor out on a first page and keeps limit within 1 to 200.
def media_list(kind, limit=None, cursor=None, request=R):
    p = {"version": 1, "requestId": request, "kind": kind}
    if cursor is not None:
        p["cursor"] = cursor
    if limit is not None:
        p["limit"] = limit
    return p


def list_expect(kind, limit, cursor=None):
    return {"requestId": R, "kind": kind, "limit": limit, "cursor": cursor}


media_list_cases = [
    case("first page of photos and videos", media_list("media", 100), list_expect("media", 100), write=True),
    case("next page of recent documents", media_list("files", 100, "d100"), list_expect("files", 100, "d100"), write=True),
    case("both, the largest page", media_list("recent", 200, "r3.4"), list_expect("recent", 200, "r3.4"), write=True),
    case("no limit reads as 100", media_list("media"), list_expect("media", 100)),
    case("unknown kind", media_list("music", 100), "reject"),
    case("version 2", {**media_list("media", 100), "version": 2}, "reject"),
    case("requestId in capitals", media_list("media", 100, request=R.upper()), "reject"),
    case("requestId not a UUID", media_list("media", 100, request="r1"), "reject"),
]

# media.cancel (Mac to phone). Never answered.
media_cancel = [
    case("cancel", {"version": 1, "requestId": R}, {"requestId": R}, write=True),
    case("requestId in capitals", {"version": 1, "requestId": R.upper()}, "reject"),
    case("no requestId", {"version": 1}, "reject"),
]

# media.thumbnails_batch (phone to Mac). expect: the thumbnails the Mac shows (data as sent), tint as 0xRRGGBB or null,
# and the keys it counts as missing (thumbnails it cannot use, in order, then the batch's own missing list).
def thumb(key, mime="image/webp", width=256, height=192, tint="#336699", data=b"\x52\x49\x46\x46\x24\x00\x00\x00WEBPVP8 "):
    return {"key": key, "mimeType": mime, "width": width, "height": height, "tint": tint, "data": b64(data) if isinstance(data, bytes) else data}


def shown(t):
    return {**without(t, "data"), "tint": int(t["tint"][1:], 16) if t["tint"] else None}


def batch(thumbs, missing, done):
    return {"version": 1, "requestId": R, "thumbs": thumbs, "missing": missing, "done": done}


two = [thumb("k0"), thumb("k1", mime="image/jpeg", width=192, height=256, tint=None, data=b"\xff\xd8\xff\xe0\x00\x10JFIF")]
k3 = thumb("k3", width=512, height=384, tint="#0a0b0c")
big = thumb("k0", width=512, height=512, tint="#ffffff", data=pattern(24 * 1024))
media_thumbnails_batch = [
    case("two thumbnails and one missing, the last batch", batch(two, ["k2"], True), {"thumbs": [shown(t) for t in two], "missing": ["k2"], "done": True}, write=True),
    case("a batch before the last", batch([k3], [], False), {"thumbs": [shown(k3)], "missing": [], "done": False}, write=True),
    case("nothing could be made", batch([], ["k0", "k1"], True), {"thumbs": [], "missing": ["k0", "k1"], "done": True}, write=True),
    case("the closing batch", batch([], [], True), {"thumbs": [], "missing": [], "done": True}, write=True),
    case("a thumbnail of 24 KiB", batch([big], [], True), {"thumbs": [shown(big)], "missing": [], "done": True}, write=True),
    case("a thumbnail over 24 KiB counts as missing", batch([thumb("k0", data=pattern(24 * 1024 + 1))], [], True), {"thumbs": [], "missing": ["k0"], "done": True}),
    case("thumbnails without a size, not an image or not base64 count as missing",
         batch([thumb("k0", width=0), thumb("k1", mime="video/mp4"), thumb("k2", data="not base64!")], ["k3"], True),
         {"thumbs": [], "missing": ["k0", "k1", "k2", "k3"], "done": True}),
    case("a tint that is not a colour is dropped", batch([thumb("k0", tint="blue")], [], True), {"thumbs": [shown(thumb("k0", tint=None))], "missing": [], "done": True}),
    case("no done", without(batch(two, [], True), "done"), "reject"),
    case("thumbs not an array", batch({}, [], True), "reject"),
    case("width not an integer", batch([thumb("k0", width="256")], [], True), "reject"),
]

# media.preview_part (phone to Mac). Every part but the last carries 32 KiB; the whole preview is at most 1 MiB (32 parts).
def part(index, count, data, mime="image/jpeg", width=1600, height=1200, tint="#102030"):
    return {"version": 1, "requestId": R, "index": index, "count": count, "mimeType": mime, "width": width, "height": height, "tint": tint,
            "data": b64(data) if isinstance(data, bytes) else data}


def part_expect(p):
    return {**without(p, "version", "requestId", "data"), "tint": int(p["tint"][1:], 16) if p["tint"] else None}


jpeg = b"\xff\xd8\xff\xdb\x00\x43\x00\x08"
preview_written = [
    ("a single part", part(0, 1, jpeg)),
    ("the last of two parts, no tint", part(1, 2, b"\x00\x11\x22\xff\xd9", mime="image/webp", width=2048, height=1536, tint=None)),
    ("the first of the most parts: 32 KiB of 32", part(0, 32, pattern(32 * 1024), width=2048, height=1536)),
]
media_preview_part = [case(n, p, part_expect(p), write=True) for n, p in preview_written] + [
    case("a tint that is not a colour is dropped", part(0, 1, jpeg, tint="#12345"), part_expect(part(0, 1, jpeg, tint=None))),
    case("a part over 32 KiB", part(0, 2, pattern(32 * 1024 + 1)), "reject"),
    case("count 0", part(0, 0, jpeg), "reject"),
    case("count 34", part(0, 34, jpeg), "reject"),
    case("data not base64", part(0, 1, "not base64!"), "reject"),
    case("no mimeType", without(part(0, 1, jpeg), "mimeType"), "reject"),
]

# media.range_part (phone to Mac). An empty last part answers a range that starts at or past the end of the file.
def rng(offset, size, data, last, modified=T):
    return {"version": 1, "requestId": R, "offset": offset, "fileSize": size, "modified": modified, "data": b64(data) if isinstance(data, bytes) else data, "last": last}


range_written = [
    ("a part in the middle", rng(32768, 100000, pattern(16), False)),
    ("the last part", rng(98304, 100000, pattern(16), True)),
    ("past the end of the file", rng(100000, 100000, b"", True)),
    ("modified unknown", rng(0, 100000, pattern(16), False, modified=None)),
    ("a file over 4 GiB", rng(5000000000, 6000000000, pattern(16), False)),
    ("a part of 32 KiB", rng(0, 100000, pattern(32 * 1024), False)),
]
media_range_part = [case(n, p, without(p, "version", "requestId", "data"), write=True) for n, p in range_written] + [
    case("a part over 32 KiB", rng(0, 100000, pattern(32 * 1024 + 1), False), "reject"),
    case("data not base64", rng(0, 100000, "not base64!", False), "reject"),
    case("offset a string", {**rng(0, 100000, pattern(16), False), "offset": "0"}, "reject"),
    case("no last", without(rng(0, 100000, pattern(16), False), "last"), "reject"),
]

vectors = {
    "description": "Browsing the phone's files (files_browse_draft1, docs/protocol.md). write: the sender's encoder writes this "
                   "plaintext exactly. expect 'reject' means the receiver refuses the message; otherwise the fields it keeps "
                   "(a kept thumbnail or part keeps its data as sent, so expect leaves data out).",
    "placesFilesPage": places_files_page,
    "placesDownloadStarted": places_download_started,
    "mediaList": media_list_cases,
    "mediaThumbnailsBatch": media_thumbnails_batch,
    "mediaPreviewPart": media_preview_part,
    "mediaRangePart": media_range_part,
    "mediaCancel": media_cancel,
}

OUT.write_text(json.dumps(vectors, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"wrote {OUT}")
