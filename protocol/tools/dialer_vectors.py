#!/usr/bin/env python3
"""Writes protocol/test-vectors/dialer-v1.json: the Calls window (dialer_draft1) payloads both platforms decode.

request: dialer.contacts, dialer.recents and dialer.call as the phone decodes them (each vector names its kind).
status, contacts, recents, callResult: dialer.status, dialer.contacts_result, dialer.recents_result and
dialer.call_result as the Mac decodes them; 'android': true means the phone also writes exactly that plaintext.
Expected values are normalised: requestId lowercased, absent optionals null, lengths in UTF-16 units.
Names and numbers are made up. Edit here, then run it.
"""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parents[1] / "test-vectors" / "dialer-v1.json"
R = "5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293"
j = lambda o: json.dumps(o, separators=(",", ":"), ensure_ascii=False)


def sized(prefix, total):
    """A JSON object string of exactly `total` bytes: prefix, padding, then the closing quote and brace."""
    body = prefix + "x" * (total - len(prefix.encode()) - 2) + '"}'
    assert len(body.encode()) == total
    return body


request, status, contacts, recents, result = [], [], [], [], []


def q(name, kind, p, expect, raw=False):
    request.append({"name": name, "kind": kind, ("plaintextString" if raw else "plaintext"): p, "expect": expect})


def add(target, name, p, expect, raw=False, android=False):
    v = {"name": name, ("plaintextString" if raw else "plaintext"): p, "expect": expect}
    if android:
        v["android"] = True
    target.append(v)


# dialer.contacts
q("contacts, a name", "dialer.contacts", {"version": 1, "requestId": R, "query": "Anna"}, {"requestId": R, "query": "Anna"})
q("contacts, upper-case request ID", "dialer.contacts", {"version": 1, "requestId": R.upper(), "query": "98765"}, {"requestId": R, "query": "98765"})
q("contacts, spaces around are trimmed", "dialer.contacts", {"version": 1, "requestId": R, "query": "  Anna K "}, {"requestId": R, "query": "Anna K"})
q("contacts, 64 UTF-16 units", "dialer.contacts", {"version": 1, "requestId": R, "query": "a" * 64}, {"requestId": R, "query": "a" * 64})
q("contacts, 65 UTF-16 units", "dialer.contacts", {"version": 1, "requestId": R, "query": "a" * 65}, "reject")
q("contacts, Cyrillic name", "dialer.contacts", {"version": 1, "requestId": R, "query": "Анна"}, {"requestId": R, "query": "Анна"})
q("contacts, emoji counts two units", "dialer.contacts", {"version": 1, "requestId": R, "query": "\U0001F600" * 32}, {"requestId": R, "query": "\U0001F600" * 32})
q("contacts, emoji over 64 units", "dialer.contacts", {"version": 1, "requestId": R, "query": "\U0001F600" * 32 + "a"}, "reject")
q("contacts, only spaces", "dialer.contacts", {"version": 1, "requestId": R, "query": "   "}, "reject")
q("contacts, empty", "dialer.contacts", {"version": 1, "requestId": R, "query": ""}, "reject")
q("contacts, query a number", "dialer.contacts", {"version": 1, "requestId": R, "query": 98765}, "reject")
q("contacts, no request ID", "dialer.contacts", {"version": 1, "query": "Anna"}, "reject")
q("contacts, request ID not a UUID", "dialer.contacts", {"version": 1, "requestId": "abc", "query": "Anna"}, "reject")
q("contacts, version 2", "dialer.contacts", {"version": 2, "requestId": R, "query": "Anna"}, "reject")
q("contacts, duplicate key", "dialer.contacts", '{"version":1,"requestId":"%s","query":"Anna","query":"Bob"}' % R, "reject", raw=True)
q("contacts, over 1 KiB", "dialer.contacts", sized('{"version":1,"requestId":"%s","query":"a","pad":"' % R, 1025), "reject", raw=True)
# dialer.recents
q("recents, 20", "dialer.recents", {"version": 1, "requestId": R, "limit": 20}, {"requestId": R, "limit": 20})
q("recents, 1", "dialer.recents", {"version": 1, "requestId": R, "limit": 1}, {"requestId": R, "limit": 1})
q("recents, 50", "dialer.recents", {"version": 1, "requestId": R, "limit": 50}, {"requestId": R, "limit": 50})
q("recents, limit written as 20.0", "dialer.recents", '{"version":1,"requestId":"%s","limit":20.0}' % R, {"requestId": R, "limit": 20}, raw=True)
q("recents, 0", "dialer.recents", {"version": 1, "requestId": R, "limit": 0}, "reject")
q("recents, 51", "dialer.recents", {"version": 1, "requestId": R, "limit": 51}, "reject")
q("recents, limit a string", "dialer.recents", {"version": 1, "requestId": R, "limit": "20"}, "reject")
q("recents, no limit", "dialer.recents", {"version": 1, "requestId": R}, "reject")
# dialer.call
call = lambda **kw: {"requestId": R, "via": "phone", "address": None, "subId": None, "dataId": None, **kw}
q("call, a number", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "+91 98765 43210"}, call(address="+919876543210"))
q("call, a number on SIM 2", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "(022) 4000-1234", "subId": 2},
  call(address="02240001234", subId=2))
q("call, subId 0", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "100200", "subId": 0}, call(address="100200", subId=0))
q("call, null subId is absent", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "100200", "subId": None}, call(address="100200"))
q("call, dots are removed", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "555.123.4567"}, call(address="5551234567"))
q("call, 3 digits", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "123"}, call(address="123"))
q("call, 15 digits", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "+123456789012345"}, call(address="+123456789012345"))
q("call, 2 digits", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "12"}, "reject")
q("call, 16 digits", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "1234567890123456"}, "reject")
q("call, USSD code", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "*#06#"}, "reject")
q("call, extension", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "5551234,22"}, "reject")
q("call, letters", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "1-800-FLOWERS"}, "reject")
q("call, plus in the middle", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "91+98765"}, "reject")
q("call, no address", "dialer.call", {"version": 1, "requestId": R, "via": "phone"}, "reject")
q("call, phone with a dataId", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "100200", "dataId": 5}, "reject")
q("call, negative subId", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "100200", "subId": -1}, "reject")
q("call, subId too large", "dialer.call", {"version": 1, "requestId": R, "via": "phone", "address": "100200", "subId": 2147483648}, "reject")
q("call, WhatsApp voice", "dialer.call", {"version": 1, "requestId": R, "via": "whatsapp_voice", "dataId": 4211}, call(via="whatsapp_voice", dataId=4211))
q("call, WhatsApp video", "dialer.call", {"version": 1, "requestId": R, "via": "whatsapp_video", "dataId": 4212}, call(via="whatsapp_video", dataId=4212))
q("call, WhatsApp with a number", "dialer.call", {"version": 1, "requestId": R, "via": "whatsapp_voice", "dataId": 4211, "address": "100200"}, "reject")
q("call, WhatsApp with a SIM", "dialer.call", {"version": 1, "requestId": R, "via": "whatsapp_video", "dataId": 4211, "subId": 1}, "reject")
q("call, WhatsApp without a dataId", "dialer.call", {"version": 1, "requestId": R, "via": "whatsapp_voice"}, "reject")
q("call, dataId 0", "dialer.call", {"version": 1, "requestId": R, "via": "whatsapp_voice", "dataId": 0}, "reject")
q("call, dataId a string", "dialer.call", {"version": 1, "requestId": R, "via": "whatsapp_voice", "dataId": "4211"}, "reject")
q("call, unknown via", "dialer.call", {"version": 1, "requestId": R, "via": "telegram", "dataId": 1}, "reject")
q("call, no via", "dialer.call", {"version": 1, "requestId": R, "address": "100200"}, "reject")
q("call, version 2", "dialer.call", {"version": 2, "requestId": R, "via": "phone", "address": "100200"}, "reject")
q("call, not JSON", "dialer.call", "call 100200", "reject", raw=True)

# dialer.status
SIM1, SIM2 = {"subId": 1, "slot": 0, "label": "Jio"}, {"subId": 2, "slot": 1, "label": "Airtel"}
st = lambda **kw: {"place": True, "confirm": False, "contacts": "on", "recents": "on", "whatsapp": True, "sims": [], **kw}
add(status, "everything allowed, two SIMs", {"version": 1, "place": True, "confirm": False, "contacts": "on", "recents": "on", "whatsapp": True, "sims": [SIM1, SIM2]},
    st(sims=[SIM1, SIM2]), android=True)
add(status, "nothing allowed yet", {"version": 1, "place": False, "confirm": False, "contacts": "off", "recents": "off", "whatsapp": False, "sims": []},
    st(place=False, contacts="off", recents="off", whatsapp=False), android=True)
add(status, "Play build", {"version": 1, "place": True, "confirm": True, "contacts": "unavailable", "recents": "unavailable", "whatsapp": False, "sims": [SIM1]},
    st(confirm=True, contacts="unavailable", recents="unavailable", whatsapp=False, sims=[SIM1]), android=True)
add(status, "sims missing reads as none", {"version": 1, "place": True, "confirm": False, "contacts": "on", "recents": "on", "whatsapp": True}, st())
add(status, "unknown contacts value reads as off", {"version": 1, "place": True, "confirm": False, "contacts": "later", "recents": "on", "whatsapp": True, "sims": []},
    st(contacts="off"))
add(status, "invalid SIM entries are dropped", {"version": 1, "place": True, "confirm": False, "contacts": "on", "recents": "on", "whatsapp": True,
    "sims": [{"subId": "1", "slot": 0, "label": "x"}, {"subId": 3, "slot": 4, "label": "x"}, {"subId": 5, "slot": 1}, SIM2]}, st(sims=[SIM2]))
add(status, "more than 4 SIM entries", {"version": 1, "place": True, "confirm": False, "contacts": "on", "recents": "on", "whatsapp": True,
    "sims": [SIM1, SIM2, SIM1, SIM2, SIM1]}, "reject")
add(status, "place as a number", {"version": 1, "place": 1, "confirm": False, "contacts": "on", "recents": "on", "whatsapp": True}, "reject")
add(status, "contacts as a boolean", {"version": 1, "place": True, "confirm": False, "contacts": True, "recents": "on", "whatsapp": True}, "reject")
add(status, "no whatsapp", {"version": 1, "place": True, "confirm": False, "contacts": "on", "recents": "on"}, "reject")
add(status, "version 2", {"version": 2, "place": True, "confirm": False, "contacts": "on", "recents": "on", "whatsapp": True}, "reject")
add(status, "over 2 KiB", sized('{"version":1,"place":true,"confirm":false,"contacts":"on","recents":"on","whatsapp":true,"pad":"', 2049), "reject", raw=True)

# dialer.contacts_result
anna = {"id": 7, "name": "Anna Kapoor", "starred": True, "numbers": [{"address": "+91 98765 43210", "label": "Mobile"}, {"address": "+91 22 4000 1234", "label": "Work"}],
        "whatsapp": [{"address": "+919876543210", "voice": 4211, "video": 4212}]}
rohan = {"id": 9, "name": "Rohan", "numbers": [{"address": "100200"}]}
rohan_x = {"id": 9, "name": "Rohan", "starred": False, "numbers": [{"address": "100200", "label": None}], "whatsapp": []}
anna_x = anna
cr = lambda contacts, error=None: {"requestId": R, "contacts": contacts, "error": error}
add(contacts, "two contacts", {"version": 1, "requestId": R, "contacts": [anna, rohan]}, cr([anna_x, rohan_x]), android=True)
add(contacts, "no matches", {"version": 1, "requestId": R, "contacts": []}, cr([]), android=True)
add(contacts, "permission", {"version": 1, "requestId": R, "contacts": [], "error": "permission"}, cr([], "permission"), android=True)
add(contacts, "rate limited", {"version": 1, "requestId": R, "contacts": [], "error": "rate_limited"}, cr([], "rate_limited"), android=True)
add(contacts, "unknown error reads as unavailable", {"version": 1, "requestId": R, "contacts": [anna], "error": "busy"}, cr([], "unavailable"))
add(contacts, "WhatsApp only, video only", {"version": 1, "requestId": R, "contacts": [{"id": 3, "name": "Mahima", "numbers": [], "whatsapp": [{"address": "+919812345678", "video": 9}]}]},
    cr([{"id": 3, "name": "Mahima", "starred": False, "numbers": [], "whatsapp": [{"address": "+919812345678", "voice": None, "video": 9}]}]))
add(contacts, "a contact with nothing to call is dropped", {"version": 1, "requestId": R, "contacts": [{"id": 3, "name": "Nobody", "numbers": []}, rohan]}, cr([rohan_x]))
add(contacts, "a WhatsApp entry without voice or video drops the contact",
    {"version": 1, "requestId": R, "contacts": [{"id": 3, "name": "M", "numbers": [{"address": "1"}], "whatsapp": [{"address": "+1"}]}, rohan]}, cr([rohan_x]))
add(contacts, "id 0 is dropped", {"version": 1, "requestId": R, "contacts": [{**rohan, "id": 0}]}, cr([]))
add(contacts, "an empty name is dropped", {"version": 1, "requestId": R, "contacts": [{**rohan, "name": ""}]}, cr([]))
add(contacts, "a name of 129 units is dropped", {"version": 1, "requestId": R, "contacts": [{**rohan, "name": "n" * 129}]}, cr([]))
add(contacts, "an empty number is dropped with its contact", {"version": 1, "requestId": R, "contacts": [{**rohan, "numbers": [{"address": ""}]}]}, cr([]))
add(contacts, "9 numbers is dropped", {"version": 1, "requestId": R, "contacts": [{**rohan, "numbers": [{"address": str(100 + i)} for i in range(9)]}]}, cr([]))
add(contacts, "a label of 33 units is dropped", {"version": 1, "requestId": R, "contacts": [{**rohan, "numbers": [{"address": "1", "label": "l" * 33}]}]}, cr([]))
add(contacts, "21 contacts", {"version": 1, "requestId": R, "contacts": [{**rohan, "id": i + 1} for i in range(21)]}, "reject")
add(contacts, "contacts missing", {"version": 1, "requestId": R}, "reject")
add(contacts, "request ID not a UUID", {"version": 1, "requestId": "x", "contacts": []}, "reject")
add(contacts, "over 16 KiB", sized('{"version":1,"requestId":"%s","contacts":[],"pad":"' % R, 16385), "reject", raw=True)

# dialer.recents_result
c1 = {"id": 501, "address": "+919876543210", "name": "Anna Kapoor", "type": "outgoing", "date": 1763193600000, "duration": 184, "subId": 1}
c2 = {"id": 500, "address": "", "type": "missed", "date": 1763190000000, "duration": 0}
c1x = c1
c2x = {**c2, "name": None, "subId": None}
rr = lambda calls, error=None: {"requestId": R, "calls": calls, "error": error}
add(recents, "two calls", {"version": 1, "requestId": R, "calls": [c1, c2]}, rr([c1x, c2x]), android=True)
add(recents, "every type", {"version": 1, "requestId": R, "calls": [{**c2, "id": 10 + i, "type": t} for i, t in enumerate(["incoming", "outgoing", "missed", "rejected", "blocked", "voicemail"])]},
    rr([{**c2x, "id": 10 + i, "type": t} for i, t in enumerate(["incoming", "outgoing", "missed", "rejected", "blocked", "voicemail"])]), android=True)
add(recents, "an unknown type reads as incoming", {"version": 1, "requestId": R, "calls": [{**c2, "type": "answered_elsewhere"}]}, rr([{**c2x, "type": "incoming"}]))
add(recents, "permission", {"version": 1, "requestId": R, "calls": [], "error": "permission"}, rr([], "permission"), android=True)
add(recents, "unavailable", {"version": 1, "requestId": R, "calls": [], "error": "unavailable"}, rr([], "unavailable"), android=True)
add(recents, "a negative duration is dropped", {"version": 1, "requestId": R, "calls": [{**c2, "duration": -1}, c1]}, rr([c1x]))
add(recents, "a type that is not a string is dropped", {"version": 1, "requestId": R, "calls": [{**c2, "type": 3}]}, rr([]))
add(recents, "an address of 65 units is dropped", {"version": 1, "requestId": R, "calls": [{**c2, "address": "1" * 65}]}, rr([]))
add(recents, "a missing address is dropped", {"version": 1, "requestId": R, "calls": [{k: v for k, v in c2.items() if k != "address"}]}, rr([]))
add(recents, "51 calls", {"version": 1, "requestId": R, "calls": [{**c2, "id": i + 1} for i in range(51)]}, "reject")
add(recents, "calls missing", {"version": 1, "requestId": R}, "reject")
add(recents, "over 40 KiB", sized('{"version":1,"requestId":"%s","calls":[],"pad":"' % R, 40961), "reject", raw=True)

# dialer.call_result
res = lambda r, reason=None: {"requestId": R, "result": r, "reason": reason}
add(result, "started", {"version": 1, "requestId": R, "result": "started"}, res("started"), android=True)
add(result, "confirm on the phone", {"version": 1, "requestId": R, "result": "confirm"}, res("confirm"), android=True)
for reason in ["disabled", "permission", "invalid", "emergency", "no_sim", "rate_limited", "not_found", "unavailable", "failed"]:
    add(result, "refused " + reason, {"version": 1, "requestId": R, "result": "refused", "reason": reason}, res("refused", reason), android=True)
add(result, "an unknown reason reads as failed", {"version": 1, "requestId": R, "result": "refused", "reason": "busy"}, res("refused", "failed"))
add(result, "a missing reason reads as failed", {"version": 1, "requestId": R, "result": "refused"}, res("refused", "failed"))
add(result, "a reason with started is ignored", {"version": 1, "requestId": R, "result": "started", "reason": "failed"}, res("started"))
add(result, "an unknown result reads as refused", {"version": 1, "requestId": R, "result": "ringing"}, res("refused", "failed"))
add(result, "result a number", {"version": 1, "requestId": R, "result": 1}, "reject")
add(result, "upper-case request ID", {"version": 1, "requestId": R.upper(), "result": "started"}, res("started"))
add(result, "no request ID", {"version": 1, "result": "started"}, "reject")
add(result, "over 1 KiB", sized('{"version":1,"requestId":"%s","result":"started","pad":"' % R, 1025), "reject", raw=True)

out = {
    "format": "bridgey.dialer.v1",
    "description": __doc__.strip().split("\n\n")[1],
    "request": request,
    "status": status,
    "contacts": contacts,
    "recents": recents,
    "callResult": result,
}
if __name__ == "__main__":
    OUT.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(len(request), len(status), len(contacts), len(recents), len(result))
