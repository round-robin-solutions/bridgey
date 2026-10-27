#!/usr/bin/env python3
"""Writes protocol/test-vectors/protocol-v1.json, the golden vectors both platforms decode. Edit here, then run it."""
import json, base64, hashlib
import pathlib
OUT = pathlib.Path(__file__).resolve().parents[1] / "test-vectors" / "protocol-v1.json"
S = "4f1c2a9e-6b3d-4c8e-9a1f-2d3e4f5a6b7c"
M = "0d9c8b7a-6f5e-4d3c-2b1a-0f9e8d7c6b5a"
frames = []
def f(name, line, expect, **kw):
    v = {"name": name}
    v.update(kw)
    if line is not None: v["line"] = line
    v["expect"] = expect
    frames.append(v)
j = lambda o: json.dumps(o, separators=(",", ":"), ensure_ascii=False)
f("pairing.cancel", j({"kind":"pairing.cancel","sessionId":S}), {"kind":"pairing.cancel","sessionId":S})
f("pairing.cancel before the session ID is known", j({"kind":"pairing.cancel","sessionId":""}), {"kind":"pairing.cancel","sessionId":""})
f("empty sessionId outside pairing.cancel", j({"kind":"heartbeat.ping","sessionId":"","messageId":M}), "reject")
f("pairing.offer with every field", j({"kind":"pairing.offer","sessionId":S,"deviceId":"7e57d00d-0000-4000-8000-000000000001","deviceName":"Test Mac","publicKey":"BAAA","targetDeviceId":"7e57d00d-0000-4000-8000-000000000002"}),
  {"kind":"pairing.offer","sessionId":S,"deviceId":"7e57d00d-0000-4000-8000-000000000001","deviceName":"Test Mac","publicKey":"BAAA","targetDeviceId":"7e57d00d-0000-4000-8000-000000000002"})
f("pairing.confirm", j({"kind":"pairing.confirm","sessionId":S,"deviceId":"d","identityKey":"ik","proof":"pr","signature":"sg"}),
  {"kind":"pairing.confirm","sessionId":S,"deviceId":"d","identityKey":"ik","proof":"pr","signature":"sg"})
f("files.chunk", j({"kind":"files.chunk","sessionId":S,"transferId":"t1","sequence":0,"nonce":"bm9uY2U=","ciphertext":"Y2lwaGVy"}),
  {"kind":"files.chunk","sessionId":S,"transferId":"t1","sequence":0,"nonce":"bm9uY2U=","ciphertext":"Y2lwaGVy"})
f("unknown kind decodes (dispatch ignores it)", j({"kind":"future.thing","sessionId":S,"messageId":M,"shiny":{"a":[1,2,{"b":None}]}}), {"kind":"future.thing","sessionId":S,"messageId":M})
f("unknown fields are ignored", j({"kind":"ping.ack","sessionId":S,"messageId":M,"extra":"x","n":5,"flag":True}), {"kind":"ping.ack","sessionId":S,"messageId":M})
f("empty optional string counts as absent", j({"kind":"ping.ack","sessionId":S,"messageId":"","transferId":""}), {"kind":"ping.ack","sessionId":S})
f("null optional counts as absent", j({"kind":"ping.ack","sessionId":S,"messageId":None,"sequence":None}), {"kind":"ping.ack","sessionId":S})
f("kind missing", j({"sessionId":S}), "reject")
f("sessionId missing", j({"kind":"ping.ack"}), "reject")
f("kind is a number", j({"kind":5,"sessionId":S}), "reject")
f("kind is empty", j({"kind":"","sessionId":S}), "reject")
f("kind of 64 bytes", j({"kind":"k."+"a"*62,"sessionId":S}), {"kind":"k."+"a"*62,"sessionId":S})
f("kind of 65 bytes", j({"kind":"k."+"a"*63,"sessionId":S}), "reject")
f("sessionId of 128 bytes", j({"kind":"ping.ack","sessionId":"s"*128}), {"kind":"ping.ack","sessionId":"s"*128})
f("sessionId of 129 bytes", j({"kind":"ping.ack","sessionId":"s"*129}), "reject")
f("multi-byte kind counts bytes", j({"kind":"k."+"é"*31,"sessionId":S}), {"kind":"k."+"é"*31,"sessionId":S})
f("multi-byte kind over 64 bytes", j({"kind":"k."+"é"*32,"sessionId":S}), "reject")
f("messageId is a number", j({"kind":"ping.ack","sessionId":S,"messageId":7}), "reject")
f("deviceName is an object", j({"kind":"pairing.offer","sessionId":S,"deviceName":{"a":1}}), "reject")
f("sequence is a string", j({"kind":"files.chunk","sessionId":S,"sequence":"3"}), "reject")
f("sequence is a fraction", '{"kind":"files.chunk","sessionId":"%s","sequence":1.5}' % S, "reject")
f("sequence is a boolean", j({"kind":"files.chunk","sessionId":S,"sequence":True}), "reject")
f("sequence written as 1.0", '{"kind":"files.chunk","sessionId":"%s","sequence":1.0}' % S, {"kind":"files.chunk","sessionId":S,"sequence":1})
f("sequence written as 1e2", '{"kind":"files.chunk","sessionId":"%s","sequence":1e2}' % S, {"kind":"files.chunk","sessionId":S,"sequence":100})
f("sequence 2^53-1", j({"kind":"files.chunk","sessionId":S,"sequence":9007199254740991}), {"kind":"files.chunk","sessionId":S,"sequence":9007199254740991})
f("sequence 2^53", j({"kind":"files.chunk","sessionId":S,"sequence":9007199254740992}), "reject")
f("negative sequence decodes (each kind checks its range)", j({"kind":"files.chunk","sessionId":S,"sequence":-1}), {"kind":"files.chunk","sessionId":S,"sequence":-1})
f("top level array", j([{"kind":"ping.ack","sessionId":S}]), "reject")
f("top level string", j("ping.ack"), "reject")
f("empty line", "", "reject")
f("whitespace only", "   ", "reject")
f("trailing garbage", j({"kind":"ping.ack","sessionId":S}) + " x", "reject")
f("two objects on one line", j({"kind":"ping.ack","sessionId":S}) * 2, "reject")
f("trailing whitespace", j({"kind":"ping.ack","sessionId":S}) + " \t ", {"kind":"ping.ack","sessionId":S})
f("single quotes", "{'kind':'ping.ack','sessionId':'%s'}" % S, "reject")
f("unquoted names", "{kind:\"ping.ack\",sessionId:\"%s\"}" % S, "reject")
f("comment", "{\"kind\":\"ping.ack\",/* c */\"sessionId\":\"%s\"}" % S, "reject")
f("trailing comma", "{\"kind\":\"ping.ack\",\"sessionId\":\"%s\",}" % S, "reject")
f("truncated", j({"kind":"ping.ack","sessionId":S})[:-1], "reject")
f("leading zero number", "{\"kind\":\"ping.ack\",\"sessionId\":\"%s\",\"n\":01}" % S, "reject")
f("escaped unicode", '{"kind":"pairing.offer","sessionId":"%s","deviceName":"Caf\\u00e9 \\ud83d\\ude00"}' % S, {"kind":"pairing.offer","sessionId":S,"deviceName":"Café \U0001F600"})
f("lone surrogate escape", '{"kind":"pairing.offer","sessionId":"%s","deviceName":"x\\ud800"}' % S, "reject")
f("depth 32", None, {"kind":"x.y","sessionId":S}, nest=32)
f("depth 33", None, "reject", nest=33)
f("depth 3000 does not overflow the stack", None, "reject", nest=3000)
f("invalid UTF-8", None, "reject", lineBase64=base64.b64encode(b'{"kind":"ping.ack","sessionId":"\xc3\x28"}').decode())
f("frame of exactly 65,536 bytes", None, {"kind":"pairing.offer","sessionId":S,"deviceName":"@PAD@"}, padTo=65536)
f("frame of 65,537 bytes", None, "reject", padTo=65537)
f("CRLF line ending", j({"kind":"ping.ack","sessionId":S}), {"kind":"ping.ack","sessionId":S}, lineEnding="\r\n")
f("frame of 65,536 bytes with CRLF", None, {"kind":"pairing.offer","sessionId":S,"deviceName":"@PAD@"}, padTo=65536, lineEnding="\r\n")

features_all = {"clipboard":True,"files":True,"notifications":True,"battery":True,"find_device":True,"ping":True,"links":True,"media":True,"calls":True,"remote_input_draft1":False}
drafts_none = {"clipboard_files_draft1":False,"folders_draft1":False,"places_draft1":False,"sms_codes_draft1":False,"folders_receive_draft1":False,"files_browse_draft1":False,
               "mac_actions_draft1":False,"links_open_draft1":False,"focus_sync_draft1":False,"camera_draft1":False,
               "updates_draft1":False,"settings_sync_draft1":False}
feat = []
def fe(name, plaintext, expect, raw=False):
    feat.append({"name": name, ("plaintextString" if raw else "plaintext"): plaintext, "expect": expect})
fe("edition Mac", {"version":1,"features":{**features_all,"clipboard_files_draft1":True,"folders_draft1":True,"places_draft1":False,"sms_codes_draft1":True,"folders_receive_draft1":True,"files_browse_draft1":False}},
   {"features":features_all,"drafts":{**drafts_none,"clipboard_files_draft1":True,"folders_draft1":True,"places_draft1":False,"sms_codes_draft1":True,"folders_receive_draft1":True,"files_browse_draft1":False}})
fe("edition phone serving Files 2.0 browsing", {"version":1,"features":{**features_all,"clipboard_files_draft1":True,"folders_draft1":True,"places_draft1":True,"sms_codes_draft1":True,"folders_receive_draft1":True,"files_browse_draft1":True}},
   {"features":features_all,"drafts":{**drafts_none,"clipboard_files_draft1":True,"folders_draft1":True,"places_draft1":True,"sms_codes_draft1":True,"folders_receive_draft1":True,"files_browse_draft1":True}})
# Automation (v0.9): mac_actions_draft1 and camera_draft1 are switches in the apps but draft keys on the wire, pinned under drafts.
automation_mac = {"mac_actions_draft1":True,"links_open_draft1":True,"focus_sync_draft1":True,"camera_draft1":True}
fe("v0.9 Mac with Mac actions granted, links open, Focus and camera", {"version":1,"features":{**features_all,"clipboard_files_draft1":True,"folders_draft1":True,"sms_codes_draft1":True,"folders_receive_draft1":True,**automation_mac}},
   {"features":features_all,"drafts":{**drafts_none,"clipboard_files_draft1":True,"folders_draft1":True,"sms_codes_draft1":True,"folders_receive_draft1":True,**automation_mac}})
fe("v0.9 phone (Mac actions and camera on, Focus off, no links open)", {"version":1,"features":{**features_all,"files_browse_draft1":True,"mac_actions_draft1":True,"focus_sync_draft1":False,"camera_draft1":True}},
   {"features":features_all,"drafts":{**drafts_none,"files_browse_draft1":True,"mac_actions_draft1":True,"camera_draft1":True}})
fe("automation keys that are not booleans count as false", {"version":1,"features":{**features_all,"mac_actions_draft1":1,"links_open_draft1":"true","focus_sync_draft1":None,"camera_draft1":{"on":True}}},
   {"features":features_all,"drafts":drafts_none})
# Update all: updates_draft1 is advertised by every edition build that has it, whatever its remote start switch says.
fe("Update all: an edition phone with updates_draft1", {"version":1,"features":{**features_all,"files_browse_draft1":True,"updates_draft1":True}},
   {"features":features_all,"drafts":{**drafts_none,"files_browse_draft1":True,"updates_draft1":True}})
fe("updates_draft1 that is not a boolean counts as false", {"version":1,"features":{**features_all,"updates_draft1":"true"}},
   {"features":features_all,"drafts":drafts_none})
# Settings sync (v0.10): settings_sync_draft1 is a draft key on both sides, true only for JSON true.
fe("v0.10 device with settings sync on", {"version":1,"features":{**features_all,"settings_sync_draft1":True}},
   {"features":features_all,"drafts":{**drafts_none,"settings_sync_draft1":True}})
fe("settings sync key that is not a boolean counts as false", {"version":1,"features":{**features_all,"settings_sync_draft1":"true"}},
   {"features":features_all,"drafts":drafts_none})
fe("v0.10 device with Update all and settings sync", {"version":1,"features":{**features_all,"updates_draft1":True,"settings_sync_draft1":True}},
   {"features":features_all,"drafts":{**drafts_none,"updates_draft1":True,"settings_sync_draft1":True}})
fe("first-slice Mac (folders_draft1 only, no Files 2.0 keys)", {"version":1,"features":{**features_all,"folders_draft1":True,"places_draft1":False}},
   {"features":features_all,"drafts":{**drafts_none,"folders_draft1":True}})
legacy = {"clipboard":True,"files":False,"notifications":True,"battery":True,"find_device":False}
fe("upstream 0.5 peer (original keys only)", {"version":1,"features":legacy},
   {"features":{**legacy,"ping":False,"links":False,"media":False,"calls":False,"remote_input_draft1":False},"drafts":drafts_none})
fe("unknown keys are ignored, even non-boolean", {"version":1,"features":{**legacy,"future_key":"yes","other":{"a":1}}},
   {"features":{**legacy,"ping":False,"links":False,"media":False,"calls":False,"remote_input_draft1":False},"drafts":drafts_none})
fe("draft key that is not a boolean counts as false", {"version":1,"features":{**legacy,"sms_codes_draft1":1}},
   {"features":{**legacy,"ping":False,"links":False,"media":False,"calls":False,"remote_input_draft1":False},"drafts":drafts_none})
fe("missing original key closes", {"version":1,"features":{"clipboard":True,"files":True,"notifications":True,"battery":True}}, "invalid")
fe("non-boolean known key closes", {"version":1,"features":{**legacy,"ping":"true"}}, "invalid")
fe("null known key closes", {"version":1,"features":{**legacy,"clipboard":None}}, "invalid")
fe("features is not an object", {"version":1,"features":[True]}, "invalid")
fe("no features", {"version":1}, "invalid")
fe("unknown version keeps the previous state", {"version":2,"features":legacy}, "ignored")
fe("missing version keeps the previous state", {"features":legacy}, "ignored")
fe("not JSON closes", "features", "invalid", raw=True)
fe("lenient JSON closes", "{version:1,features:{clipboard:true}}", "invalid", raw=True)

batt = []
def b(name, p, expect, raw=False): batt.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
b("charging", {"level":79,"isCharging":True}, {"level":79,"isCharging":True})
b("empty", {"level":0,"isCharging":False}, {"level":0,"isCharging":False})
b("full", {"level":100,"isCharging":False}, {"level":100,"isCharging":False})
b("extra fields", {"level":50,"isCharging":False,"temperature":30}, {"level":50,"isCharging":False})
b("level 101", {"level":101,"isCharging":False}, "reject")
b("level -1", {"level":-1,"isCharging":False}, "reject")
b("level as a string", {"level":"50","isCharging":False}, "reject")
b("level as a fraction", '{"level":50.5,"isCharging":false}', "reject", raw=True)
b("isCharging as a number", {"level":50,"isCharging":1}, "reject")
b("isCharging missing", {"level":50}, "reject")
b("level missing", {"isCharging":True}, "reject")
b("not an object", [50, True], "reject")

rich = []
def r(name, p, expect, raw=False): rich.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
r("text and html", {"version":1,"text":"example","html":"<p><strong>example</strong></p>"}, {"text":"example","html":"<p><strong>example</strong></p>"})
r("unicode", {"version":1,"text":"привет","html":"<b>привет</b>"}, {"text":"привет","html":"<b>привет</b>"})
r("exactly 32 KiB together", {"version":1,"text":"t"*16384,"html":"h"*16384}, {"text":"t"*16384,"html":"h"*16384})
r("over 32 KiB together", {"version":1,"text":"t"*16384,"html":"h"*16385}, "reject")
r("empty text", {"version":1,"text":"","html":"<p>x</p>"}, "reject")
r("blank html", {"version":1,"text":"x","html":"  \n "}, "reject")
r("html missing", {"version":1,"text":"x"}, "reject")
r("version 2", {"version":2,"text":"x","html":"<p>x</p>"}, "reject")
r("version as a string", {"version":"1","text":"x","html":"<p>x</p>"}, "reject")
r("text as a number", {"version":1,"text":5,"html":"<p>x</p>"}, "reject")
r("not JSON", "<p>x</p>", "reject", raw=True)

png = bytes(range(64))
sha = base64.b64encode(hashlib.sha256(png).digest()).decode()
sha_other = base64.b64encode(hashlib.sha256(b"other").digest()).decode()
O = "5b1f3a5e-7d0c-4f6e-9a51-0c2f6f7d1e0b"
offers = []
def o(name, p, expect, raw=False): offers.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
o("image and file", {"version":1,"offerId":O,"createdAt":1786550000000,"sensitive":False,"items":[
    {"index":0,"kind":"image","mime":"image/png","size":2202009,"sha256":sha},
    {"index":1,"kind":"file","mime":"video/mp4","name":"video.mp4","size":356515840}]},
  {"offerId":O,"createdAt":1786550000000,"sensitive":False,"items":[
    {"index":0,"kind":"image","mime":"image/png","name":None,"size":2202009,"sha256":sha,"inlineBytes":None},
    {"index":1,"kind":"file","mime":"video/mp4","name":"video.mp4","size":356515840,"sha256":None,"inlineBytes":None}]})
o("text with html, sensitive", {"version":1,"offerId":O,"createdAt":0,"sensitive":True,"items":[
    {"index":0,"kind":"text","mime":"text/plain","size":300000},{"index":1,"kind":"html","mime":"text/html","size":400000}]},
  {"offerId":O,"createdAt":0,"sensitive":True,"items":[
    {"index":0,"kind":"text","mime":"text/plain","name":None,"size":300000,"sha256":None,"inlineBytes":None},
    {"index":1,"kind":"html","mime":"text/html","name":None,"size":400000,"sha256":None,"inlineBytes":None}]})
o("inline item", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"image","mime":"image/png","size":64,"sha256":sha,"inline":base64.b64encode(png).decode()}]},
  {"offerId":O,"createdAt":5,"sensitive":False,"items":[{"index":0,"kind":"image","mime":"image/png","name":None,"size":64,"sha256":sha,"inlineBytes":64}]})
o("file name keeps only the last component", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"file","mime":"application/pdf","name":"../../etc/passwd.pdf","size":10}]},
  {"offerId":O,"createdAt":5,"sensitive":False,"items":[{"index":0,"kind":"file","mime":"application/pdf","name":"passwd.pdf","size":10,"sha256":None,"inlineBytes":None}]})
o("inline that does not match its hash", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"image","mime":"image/png","size":64,"sha256":sha_other,"inline":base64.b64encode(png).decode()}]}, "reject")
o("inline without a hash", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"image","mime":"image/png","size":64,"inline":base64.b64encode(png).decode()}]}, "reject")
o("mixed text and file", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"text","mime":"text/plain","size":1},{"index":1,"kind":"file","mime":"a/b","name":"x","size":1}]}, "reject")
o("html without text", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"html","mime":"text/html","size":1}]}, "reject")
o("unknown item kind", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"sticker","mime":"image/png","size":1}]}, "reject")
o("index out of order", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":1,"kind":"image","mime":"image/png","size":1}]}, "reject")
o("no items", {"version":1,"offerId":O,"createdAt":5,"items":[]}, "reject")
o("101 items", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":i,"kind":"image","mime":"image/png","size":1} for i in range(101)]}, "reject")
o("100 items", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":i,"kind":"image","mime":"image/png","size":1} for i in range(100)]},
  {"offerId":O,"createdAt":5,"sensitive":False,"items":[{"index":i,"kind":"image","mime":"image/png","name":None,"size":1,"sha256":None,"inlineBytes":None} for i in range(100)]})
o("size over 10 GiB", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"file","mime":"a/b","name":"x","size":10737418241}]}, "reject")
o("negative size", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"image","mime":"image/png","size":-1}]}, "reject")
o("negative createdAt", {"version":1,"offerId":O,"createdAt":-5,"items":[{"index":0,"kind":"image","mime":"image/png","size":1}]}, "reject")
o("offerId not a UUID", {"version":1,"offerId":"not-a-uuid","createdAt":5,"items":[{"index":0,"kind":"image","mime":"image/png","size":1}]}, "reject")
o("file without a name", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"file","mime":"a/b","size":1}]}, "reject")
o("mime without a slash", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"image","mime":"imagepng","size":1}]}, "reject")
o("short hash", {"version":1,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"image","mime":"image/png","size":1,"sha256":"AAAA"}]}, "reject")
o("version 2", {"version":2,"offerId":O,"createdAt":5,"items":[{"index":0,"kind":"image","mime":"image/png","size":1}]}, "reject")
o("over 40,960 bytes", "{\"version\":1,\"offerId\":\"%s\",\"createdAt\":5,\"pad\":\"%s\",\"items\":[{\"index\":0,\"kind\":\"image\",\"mime\":\"image/png\",\"size\":1}]}" % (O, "x"*41000), "reject", raw=True)

IS = "c0ffee00-1234-4abc-8def-0123456789ab"
inp = []
def i(name, kind, fields, expect, android=None):
    p = {"version":1,"inputSessionId":IS,"sequence":7}; p.update(fields)
    v = {"name":name,"kind":kind,"plaintext":p,"expect":expect}
    if android: v["android"] = android
    inp.append(v)
i("start touchpad", "input.session.start", {"mode":"touchpad"}, {"command":"start","mode":"touchpad"}, {"type":"Start","mode":"touchpad"})
i("heartbeat", "input.session.heartbeat", {}, {"command":"heartbeat"}, {"type":"Heartbeat"})
i("stop by the user", "input.session.stop", {"reason":"user"}, {"command":"stop","reason":"user"}, {"type":"Stop","reason":"user"})
i("pointer", "input.pointer", {"dx":5,"dy":-3}, {"command":"pointer","dx":5,"dy":-3}, {"type":"Pointer","dx":5,"dy":-3})
i("pointer at the limit", "input.pointer", {"dx":512,"dy":-512}, {"command":"pointer","dx":512,"dy":-512}, {"type":"Pointer","dx":512,"dy":-512})
i("pointer over the limit", "input.pointer", {"dx":513,"dy":0}, "reject", {"type":"Pointer","dx":513,"dy":0})
i("pointer that does not move", "input.pointer", {"dx":0,"dy":0}, "reject", {"type":"Pointer","dx":0,"dy":0})
i("left button down", "input.button", {"button":"left","action":"down"}, {"command":"button","button":"left","down":True}, {"type":"Button","button":"left","down":True})
i("pixel scroll", "input.scroll", {"dx":0,"dy":-40,"unit":"pixel"}, {"command":"scroll","dx":0,"dy":-40,"unit":"pixel"}, {"type":"Scroll","dx":0,"dy":-40,"unit":"pixel"})
i("line scroll over the limit", "input.scroll", {"dx":0,"dy":11,"unit":"line"}, "reject", {"type":"Scroll","dx":0,"dy":11,"unit":"line"})
i("drag start", "input.drag", {"phase":"start"}, {"command":"dragStart"}, {"type":"DragStart"})
i("drag move", "input.drag", {"phase":"move","dx":1,"dy":2}, {"command":"dragMove","dx":1,"dy":2}, {"type":"DragMove","dx":1,"dy":2})
i("drag end", "input.drag", {"phase":"end"}, {"command":"dragEnd"}, {"type":"DragEnd"})
i("text", "input.text", {"text":"Hello, мир \U0001F600"}, {"command":"text","text":"Hello, мир \U0001F600"}, {"type":"Text","text":"Hello, мир \U0001F600"})
i("text of 256 scalars", "input.text", {"text":"a"*256}, {"command":"text","text":"a"*256}, {"type":"Text","text":"a"*256})
i("text of 257 scalars", "input.text", {"text":"a"*257}, "reject", {"type":"Text","text":"a"*257})
i("text with a control character", "input.text", {"text":"a\u0007b"}, "reject", {"type":"Text","text":"a\u0007b"})
i("empty text", "input.text", {"text":""}, "reject", {"type":"Text","text":""})
i("key with shift", "input.key", {"key":"tab","modifiers":["shift"]}, {"command":"key","key":"tab","shift":True}, {"type":"Key","key":"tab","shift":True})
i("previous app", "input.key", {"key":"previous_app"}, {"command":"key","key":"previous_app","shift":False}, {"type":"Key","key":"previous_app","shift":False})
i("previous app with shift", "input.key", {"key":"previous_app","modifiers":["shift"]}, "reject", {"type":"Key","key":"previous_app","shift":True})
i("laser on", "input.present", {"action":"laser_on","x":5000,"y":10000}, {"command":"present","action":"laser_on","x":5000,"y":10000}, {"type":"Present","action":"laser_on","x":5000,"y":10000})
i("laser outside the screen", "input.present", {"action":"laser_move","x":10001,"y":0}, "reject", {"type":"Present","action":"laser_move","x":10001,"y":0})
i("next slide", "input.present", {"action":"next"}, {"command":"present","action":"next"}, {"type":"Present","action":"next"})
# Host only (no Android encoding): what a hostile controller could send.
i("command modifier", "input.key", {"key":"tab","modifiers":["command"]}, "reject")
i("unknown key", "input.key", {"key":"power"}, "reject")
i("unknown button", "input.button", {"button":"back","action":"down"}, "reject")
i("sequence 0", "input.pointer", {"dx":1,"dy":1,"sequence":0}, "reject")
i("session ID not a UUID", "input.pointer", {"dx":1,"dy":1,"inputSessionId":"x"}, "reject")
i("version 2", "input.pointer", {"dx":1,"dy":1,"version":2}, "reject")

# Files 2.0 browse refs (docs/protocol.md "References"): the Mac reads them from media.page and the phone from
# every browse request, so both must accept exactly the same refs. Hidden names parse; resolution refuses them.
PL = "AbCdEfGhIjKlMnOpQrStUv"
refs = []
def ref(name, p, expect, raw=False): refs.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
ref("media ID", {"mediaId":"1234"}, {"mediaId":"1234"})
ref("media ID 0", {"mediaId":"0"}, {"mediaId":"0"})
ref("largest media ID (2^63-1)", {"mediaId":"9223372036854775807"}, {"mediaId":"9223372036854775807"})
ref("media ID over 2^63-1", {"mediaId":"9223372036854775808"}, "reject")
ref("media ID of 21 digits", {"mediaId":"1"*21}, "reject")
ref("media ID empty", {"mediaId":""}, "reject")
ref("media ID negative", {"mediaId":"-1"}, "reject")
ref("media ID with letters", {"mediaId":"12a"}, "reject")
ref("media ID with non-ASCII digits", {"mediaId":"١٢"}, "reject")
ref("media ID as a number", {"mediaId":1234}, "reject")
ref("media ID and a place together", {"mediaId":"5","placeId":"default","path":"","name":"a.jpg"}, "reject")
ref("unknown fields are ignored", {"mediaId":"5","future":True}, {"mediaId":"5"})
ref("default place, top level", {"placeId":"default","path":"","name":"a.jpg"}, {"placeId":"default","path":"","name":"a.jpg"})
ref("granted place, nested path", {"placeId":PL,"path":"DCIM/Camera","name":"IMG_0001.jpg"}, {"placeId":PL,"path":"DCIM/Camera","name":"IMG_0001.jpg"})
ref("unicode name", {"placeId":PL,"path":"Документы","name":"Счёт №1.pdf"}, {"placeId":PL,"path":"Документы","name":"Счёт №1.pdf"})
ref("hidden name parses", {"placeId":"default","path":"","name":".nomedia"}, {"placeId":"default","path":"","name":".nomedia"})
ref("name of 255 bytes", {"placeId":"default","path":"","name":"n"*255}, {"placeId":"default","path":"","name":"n"*255})
ref("name of 256 bytes", {"placeId":"default","path":"","name":"n"*256}, "reject")
ref("place ID of 21 characters", {"placeId":PL[:21],"path":"","name":"a"}, "reject")
ref("place ID with a slash", {"placeId":PL[:21]+"/","path":"","name":"a"}, "reject")
ref("name missing", {"placeId":"default","path":""}, "reject")
ref("path missing", {"placeId":"default","name":"a"}, "reject")
ref("empty name", {"placeId":"default","path":"","name":""}, "reject")
ref("name with a slash", {"placeId":"default","path":"","name":"a/b"}, "reject")
ref("name ..", {"placeId":"default","path":"","name":".."}, "reject")
ref("name with a control character", {"placeId":"default","path":"","name":"ab"}, "reject")
ref("name with DEL", {"placeId":"default","path":"","name":"ab"}, "reject")
ref("path with ..", {"placeId":"default","path":"a/../b","name":"c"}, "reject")
ref("path with an empty component", {"placeId":"default","path":"a//b","name":"c"}, "reject")
ref("absolute path", {"placeId":"default","path":"/a","name":"c"}, "reject")
ref("path of 32 components", {"placeId":"default","path":"/".join(["d"]*32),"name":"c"}, {"placeId":"default","path":"/".join(["d"]*32),"name":"c"})
ref("path of 33 components", {"placeId":"default","path":"/".join(["d"]*33),"name":"c"}, "reject")
ref("path of 1,025 bytes", {"placeId":"default","path":"/".join(["d"*200]*5)+"/"+"d"*20,"name":"c"}, "reject")
ref("path as a number", {"placeId":"default","path":5,"name":"c"}, "reject")
ref("not an object", ["default","","a"], "reject")

# Automation (v0.9, docs/protocol.md "Mac actions", "Focus and Do Not Disturb sync", "Phone camera to Mac"). Each group is
# decoded by the receiving platform; vectors marked "android" or "mac" are also what that sending platform writes.
def sized(prefix, total, suffix='"}'):
    """A JSON object text of exactly `total` bytes: prefix + padding + suffix (prefix ends inside a "pad" string)."""
    return prefix + "x" * (total - len(prefix.encode()) - len(suffix)) + suffix

R1 = "8a5d9c3e-2b47-4f1a-9e60-7c1d2b3a4f5e"
SH = "3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b"
focus = []
def fs(name, p, expect, raw=False): focus.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
fs("active", {"version":1,"active":True}, {"active":True})
fs("not active", {"version":1,"active":False}, {"active":False})
fs("unknown fields are ignored", {"version":1,"active":True,"source":"filter","since":5}, {"active":True})
fs("version written as 1.0", '{"version":1.0,"active":true}', {"active":True}, raw=True)
fs("exactly 256 bytes", sized('{"version":1,"active":false,"pad":"', 256), {"active":False}, raw=True)
fs("257 bytes", sized('{"version":1,"active":false,"pad":"', 257), "reject", raw=True)
fs("active as a number", {"version":1,"active":1}, "reject")
fs("active as a string", {"version":1,"active":"true"}, "reject")
fs("active missing", {"version":1}, "reject")
fs("version 2", {"version":2,"active":True}, "reject")
fs("version as a boolean", {"version":True,"active":True}, "reject")
fs("version missing", {"active":True}, "reject")
fs("not an object", [1, True], "reject")
fs("lenient JSON", "{version:1,active:true}", "reject", raw=True)

def cat_entry(i, t=None, b=None): return {"id":i,"title":t,"blocked":b}
mac_full = {"switches":["lock","sleep","screensaver","volume"],"apps":[{"bundleID":"com.apple.Safari","name":"Safari"}],
            "shortcuts":[{"id":SH,"name":"Morning routine"}],"accessibilityTrusted":False}
catalog = []
def ca(name, p, expect, raw=False, mac=None):
    v = {"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect}
    if mac: v["mac"] = mac
    catalog.append(v)
ca("every kind of entry, Lock needs Accessibility", {"version":1,"actions":[
    {"id":"lock","title":"Lock screen","blocked":"permission_required"},{"id":"sleep","title":"Sleep"},{"id":"screensaver","title":"Start screen saver"},
    {"id":"volume_down","title":"Volume down"},{"id":"volume_mute","title":"Mute"},{"id":"volume_up","title":"Volume up"},{"id":"volume_set","title":"Set volume"},
    {"id":"app:com.apple.Safari","title":"Safari"},{"id":"shortcut:"+SH,"title":"Morning routine"}],"volume":{"level":40,"muted":False}},
   {"actions":[cat_entry("lock",None,"permission_required"),cat_entry("sleep"),cat_entry("screensaver"),cat_entry("volume_down"),cat_entry("volume_mute"),
               cat_entry("volume_up"),cat_entry("volume_set"),cat_entry("app:com.apple.Safari","Safari"),cat_entry("shortcut:"+SH,"Morning routine")],
    "volume":{"level":40,"muted":False}}, mac=mac_full)
ca("Lock allowed with Accessibility, nothing else", {"version":1,"actions":[{"id":"lock","title":"Lock screen"}]},
   {"actions":[cat_entry("lock")],"volume":None}, mac={"switches":["lock"],"apps":[],"shortcuts":[],"accessibilityTrusted":True})
ca("empty list", {"version":1,"actions":[]}, {"actions":[],"volume":None}, mac={"switches":[],"apps":[],"shortcuts":[],"accessibilityTrusted":True})
ca("unknown identifiers are dropped", {"version":1,"actions":[{"id":"power_off"},{"id":"app:com apple"},{"id":"shortcut:NOT-A-UUID","title":"x"},
    {"id":"shortcut:"+SH.upper(),"title":"x"},{"id":"app:"+"a"*156,"title":"x"},{"id":"sleep"}]}, {"actions":[cat_entry("sleep")],"volume":None})
ca("apps and Shortcuts need a title", {"version":1,"actions":[{"id":"app:com.apple.Notes"},{"id":"app:com.apple.Music","title":""},{"id":"app:com.apple.Mail","title":"   "},{"id":"app:com.apple.Maps","title":"Maps"}]},
   {"actions":[cat_entry("app:com.apple.Maps","Maps")],"volume":None})
ca("title of 64 characters", {"version":1,"actions":[{"id":"app:x.y","title":"t"*64}]}, {"actions":[cat_entry("app:x.y","t"*64)],"volume":None})
ca("title of 65 characters is dropped", {"version":1,"actions":[{"id":"app:x.y","title":"t"*65}]}, {"actions":[],"volume":None})
ca("title with a control character is dropped", {"version":1,"actions":[{"id":"app:x.y","title":"a\u0007b"}]}, {"actions":[],"volume":None})
ca("unicode title", {"version":1,"actions":[{"id":"app:ru.yandex.music","title":"Яндекс Музыка 🎵"}]}, {"actions":[cat_entry("app:ru.yandex.music","Яндекс Музыка 🎵")],"volume":None})
ca("a repeated identifier keeps the first", {"version":1,"actions":[{"id":"app:x.y","title":"First"},{"id":"app:x.y","title":"Second"}]}, {"actions":[cat_entry("app:x.y","First")],"volume":None})
ca("entries that are not objects are dropped", {"version":1,"actions":["lock",5,None,{"id":5},{"id":"lock"}]}, {"actions":[cat_entry("lock")],"volume":None})
ca("blocked other than permission_required is ignored", {"version":1,"actions":[{"id":"lock","blocked":"later"}]}, {"actions":[cat_entry("lock")],"volume":None})
ca("volume level 101 is dropped", {"version":1,"actions":[],"volume":{"level":101,"muted":False}}, {"actions":[],"volume":None})
ca("volume level as a string is dropped", {"version":1,"actions":[],"volume":{"level":"40","muted":False}}, {"actions":[],"volume":None})
ca("volume muted as a number is dropped", {"version":1,"actions":[],"volume":{"level":40,"muted":1}}, {"actions":[],"volume":None})
ca("volume level written as 40.0", '{"version":1,"actions":[],"volume":{"level":40.0,"muted":true}}', {"actions":[],"volume":{"level":40,"muted":True}}, raw=True)
ca("64 entries", {"version":1,"actions":[{"id":"app:a%d" % i,"title":"A%d" % i} for i in range(64)]},
   {"actions":[cat_entry("app:a%d" % i,"A%d" % i) for i in range(64)],"volume":None})
ca("65 entries", {"version":1,"actions":[{"id":"app:a%d" % i,"title":"A%d" % i} for i in range(65)]}, "reject")
ca("version 2", {"version":2,"actions":[]}, "reject")
ca("version missing", {"actions":[]}, "reject")
ca("actions missing", {"version":1}, "reject")
ca("actions not an array", {"version":1,"actions":{"id":"lock"}}, "reject")
ca("over 8 KiB", sized('{"version":1,"actions":[],"pad":"', 8193), "reject", raw=True)
ca("exactly 8 KiB", sized('{"version":1,"actions":[],"pad":"', 8192), {"actions":[],"volume":None}, raw=True)
ca("lenient JSON", "{version:1,actions:[]}", "reject", raw=True)

run = []
def ru(name, p, expect, raw=False, android=None):
    v = {"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect}
    if android: v["android"] = android
    run.append(v)
def rx(action, seq=1, value=None, rid=R1):
    return {"requestId":rid,"action":action,"sequence":seq,"value":value}
ru("lock", {"version":1,"requestId":R1,"action":"lock","sequence":1}, rx("lock"), android={"action":"lock"})
ru("set the volume", {"version":1,"requestId":R1,"action":"volume_set","sequence":7,"value":30}, rx("volume_set",7,30), android={"action":"volume_set","value":30})
ru("open an app", {"version":1,"requestId":R1,"action":"app:com.apple.Safari","sequence":2}, rx("app:com.apple.Safari",2), android={"action":"app:com.apple.Safari"})
ru("run a Shortcut", {"version":1,"requestId":R1,"action":"shortcut:"+SH,"sequence":3}, rx("shortcut:"+SH,3), android={"action":"shortcut:"+SH})
ru("largest sequence", {"version":1,"requestId":R1,"action":"sleep","sequence":9007199254740991}, rx("sleep",9007199254740991), android={"action":"sleep","sequence":9007199254740991})
ru("unknown fields are ignored", {"version":1,"requestId":R1,"action":"sleep","sequence":1,"command":"rm -rf /"}, rx("sleep"))
ru("unknown action decodes (answered not_allowed)", {"version":1,"requestId":R1,"action":"power_off","sequence":1}, rx("power_off"))
ru("action missing decodes (answered not_allowed)", {"version":1,"requestId":R1,"sequence":1}, rx(None))
ru("value as a string (answered invalid)", {"version":1,"requestId":R1,"action":"volume_set","sequence":1,"value":"30"}, rx("volume_set",1,"other"))
ru("value as a fraction (answered invalid)", '{"version":1,"requestId":"%s","action":"volume_set","sequence":1,"value":30.5}' % R1, rx("volume_set",1,"other"), raw=True)
ru("value as a boolean (answered invalid)", {"version":1,"requestId":R1,"action":"volume_set","sequence":1,"value":True}, rx("volume_set",1,"other"))
ru("value written as 30.0", '{"version":1,"requestId":"%s","action":"volume_set","sequence":1,"value":30.0}' % R1, rx("volume_set",1,30), raw=True)
ru("null value counts as absent", {"version":1,"requestId":R1,"action":"lock","sequence":1,"value":None}, rx("lock"))
ru("sequence written as 1.0", '{"version":1,"requestId":"%s","action":"lock","sequence":1.0}' % R1, rx("lock"), raw=True)
ru("sequence 0", {"version":1,"requestId":R1,"action":"lock","sequence":0}, "reject")
ru("sequence 2^53", {"version":1,"requestId":R1,"action":"lock","sequence":9007199254740992}, "reject")
ru("sequence as a string", {"version":1,"requestId":R1,"action":"lock","sequence":"1"}, "reject")
ru("sequence missing", {"version":1,"requestId":R1,"action":"lock"}, "reject")
ru("requestId not a UUID", {"version":1,"requestId":"run-1","action":"lock","sequence":1}, "reject")
ru("requestId missing", {"version":1,"action":"lock","sequence":1}, "reject")
ru("version 2", {"version":2,"requestId":R1,"action":"lock","sequence":1}, "reject")
ru("version as a boolean", {"version":True,"requestId":R1,"action":"lock","sequence":1}, "reject")
ru("over 1 KiB", sized('{"version":1,"requestId":"%s","action":"lock","sequence":1,"pad":"' % R1, 1025), "reject", raw=True)
ru("lenient JSON", "{version:1,requestId:'%s',action:'lock',sequence:1}" % R1, "reject", raw=True)

result = []
def rs(name, p, expect, raw=False, mac=None):
    v = {"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect}
    if mac: v["mac"] = mac
    result.append(v)
def rr(action, status, reason=None, volume=None): return {"requestId":R1,"action":action,"status":status,"reason":reason,"volume":volume}
rs("done", {"version":1,"requestId":R1,"action":"lock","status":"done"}, rr("lock","done"), mac={"outcome":"done"})
rs("done with the new volume", {"version":1,"requestId":R1,"action":"volume_up","status":"done","volume":{"level":50,"muted":False}},
   rr("volume_up","done",volume={"level":50,"muted":False}), mac={"outcome":"done","volume":{"level":50,"muted":False}})
for reason in ["not_allowed","invalid","rate_limited","busy","permission_required","unavailable","failed"]:
    rs("refused " + reason, {"version":1,"requestId":R1,"action":"lock","status":"refused","reason":reason}, rr("lock","refused",reason), mac={"outcome":"refused","reason":reason})
rs("an unknown reason reads as failed", {"version":1,"requestId":R1,"action":"lock","status":"refused","reason":"tired"}, rr("lock","refused","failed"))
rs("a missing reason reads as failed", {"version":1,"requestId":R1,"action":"lock","status":"refused"}, rr("lock","refused","failed"))
rs("a reason on done is ignored", {"version":1,"requestId":R1,"action":"lock","status":"done","reason":"busy"}, rr("lock","done"))
rs("a bad volume is dropped", {"version":1,"requestId":R1,"action":"volume_up","status":"done","volume":{"level":-1,"muted":False}}, rr("volume_up","done"))
rs("unknown status", {"version":1,"requestId":R1,"action":"lock","status":"maybe"}, "reject")
rs("status missing", {"version":1,"requestId":R1,"action":"lock"}, "reject")
rs("requestId missing", {"version":1,"action":"lock","status":"done"}, "reject")
rs("action missing", {"version":1,"requestId":R1,"status":"done"}, "reject")
rs("version 2", {"version":2,"requestId":R1,"action":"lock","status":"done"}, "reject")
rs("over 1 KiB", sized('{"version":1,"requestId":"%s","action":"lock","status":"done","pad":"' % R1, 1025), "reject", raw=True)
rs("lenient JSON", "{version:1,requestId:'%s',action:'lock',status:'done'}" % R1, "reject", raw=True)

camreq = []
def cq(name, p, expect, raw=False, mac=False):
    v = {"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect}
    if mac: v["mac"] = True
    camreq.append(v)
cq("one photo", {"version":1,"requestId":R1,"mode":"photo"}, {"requestId":R1}, mac=True)
cq("an uppercase request ID is read lowercased", {"version":1,"requestId":R1.upper(),"mode":"photo"}, {"requestId":R1})
cq("unknown fields are ignored", {"version":1,"requestId":R1,"mode":"photo","flash":True}, {"requestId":R1})
cq("mode video", {"version":1,"requestId":R1,"mode":"video"}, "reject")
cq("mode missing", {"version":1,"requestId":R1}, "reject")
cq("requestId not a UUID", {"version":1,"requestId":"photo-1","mode":"photo"}, "reject")
cq("requestId without dashes", {"version":1,"requestId":R1.replace("-",""),"mode":"photo"}, "reject")
cq("requestId as a number", {"version":1,"requestId":5,"mode":"photo"}, "reject")
cq("version 2", {"version":2,"requestId":R1,"mode":"photo"}, "reject")
cq("over 512 bytes", sized('{"version":1,"requestId":"%s","mode":"photo","pad":"' % R1, 513), "reject", raw=True)
cq("lenient JSON", "{version:1,requestId:'%s',mode:'photo'}" % R1, "reject", raw=True)

camstat = []
def cs(name, p, expect, raw=False, android=None):
    v = {"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect}
    if android: v["android"] = android
    camstat.append(v)
for status in ["opened","locked","permission_required","cancelled","busy","disabled","sending","failed"]:
    cs(status, {"version":1,"requestId":R1,"status":status}, {"requestId":R1,"status":status}, android=status)
cs("unknown status", {"version":1,"requestId":R1,"status":"smiling"}, "reject")
cs("status missing", {"version":1,"requestId":R1}, "reject")
cs("requestId as a number", {"version":1,"requestId":5,"status":"opened"}, "reject")
cs("version 2", {"version":2,"requestId":R1,"status":"opened"}, "reject")
cs("over 512 bytes", sized('{"version":1,"requestId":"%s","status":"opened","pad":"' % R1, 513), "reject", raw=True)
cs("lenient JSON", "{version:1,requestId:'%s',status:'opened'}" % R1, "reject", raw=True)

# Update all (docs/protocol.md "Update all"). Both platforms decode every group. 'write': true means both platforms' encoders
# also write exactly that plaintext from the expected value (key order aside).
R2 = "5b0c9e2a-7d41-4c3f-8e5a-1f2b3c4d5e6f"
st = []
def us(name, p, expect, raw=False, write=False):
    v = {"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect}
    if write: v["write"] = True
    st.append(v)
base = {"version":1,"platform":"android","edition":"rr","app":"0.9.0-rr.3-beta.2","build":903002,"channel":"beta","state":"current","remoteStart":True,"checkedAt":1793091600000}
def e(**kw):
    d = {k:v for k,v in base.items() if k != "version"}
    d.update({"target":None,"targetBuild":None,"progress":None,"reason":None})
    d.update(kw)
    return d
us("up to date", base, e(), write=True)
us("checking, never checked before", {**base,"state":"checking","checkedAt":0}, e(state="checking",checkedAt=0), write=True)
us("available", {**base,"state":"available","target":"0.9.0-rr.3-beta.3","targetBuild":903003}, e(state="available",target="0.9.0-rr.3-beta.3",targetBuild=903003), write=True)
us("downloading at 42%", {**base,"state":"downloading","target":"0.9.0-rr.3-beta.3","targetBuild":903003,"progress":42}, e(state="downloading",target="0.9.0-rr.3-beta.3",targetBuild=903003,progress=42), write=True)
us("ready on a Mac", {**base,"platform":"macos","channel":"stable","app":"0.9.0-rr.2","build":902000,"state":"ready","target":"0.9.0-rr.3","targetBuild":903000},
   e(platform="macos",channel="stable",app="0.9.0-rr.2",build=902000,state="ready",target="0.9.0-rr.3",targetBuild=903000), write=True)
us("installing", {**base,"state":"installing","target":"0.9.0-rr.3-beta.3","targetBuild":903003}, e(state="installing",target="0.9.0-rr.3-beta.3",targetBuild=903003), write=True)
us("needs the person to confirm", {**base,"state":"needs_user","target":"0.9.0-rr.3-beta.3","targetBuild":903003,"reason":"confirm"}, e(state="needs_user",target="0.9.0-rr.3-beta.3",targetBuild=903003,reason="confirm"), write=True)
us("needs Install unknown apps", {**base,"state":"needs_user","target":"0.9.0-rr.3-beta.3","targetBuild":903003,"reason":"permission"}, e(state="needs_user",target="0.9.0-rr.3-beta.3",targetBuild=903003,reason="permission"), write=True)
us("did not apply", {**base,"state":"failed","target":"0.9.0-rr.3-beta.3","targetBuild":903003,"reason":"not_applied"}, e(state="failed",target="0.9.0-rr.3-beta.3",targetBuild=903003,reason="not_applied"), write=True)
us("failed check without a target", {**base,"state":"failed","reason":"check"}, e(state="failed",reason="check"), write=True)
us("manual, remote start off", {**base,"platform":"macos","state":"manual","remoteStart":False}, e(platform="macos",state="manual",remoteStart=False), write=True)
us("an unknown reason reads as other", {**base,"state":"failed","reason":"disk_full"}, e(state="failed",reason="other"))
us("unknown fields are ignored", {**base,"since":5,"extra":{"a":1}}, e())
us("version written as 1.0", '{"version":1.0,"platform":"android","edition":"rr","app":"0.9.0-rr.3-beta.2","build":903002,"channel":"beta","state":"current","remoteStart":true,"checkedAt":1793091600000}', e(), raw=True)
us("null optionals count as absent", {**base,"target":None,"targetBuild":None,"progress":None,"reason":None}, e())
us("app of 64 bytes", {**base,"app":"9"*64}, e(app="9"*64))
us("app of 65 bytes", {**base,"app":"9"*65}, "reject")
us("app empty", {**base,"app":""}, "reject")
us("edition of 33 bytes", {**base,"edition":"r"*33}, "reject")
us("multi-byte edition counts bytes", {**base,"edition":"é"*17}, "reject")
us("build 0", {**base,"build":0}, "reject")
us("build 2^53-1", {**base,"build":9007199254740991}, e(build=9007199254740991))
us("build 2^53", {**base,"build":9007199254740992}, "reject")
us("build as a string", {**base,"build":"903002"}, "reject")
us("progress 101", {**base,"state":"downloading","progress":101}, "reject")
us("progress -1", {**base,"state":"downloading","progress":-1}, "reject")
us("targetBuild 0", {**base,"state":"available","target":"x","targetBuild":0}, "reject")
us("target of 65 bytes", {**base,"state":"available","target":"9"*65}, "reject")
us("target as a number", {**base,"state":"available","target":5}, "reject")
us("reason as a number", {**base,"state":"failed","reason":3}, "reject")
us("unknown state", {**base,"state":"sleeping"}, "reject")
us("unknown platform", {**base,"platform":"windows"}, "reject")
us("unknown channel", {**base,"channel":"canary"}, "reject")
us("remoteStart missing", {k:v for k,v in base.items() if k != "remoteStart"}, "reject")
us("remoteStart as a string", {**base,"remoteStart":"true"}, "reject")
us("checkedAt missing", {k:v for k,v in base.items() if k != "checkedAt"}, "reject")
us("checkedAt negative", {**base,"checkedAt":-1}, "reject")
us("version 2", {**base,"version":2}, "reject")
us("exactly 1,024 bytes", sized('{"version":1,"platform":"android","edition":"rr","app":"0.9.0-rr.3-beta.2","build":903002,"channel":"beta","state":"current","remoteStart":true,"checkedAt":1793091600000,"pad":"', 1024), e(), raw=True)
us("1,025 bytes", sized('{"version":1,"platform":"android","edition":"rr","app":"0.9.0-rr.3-beta.2","build":903002,"channel":"beta","state":"current","remoteStart":true,"checkedAt":1793091600000,"pad":"', 1025), "reject", raw=True)
us("not an object", [1, 2], "reject")
us("lenient JSON", "{version:1,platform:'android'}", "reject", raw=True)

ustart = []
def ut(name, p, expect, raw=False, write=False):
    v = {"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect}
    if write: v["write"] = True
    ustart.append(v)
ut("update now", {"version":1,"requestId":R2}, {"requestId":R2,"retry":False}, write=True)
ut("retry after Retry was tapped", {"version":1,"requestId":R2,"retry":True}, {"requestId":R2,"retry":True}, write=True)
ut("retry false written out", {"version":1,"requestId":R2,"retry":False}, {"requestId":R2,"retry":False})
ut("an uppercase request ID is read lowercased", {"version":1,"requestId":R2.upper()}, {"requestId":R2,"retry":False})
ut("unknown fields are ignored (a version or URL is never read)", {"version":1,"requestId":R2,"url":"https://example.com/evil.apk","target":"9.9.9"}, {"requestId":R2,"retry":False})
ut("retry as a string", {"version":1,"requestId":R2,"retry":"true"}, "reject")
ut("requestId not a UUID", {"version":1,"requestId":"update-1"}, "reject")
ut("requestId missing", {"version":1}, "reject")
ut("version 2", {"version":2,"requestId":R2}, "reject")
ut("over 512 bytes", sized('{"version":1,"requestId":"%s","pad":"' % R2, 513), "reject", raw=True)
ut("lenient JSON", "{version:1,requestId:'%s'}" % R2, "reject", raw=True)

uresult = []
def ur(name, p, expect, raw=False, write=False):
    v = {"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect}
    if write: v["write"] = True
    uresult.append(v)
ur("accepted", {"version":1,"requestId":R2,"status":"accepted"}, {"requestId":R2,"status":"accepted","reason":None}, write=True)
for reason in ["disabled","rate_limited","manual","not_applied","busy"]:
    ur("refused " + reason, {"version":1,"requestId":R2,"status":"refused","reason":reason}, {"requestId":R2,"status":"refused","reason":reason}, write=True)
ur("an unknown reason reads as other", {"version":1,"requestId":R2,"status":"refused","reason":"tired"}, {"requestId":R2,"status":"refused","reason":"other"})
ur("refused without a reason reads as other", {"version":1,"requestId":R2,"status":"refused"}, {"requestId":R2,"status":"refused","reason":"other"})
ur("a reason with accepted is ignored", {"version":1,"requestId":R2,"status":"accepted","reason":"busy"}, {"requestId":R2,"status":"accepted","reason":None})
ur("unknown status", {"version":1,"requestId":R2,"status":"maybe"}, "reject")
ur("requestId not a UUID", {"version":1,"requestId":"x","status":"accepted"}, "reject")
ur("version 2", {"version":2,"requestId":R2,"status":"accepted"}, "reject")
ur("over 512 bytes", sized('{"version":1,"requestId":"%s","status":"accepted","pad":"' % R2, 513), "reject", raw=True)

# Settings sync (settings_sync_draft1, docs/folders-and-settings-sync.md sections 4.9, 8 and 8.4). settingsPayload: a
# settings.snapshot or settings.update plaintext as the receiver reads it. expect is {records, waiting, skipped} (the
# records of the 21 schema 1 keys, the keys the sender says wait for a permission there, and how many record entries were
# skipped one by one: unknown or per-device keys, wrong types, values out of range), "invalid" (the whole message is
# dropped and answered settings.error invalid_message) or {"unsupportedSchema": N}.
DA = "7e57d00d-0000-4000-8000-00000000000a"
DB = "7e57d00d-0000-4000-8000-00000000000b"
def rec(v, at, ver, by): return {"value":v,"changedAt":at,"version":ver,"changedBy":by}
SYNC_STRING_KEYS = {"files.folder_destination":["sender_picks","receiver_asks","fixed"], "files.folder_conflict":["ask","merge","replace","new_folder"]}
SYNC_BOOL_KEYS = ["activity.previews","display.reduce_motion",
                  "feature.clipboard","feature.files","feature.notifications","feature.battery","feature.find_device","feature.ping",
                  "feature.links","feature.media","feature.calls","feature.remote_input","feature.mac_actions","feature.camera",
                  "clipboard.automatic","clipboard.files","focus.share","focus.follow","codes.enabled"]
assert len(SYNC_STRING_KEYS) + len(SYNC_BOOL_KEYS) == 21
spay = []
def sp(name, kind, p, expect, raw=False): spay.append({"name":name, "kind":kind, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
def ok(records, skipped=0, waiting=None, first=False, new=False, answered=False):
    return {"records":records, "waiting":waiting or [], "skipped":skipped, "first":first, "new":new, "answered":answered}
four = {"files.folder_destination":rec("fixed",1792900000000,2,DA),"files.folder_conflict":rec("ask",0,0,""),
        "activity.previews":rec(False,1792900000500,4,DB),"display.reduce_motion":rec(True,1,1,DA)}
every = {**four, **{k: rec(True, 1792900000000 + n, 1, DA) for n, k in enumerate(SYNC_BOOL_KEYS[2:])}}
sp("snapshot with every schema 1 key", "snapshot", {"schema":1,"maxSchema":1,"records":every}, ok(every))
sp("update with one record", "update", {"schema":1,"records":{"display.reduce_motion":rec(False,1792900001000,5,DB)}},
   ok({"display.reduce_motion":rec(False,1792900001000,5,DB)}))
sp("update with no records (a waiting list change)", "update", {"schema":1,"records":{},"waiting":["feature.calls"]}, ok({}, waiting=["feature.calls"]))
sp("never-chosen value", "update", {"schema":1,"records":{"files.folder_destination":rec("sender_picks",0,0,"")}},
   ok({"files.folder_destination":rec("sender_picks",0,0,"")}))
for key, values in SYNC_STRING_KEYS.items():
    for value in values:
        sp("%s %s" % (key, value), "update", {"schema":1,"records":{key:rec(value,7,1,DA)}}, ok({key:rec(value,7,1,DA)}))
for key in SYNC_BOOL_KEYS:
    sp("%s off" % key, "update", {"schema":1,"records":{key:rec(False,7,1,DA)}}, ok({key:rec(False,7,1,DA)}))
sp("unknown key is skipped, the rest applies", "update", {"schema":1,"records":{"display.theme":rec("dark",9,1,DA),"display.reduce_motion":rec(True,9,1,DA)}},
   ok({"display.reduce_motion":rec(True,9,1,DA)}, 1))
sp("per-device and local-only keys are never synced", "snapshot",
   {"schema":1,"maxSchema":1,"records":{"pair.clipboard.automatic":rec(True,9,1,DA),"files.allow_replace":rec(True,9,1,DA),"files.allow_browse":rec(True,9,1,DA),
                                         "device.name":rec("x",9,1,DA),"updates.channel":rec("beta",9,1,DA),"updates.remote_start":rec(True,9,1,DA),
                                         "activity.previews":rec(True,0,0,"")}},
   ok({"activity.previews":rec(True,0,0,"")}, 6))
sp("bare feature keys are not settings keys", "update", {"schema":1,"records":{"files":rec(True,9,1,DA),"remote_input_draft1":rec(True,9,1,DA)}}, ok({}, 2))
sp("bool key with a string value", "update", {"schema":1,"records":{"display.reduce_motion":rec("true",9,1,DA)}}, ok({}, 1))
sp("bool key with a number value", "update", {"schema":1,"records":{"feature.calls":rec(1,9,1,DA)}}, ok({}, 1))
sp("string key with a bool value", "update", {"schema":1,"records":{"files.folder_conflict":rec(True,9,1,DA)}}, ok({}, 1))
sp("string value not allowed", "update", {"schema":1,"records":{"files.folder_conflict":rec("overwrite",9,1,DA)}}, ok({}, 1))
sp("value null", "update", {"schema":1,"records":{"display.reduce_motion":rec(None,9,1,DA)}}, ok({}, 1))
sp("value missing", "update", {"schema":1,"records":{"display.reduce_motion":{"changedAt":9,"version":1,"changedBy":DA}}}, ok({}, 1))
sp("changedAt negative", "update", {"schema":1,"records":{"display.reduce_motion":rec(True,-1,1,DA)}}, ok({}, 1))
sp("changedAt 2^53-1", "update", {"schema":1,"records":{"display.reduce_motion":rec(True,9007199254740991,1,DA)}},
   ok({"display.reduce_motion":rec(True,9007199254740991,1,DA)}))
sp("changedAt 2^53", "update", {"schema":1,"records":{"display.reduce_motion":rec(True,9007199254740992,1,DA)}}, ok({}, 1))
sp("changedAt as a string", "update", {"schema":1,"records":{"display.reduce_motion":rec(True,"9",1,DA)}}, ok({}, 1))
sp("changedAt written as 9.0", "update", '{"schema":1,"records":{"display.reduce_motion":{"value":true,"changedAt":9.0,"version":1,"changedBy":"%s"}}}' % DA,
   ok({"display.reduce_motion":rec(True,9,1,DA)}), raw=True)
sp("changedAt a fraction", "update", '{"schema":1,"records":{"display.reduce_motion":{"value":true,"changedAt":9.5,"version":1,"changedBy":"%s"}}}' % DA,
   ok({}, 1), raw=True)
sp("version negative", "update", {"schema":1,"records":{"display.reduce_motion":rec(True,9,-1,DA)}}, ok({}, 1))
sp("version missing", "update", {"schema":1,"records":{"display.reduce_motion":{"value":True,"changedAt":9,"changedBy":DA}}}, ok({}, 1))
sp("changedBy as a number", "update", {"schema":1,"records":{"display.reduce_motion":rec(True,9,1,7)}}, ok({}, 1))
sp("changedBy missing", "update", {"schema":1,"records":{"display.reduce_motion":{"value":True,"changedAt":9,"version":1}}}, ok({}, 1))
sp("changedBy of 128 bytes", "update", {"schema":1,"records":{"display.reduce_motion":rec(True,9,1,"d"*128)}},
   ok({"display.reduce_motion":rec(True,9,1,"d"*128)}))
sp("changedBy of 129 bytes", "update", {"schema":1,"records":{"display.reduce_motion":rec(True,9,1,"d"*129)}}, ok({}, 1))
sp("record not an object", "update", {"schema":1,"records":{"display.reduce_motion":True}}, ok({}, 1))
sp("unknown fields are ignored", "update", {"schema":1,"source":"x","records":{"display.reduce_motion":{**rec(True,9,1,DA),"note":"x"}}},
   ok({"display.reduce_motion":rec(True,9,1,DA)}))
sp("waiting: unknown keys and non-strings are dropped, repeats once, schema order", "update",
   {"schema":1,"records":{},"waiting":["feature.notifications","x.y",5,"feature.calls","feature.calls",None,"focus.follow"]},
   ok({}, waiting=["feature.notifications","feature.calls","focus.follow"]))
sp("waiting that is not an array counts as empty", "update", {"schema":1,"records":{},"waiting":"feature.calls"}, ok({}))
sp("first connect of a new device", "snapshot", {"schema":1,"maxSchema":1,"records":{},"first":True,"new":True}, ok({}, first=True, new=True))
sp("first connect of a device that synced before", "snapshot", {"schema":1,"maxSchema":1,"records":{},"first":True,"new":False}, ok({}, first=True))
sp("the person answered", "update", {"schema":1,"records":{},"answered":True}, ok({}, answered=True))
sp("first, new and answered that are not booleans count as false", "snapshot", {"schema":1,"records":{},"first":1,"new":"true","answered":None}, ok({}))
filler = {"x.k%02d" % n: rec(True,1,1,DA) for n in range(11)}
assert len(every) + len(filler) == 32
sp("32 records (11 unknown)", "snapshot", {"schema":1,"maxSchema":1,"records":{**every,**filler}}, ok(every, 11))
sp("33 records", "snapshot", {"schema":1,"maxSchema":1,"records":{**every,**filler,"x.k99":rec(True,1,1,DA)}}, "invalid")
sp("waiting of 33 entries", "update", {"schema":1,"records":{},"waiting":["feature.calls"]*33}, "invalid")
sp("schema 2", "update", {"schema":2,"records":{}}, {"unsupportedSchema":2})
sp("schema 0", "snapshot", {"schema":0,"maxSchema":0,"records":{}}, {"unsupportedSchema":0})
sp("schema written as 1.0", "update", '{"schema":1.0,"records":{}}', ok({}), raw=True)
sp("schema as a string", "update", {"schema":"1","records":{}}, "invalid")
sp("schema missing", "update", {"records":{}}, "invalid")
sp("records missing", "update", {"schema":1}, "invalid")
sp("records as an array", "update", {"schema":1,"records":[]}, "invalid")
sp("not an object", "update", [1], "invalid")
sp("lenient JSON", "update", "{schema:1,records:{}}", "invalid", raw=True)
sp("exactly 16,384 bytes", "update", sized('{"schema":1,"records":{},"pad":"', 16384), ok({}), raw=True)
sp("16,385 bytes", "update", sized('{"schema":1,"records":{},"pad":"', 16385), "invalid", raw=True)

# settingsMerge: which record wins when a settings.update arrives (section 8.2). The higher changedAt, then the higher
# version, then the larger changedBy in UTF-8 byte order. "equal" when all three match (the same record: nothing to do).
smerge = []
def sm(name, local, remote, expect): smerge.append({"name":name, "local":local, "remote":remote, "expect":expect})
sm("later changedAt wins", rec(True,1000,3,DA), rec(False,1200,3,DB), "remote")
sm("earlier changedAt loses even with a higher version", rec(True,1200,1,DA), rec(False,1000,9,DB), "local")
sm("same changedAt: higher version wins", rec(True,1000,3,DB), rec(False,1000,4,DA), "remote")
sm("same changedAt and version: larger changedBy wins", rec(True,1000,3,DB), rec(False,1000,3,DA), "local")
sm("changedBy compares bytes, not case", rec(True,5,1,"a"), rec(False,5,1,"B"), "local")
sm("changedBy compares UTF-8 bytes (U+1F600 sorts after U+FFFD)", rec(True,5,1,"\ufffd"), rec(False,5,1,"\U0001F600"), "remote")
sm("all three equal is the same record", rec(True,1000,3,DA), rec(True,1000,3,DA), "equal")
sm("any edit beats a never-chosen value", rec("sender_picks",0,0,""), rec("fixed",1,1,DB), "remote")
sm("two never-chosen values are equal", rec(False,0,0,""), rec(False,0,0,""), "equal")
sm("upgrade stamps resolve by device ID", rec("merge",1,1,DA), rec("replace",1,1,DB), "remote")

# settingsSnapshot: what a settings.snapshot record does here (section 8.4). "adopt": this device never chose the
# setting and the peer did, so it takes the peer's record; "different": both chose and the values differ, so nothing
# changes and Settings shows "Different on <device>" with Apply to all; "same": nothing to do (same value, or the peer
# never chose).
ssnap = []
def sn(name, local, remote, expect): ssnap.append({"name":name, "local":local, "remote":remote, "expect":expect})
sn("never chosen here, chosen there: adopt", rec(False,0,0,""), rec(True,1792900000000,3,DB), "adopt")
sn("upgrade stamp there counts as chosen", rec("ask",0,0,""), rec("merge",1,1,DB), "adopt")
sn("both chose different values: different, even when the peer's is later", rec(False,1000,2,DA), rec(True,1200,5,DB), "different")
sn("both chose different values: different, when ours is later", rec(False,1200,2,DA), rec(True,1000,5,DB), "different")
sn("both chose the same value: same", rec(True,1000,2,DA), rec(True,1200,5,DB), "same")
sn("never chosen there: same (the peer adopts ours)", rec(True,1000,2,DA), rec(False,0,0,""), "same")
sn("never chosen on either side: same", rec(False,0,0,""), rec(True,0,0,""), "same")
sn("the same record: same", rec(True,1000,2,DA), rec(True,1000,2,DA), "same")

# settingsAsker: who asks "Use the same settings as <device>?" on a first connect (8.4), from this device's side. Each
# side has first (no answer for the other yet) and new (no answer for any device); phone says whether this side is the
# phone. "local": this device asks; "remote": the other one asks (this side waits for its answer); "none": nobody asks.
sasker = []
def sa(name, lf, ln, phone, rf, rn, expect):
    sasker.append({"name":name, "local":{"first":lf,"new":ln,"phone":phone}, "remote":{"first":rf,"new":rn}, "expect":expect})
sa("new phone meets a Mac that synced before", True, True, True, True, False, "local")
sa("the Mac's side of the same", True, False, False, True, True, "remote")
sa("new Mac meets a phone that synced before", True, True, False, True, False, "local")
sa("the phone's side of the same", True, False, True, True, True, "remote")
sa("both new: the phone asks", True, True, True, True, True, "local")
sa("both new: the Mac waits", True, True, False, True, True, "remote")
sa("neither new: nobody asks", True, False, True, True, False, "none")
sa("this side already answered", False, False, True, True, True, "none")
sa("the other side already answered", True, True, False, False, False, "none")

# settingsStamp: a local edit or Apply to all (section 8.2). changedAt = max(now, current.changedAt + 1), at most 2^53-1;
# version + 1; changedBy this device.
sstamp = []
def ss(name, current, now, expect): sstamp.append({"name":name, "current":current, "now":now, "device":DA, "expect":expect})
ss("clock ahead of the record", rec(True,1000,3,DB), 5000, rec(None,5000,4,DA))
ss("clock behind the record still moves forward", rec(True,9000,3,DB), 5000, rec(None,9001,4,DA))
ss("first edit of a never-chosen value", rec(False,0,0,""), 1792900000000, rec(None,1792900000000,1,DA))
ss("changedAt at 2^53-1 stays there; the version decides", rec(True,9007199254740991,3,DB), 5000, rec(None,9007199254740991,4,DA))
ss("same changedAt as now still moves forward", rec(True,5000,1,DB), 5000, rec(None,5001,2,DA))
ss("Apply to all from a chosen value", rec(True,1792900000000,7,DA), 1792900005000, rec(None,1792900005000,8,DA))

out = {
  "description": "Bridgey Protocol v1 golden vectors. Android (ProtocolGoldenVectorsTest) and macOS (ProtocolGoldenVectorsTests) decode every vector and must get the same expected result. Frames: 'line' is one frame without its line ending (default LF; 'lineEnding' overrides); 'lineBase64' gives raw bytes; 'nest': N builds {\"kind\":\"x.y\",\"sessionId\":S,\"x\":[[...]]} nested N deep (the outer object is 1); 'padTo': N builds a pairing.offer whose deviceName is 'a' repeated until the frame is N bytes, and '@PAD@' in expect stands for that name. Payload 'plaintext' is serialised by each platform's own JSON encoder; 'plaintextString' is used byte for byte. offerId values compare lowercased. browseRef: a Files 2.0 ref object; expect is the ref both platforms read, or reject. Automation (v0.9): focusState is decoded by both platforms; actionsCatalog, actionsResult and cameraRequest by the phone, actionsRun and cameraStatus by the Mac. 'android' or 'mac' on a vector says that platform also writes exactly that plaintext: android {action, value?, sequence?} for actionsRun (requestId and sequence from the plaintext), android <status> for cameraStatus; mac {switches, apps, shortcuts, accessibilityTrusted} for actionsCatalog (ids, blocked and the app and Shortcut titles; the volume comes from the output device), mac {outcome, reason?, volume?} for actionsResult, mac true for cameraRequest. Update all: updatesStatus, updatesStart and updatesResult are decoded by both platforms; absent optional values are null in expect, and 'write': true means both platforms also write exactly that plaintext from the expected value. In actionsRun, value null is absent and 'other' is present but not an integer. Settings sync (v0.10): settingsPayload is a settings.snapshot or settings.update plaintext as both platforms read it, expect {records, waiting, skipped}, 'invalid' or {unsupportedSchema}; settingsMerge says which of two records wins when an update arrives (local, remote or equal); settingsSnapshot says what a snapshot record does (adopt, different or same); settingsAsker says which side asks on a first connect (local, remote or none); settingsStamp is the record a local edit or Apply to all makes from current at now by device (value null: the new value is the edit's own).",
  "sessionId": S,
  "frames": frames,
  "featuresUpdate": feat,
  "batteryUpdate": batt,
  "clipboardRich": rich,
  "clipboardOffer": offers,
  "remoteInput": inp,
  "browseRef": refs,
  "focusState": focus,
  "actionsCatalog": catalog,
  "actionsRun": run,
  "actionsResult": result,
  "cameraRequest": camreq,
  "cameraStatus": camstat,
  "updatesStatus": st,
  "updatesStart": ustart,
  "updatesResult": uresult,
  "settingsPayload": spay,
  "settingsMerge": smerge,
  "settingsSnapshot": ssnap,
  "settingsAsker": sasker,
  "settingsStamp": sstamp,
}
open(OUT,'w').write(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
print(len(frames), len(feat), len(batt), len(rich), len(offers), len(inp), len(refs), len(focus), len(catalog), len(run), len(result), len(camreq), len(camstat), len(st), len(ustart), len(uresult), len(spay), len(smerge), len(ssnap), len(sasker), len(sstamp))
