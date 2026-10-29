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
               "updates_draft1":False,"screen_draft1":False,"sms_draft1":False}
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
# Screen sharing (v0.9, docs/protocol.md "Phone screen to Mac"): a draft key, true only for JSON true.
fe("v0.9 phone and Mac with screen sharing on", {"version":1,"features":{**features_all,"camera_draft1":True,"screen_draft1":True}},
   {"features":features_all,"drafts":{**drafts_none,"camera_draft1":True,"screen_draft1":True}})
fe("screen_draft1 that is not a boolean counts as false", {"version":1,"features":{**features_all,"screen_draft1":"true"}},
   {"features":features_all,"drafts":drafts_none})
# Text messages (sms_draft1): a plain draft key on both platforms.
fe("Mac and phone with Text messages on", {"version":1,"features":{**features_all,"sms_codes_draft1":True,"sms_draft1":True}},
   {"features":features_all,"drafts":{**drafts_none,"sms_codes_draft1":True,"sms_draft1":True}})
fe("sms_draft1 that is not a boolean counts as false", {"version":1,"features":{**features_all,"sms_draft1":"true"}},
   {"features":features_all,"drafts":drafts_none})
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

# Screen sharing (v0.9, docs/protocol.md "Phone screen to Mac"). screenRequest is decoded by the phone, screenStatus by the
# Mac. screenStream holds the JSON stream messages, each with "kind" and "decoder" ("mac", "android" or "both").
# screenFrame is the binary frame plaintext, decoded by the Mac; vectors with "android": true are what the phone writes.
ST = "6c2e9a14-3b5d-4e7f-8a90-1b2c3d4e5f60"
screq = []
def sq(name, p, expect, raw=False, mac=False):
    v = {"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect}
    if mac: v["mac"] = True
    screq.append(v)
sq("ask to see the screen", {"version":1,"requestId":R1}, {"requestId":R1}, mac=True)
sq("an uppercase request ID is read lowercased", {"version":1,"requestId":R1.upper()}, {"requestId":R1})
sq("unknown fields are ignored", {"version":1,"requestId":R1,"control":True}, {"requestId":R1})
sq("requestId not a UUID", {"version":1,"requestId":"screen-1"}, "reject")
sq("requestId missing", {"version":1}, "reject")
sq("requestId as a number", {"version":1,"requestId":5}, "reject")
sq("version 2", {"version":2,"requestId":R1}, "reject")
sq("version missing", {"requestId":R1}, "reject")
sq("exactly 512 bytes", sized('{"version":1,"requestId":"%s","pad":"' % R1, 512), {"requestId":R1}, raw=True)
sq("over 512 bytes", sized('{"version":1,"requestId":"%s","pad":"' % R1, 513), "reject", raw=True)
sq("lenient JSON", "{version:1,requestId:'%s'}" % R1, "reject", raw=True)

scstat = []
def ss(name, p, expect, raw=False, android=None):
    v = {"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect}
    if android: v["android"] = android
    scstat.append(v)
for status in ["waiting","declined","busy","disabled","failed"]:
    ss(status, {"version":1,"requestId":R1,"status":status}, {"requestId":R1,"status":status}, android=status)
ss("unknown status", {"version":1,"requestId":R1,"status":"opened"}, "reject")
ss("status missing", {"version":1,"requestId":R1}, "reject")
ss("requestId not a UUID", {"version":1,"requestId":"x","status":"waiting"}, "reject")
ss("version 2", {"version":2,"requestId":R1,"status":"waiting"}, "reject")
ss("over 512 bytes", sized('{"version":1,"requestId":"%s","status":"busy","pad":"' % R1, 513), "reject", raw=True)
ss("lenient JSON", "{version:1,requestId:'%s',status:'busy'}" % R1, "reject", raw=True)

sstream = []
def sm(name, kind, fields, expect, decoder, android=False, mac=False, raw=None, base=True):
    p = {"version":1,"streamId":ST,"sequence":3} if base else {}
    p.update(fields or {})
    v = {"name":name, "kind":kind, "decoder":decoder}
    if raw is not None: v["plaintextString"] = raw
    else: v["plaintext"] = p
    v["expect"] = expect
    if android: v["android"] = True
    if mac: v["mac"] = True
    sstream.append(v)
start = {"codec":"h264","width":720,"height":1600,"fps":30,"bitrate":4000000}
def sx(**kw):
    e = {"streamId":ST,"sequence":3,"requestId":None,"codec":"h264","width":720,"height":1600,"fps":30,"bitrate":4000000}
    e.update(kw); return e
sm("start", "screen.start", {**start, "sequence":1}, sx(sequence=1), "mac", android=True, base=True)
sm("start answering a request", "screen.start", {**start, "requestId":R1}, sx(requestId=R1), "mac", android=True)
sm("start with an uppercase stream ID reads lowercased", "screen.start", {**start, "streamId":ST.upper()}, sx(), "mac")
sm("start at the smallest size and rate", "screen.start", {**start, "width":16,"height":16,"fps":1,"bitrate":100000}, sx(width=16,height=16,fps=1,bitrate=100000), "mac")
sm("start at the largest size and rate", "screen.start", {**start, "width":4096,"height":4096,"fps":60,"bitrate":50000000}, sx(width=4096,height=4096,fps=60,bitrate=50000000), "mac")
sm("start with unknown fields", "screen.start", {**start, "hdr":True}, sx(), "mac")
sm("start with codec h265", "screen.start", {**start, "codec":"h265"}, "reject", "mac")
sm("start with an odd width", "screen.start", {**start, "width":721}, "reject", "mac")
sm("start with width 4098", "screen.start", {**start, "width":4098}, "reject", "mac")
sm("start with height 14", "screen.start", {**start, "height":14}, "reject", "mac")
sm("start at 61 fps", "screen.start", {**start, "fps":61}, "reject", "mac")
sm("start at 0 fps", "screen.start", {**start, "fps":0}, "reject", "mac")
sm("start with a bit rate under 100 kb/s", "screen.start", {**start, "bitrate":99999}, "reject", "mac")
sm("start with width as a string", "screen.start", {**start, "width":"720"}, "reject", "mac")
sm("start with width written as 720.0", "screen.start", None, sx(), "mac",
   raw='{"version":1,"streamId":"%s","sequence":3,"codec":"h264","width":720.0,"height":1600,"fps":30,"bitrate":4000000}' % ST)
sm("start with a requestId that is not a UUID", "screen.start", {**start, "requestId":"r1"}, "reject", "mac")
sm("start without codec", "screen.start", {k:v for k,v in start.items() if k != "codec"}, "reject", "mac")
sm("start over 1 KiB", "screen.start", None, "reject", "mac",
   raw=sized('{"version":1,"streamId":"%s","sequence":3,"codec":"h264","width":720,"height":1600,"fps":30,"bitrate":4000000,"pad":"' % ST, 1025))
sm("start of exactly 1 KiB", "screen.start", None, sx(), "mac",
   raw=sized('{"version":1,"streamId":"%s","sequence":3,"codec":"h264","width":720,"height":1600,"fps":30,"bitrate":4000000,"pad":"' % ST, 1024))
sm("started", "screen.started", {}, {"streamId":ST,"sequence":3}, "android", mac=True)
sm("started with a stream ID that is not a UUID", "screen.started", {"streamId":"s1"}, "reject", "android")
sm("started with sequence 0", "screen.started", {"sequence":0}, "reject", "android")
sm("started with sequence 2^53", "screen.started", {"sequence":9007199254740992}, "reject", "android")
sm("started with the largest sequence", "screen.started", {"sequence":9007199254740991}, {"streamId":ST,"sequence":9007199254740991}, "android")
sm("started without sequence", "screen.started", None, "reject", "android", raw='{"version":1,"streamId":"%s"}' % ST)
sm("started version 2", "screen.started", {"version":2}, "reject", "android")
sm("ack", "screen.ack", {"frame":42,"decodeMs":3}, {"streamId":ST,"sequence":3,"frame":42,"decodeMs":3,"keyframe":False}, "android", mac=True)
sm("ack asking for a key frame", "screen.ack", {"frame":42,"decodeMs":0,"keyframe":True}, {"streamId":ST,"sequence":3,"frame":42,"decodeMs":0,"keyframe":True}, "android", mac=True)
sm("ack with keyframe false", "screen.ack", {"frame":1,"decodeMs":0,"keyframe":False}, {"streamId":ST,"sequence":3,"frame":1,"decodeMs":0,"keyframe":False}, "android")
sm("ack of the largest frame number", "screen.ack", {"frame":4294967295,"decodeMs":60000}, {"streamId":ST,"sequence":3,"frame":4294967295,"decodeMs":60000,"keyframe":False}, "android")
sm("ack of frame 0", "screen.ack", {"frame":0,"decodeMs":1}, "reject", "android")
sm("ack of frame 2^32", "screen.ack", {"frame":4294967296,"decodeMs":1}, "reject", "android")
sm("ack with decodeMs 60001", "screen.ack", {"frame":1,"decodeMs":60001}, "reject", "android")
sm("ack with a negative decodeMs", "screen.ack", {"frame":1,"decodeMs":-1}, "reject", "android")
sm("ack with keyframe as a string", "screen.ack", {"frame":1,"decodeMs":1,"keyframe":"true"}, "reject", "android")
sm("ack without frame", "screen.ack", {"decodeMs":1}, "reject", "android")
stats = {"latencyMs":48,"rttMs":6,"bitrate":4000000,"sentBitrate":2100000,"fps":30,"dropped":0}
sm("stats", "screen.stats", stats, {"streamId":ST,"sequence":3,**stats}, "mac", android=True)
sm("stats at the limits", "screen.stats", {"latencyMs":60000,"rttMs":60000,"bitrate":50000000,"sentBitrate":50000000,"fps":120,"dropped":1000},
   {"streamId":ST,"sequence":3,"latencyMs":60000,"rttMs":60000,"bitrate":50000000,"sentBitrate":50000000,"fps":120,"dropped":1000}, "mac")
sm("stats with fps 121", "screen.stats", {**stats, "fps":121}, "reject", "mac")
sm("stats with a negative latency", "screen.stats", {**stats, "latencyMs":-5}, "reject", "mac")
sm("stats without dropped", "screen.stats", {k:v for k,v in stats.items() if k != "dropped"}, "reject", "mac")
for reason in ["user","ended","screen_off","disabled","timeout","failed"]:
    sm("stop by the phone, " + reason, "screen.stop", {"reason":reason}, {"streamId":ST,"sequence":3,"reason":reason}, "both", android=True)
for reason in ["closed","disabled","invalid","timeout","failed"]:
    sm("stop by the Mac, " + reason, "screen.stop", {"reason":reason}, {"streamId":ST,"sequence":3,"reason":reason}, "both", mac=True)
sm("stop with an unknown reason reads as failed", "screen.stop", {"reason":"bored"}, {"streamId":ST,"sequence":3,"reason":"failed"}, "both")
sm("stop without a reason reads as failed", "screen.stop", {}, {"streamId":ST,"sequence":3,"reason":"failed"}, "both")
sm("stop over 512 bytes", "screen.stop", None, "reject", "both",
   raw=sized('{"version":1,"streamId":"%s","sequence":3,"reason":"user","pad":"' % ST, 513))
sm("stop with a stream ID that is not a UUID", "screen.stop", {"streamId":"x","reason":"user"}, "reject", "both")
sm("stop lenient JSON", "screen.stop", None, "reject", "both", raw="{version:1,streamId:'%s',sequence:3,reason:'user'}" % ST)

import uuid as _uuid
sframe = []
def header(flags, part, seq, frame, capture, version=1, stream=ST):
    return (bytes([version, flags]) + part.to_bytes(2, "big") + _uuid.UUID(stream).bytes + seq.to_bytes(8, "big")
            + frame.to_bytes(4, "big") + capture.to_bytes(8, "big"))
SPS_PPS_IDR = bytes.fromhex("0000000167640028acd940780227e5c044000003000400000300c83c60c658") + bytes.fromhex("0000000168ebe3cb22c0") + bytes.fromhex("0000000165888400")
P_SLICE = bytes.fromhex("00000001419a2a")
def sf(name, plaintext, expect, android=False, pad_to=None):
    v = {"name":name, "plaintextHex": plaintext.hex()}
    if pad_to: v["padTo"] = pad_to
    v["expect"] = expect
    if android: v["android"] = True
    sframe.append(v)
def fx(flags, part, seq, frame, capture, payload):
    return {"streamId":ST,"sequence":seq,"frame":frame,"part":part,"key":bool(flags & 1),"parameterSets":bool(flags & 2),"last":bool(flags & 4),
            "captureMicros":capture,"payloadHex":payload.hex()}
sf("key frame with SPS and PPS in one part", header(7,0,2,1,1000000) + SPS_PPS_IDR, fx(7,0,2,1,1000000,SPS_PPS_IDR), android=True)
sf("P frame in one part", header(4,0,5,4,1100000) + P_SLICE, fx(4,0,5,4,1100000,P_SLICE), android=True)
sf("first part of a split frame", header(3,0,6,5,1133333) + SPS_PPS_IDR[:20], fx(3,0,6,5,1133333,SPS_PPS_IDR[:20]), android=True)
sf("middle part needs no start code", header(3,1,7,5,1133333) + bytes.fromhex("aabbcc"), fx(3,1,7,5,1133333,bytes.fromhex("aabbcc")), android=True)
sf("three-byte start code", header(4,0,8,6,1166666) + bytes.fromhex("000001419a"), fx(4,0,8,6,1166666,bytes.fromhex("000001419a")))
sf("reserved flag bits are ignored", header(0xF4,0,9,7,1) + P_SLICE, fx(4,0,9,7,1,P_SLICE))
sf("largest sequence, frame, part and capture time", header(0,63,9007199254740991,4294967295,9223372036854775807) + b"\x01",
   fx(0,63,9007199254740991,4294967295,9223372036854775807,b"\x01"))
sf("capture time 2^63", header(4,0,2,1,9223372036854775808) + P_SLICE, "reject")
sf("payload of 32,768 bytes", header(0,1,10,8,1) + b"\x00", {"streamId":ST,"sequence":10,"frame":8,"part":1,"key":False,"parameterSets":False,"last":False,"captureMicros":1,"payloadLength":32768}, pad_to=40+32768)
sf("payload of 32,769 bytes", header(0,1,10,8,1) + b"\x00", "reject", pad_to=40+32769)
sf("header only, no payload", header(4,0,2,1,1), "reject")
sf("shorter than the header", header(4,0,2,1,1)[:39], "reject")
sf("version 2", header(4,0,2,1,1,version=2) + P_SLICE, "reject")
sf("version 0", header(4,0,2,1,1,version=0) + P_SLICE, "reject")
sf("part 64", header(4,64,2,1,1) + b"\x01", "reject")
sf("sequence 0", header(4,0,0,1,1) + P_SLICE, "reject")
sf("sequence 2^53", header(4,0,9007199254740992,1,1) + P_SLICE, "reject")
sf("frame 0", header(4,0,2,0,1) + P_SLICE, "reject")
sf("part 0 without a start code", header(4,0,2,1,1) + bytes.fromhex("419a2a"), "reject")
sf("part 0 with a broken start code", header(4,0,2,1,1) + bytes.fromhex("00000201419a"), "reject")


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
    d.update({"target":None,"targetBuild":None,"progress":None,"reason":None,"auto":False,"busy":None})
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
# Update all devices automatically: optional auto (the setting is on) and busy (what the person is doing there).
us("automatic updates on", {**base,"auto":True}, e(auto=True), write=True)
for activity in ["call","screen_share","remote_control","transfer","phone_files","setup"]:
    us("busy: " + activity, {**base,"auto":True,"busy":activity}, e(auto=True,busy=activity), write=True)
us("auto false written out", {**base,"auto":False}, e())
us("an unknown busy reads as other (still busy)", {**base,"busy":"karaoke"}, e(busy="other"))
us("busy null counts as absent", {**base,"busy":None,"auto":None}, e())
us("auto as a string", {**base,"auto":"true"}, "reject")
us("auto as a number", {**base,"auto":1}, "reject")
us("busy as a boolean", {**base,"busy":True}, "reject")
us("busy as a number", {**base,"busy":1}, "reject")
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
ut("update now", {"version":1,"requestId":R2}, {"requestId":R2,"retry":False,"auto":False}, write=True)
ut("retry after Retry was tapped", {"version":1,"requestId":R2,"retry":True}, {"requestId":R2,"retry":True,"auto":False}, write=True)
ut("retry false written out", {"version":1,"requestId":R2,"retry":False}, {"requestId":R2,"retry":False,"auto":False})
ut("an uppercase request ID is read lowercased", {"version":1,"requestId":R2.upper()}, {"requestId":R2,"retry":False,"auto":False})
ut("unknown fields are ignored (a version or URL is never read)", {"version":1,"requestId":R2,"url":"https://example.com/evil.apk","target":"9.9.9"}, {"requestId":R2,"retry":False,"auto":False})
ut("started automatically", {"version":1,"requestId":R2,"auto":True}, {"requestId":R2,"retry":False,"auto":True}, write=True)
ut("auto false written out", {"version":1,"requestId":R2,"auto":False}, {"requestId":R2,"retry":False,"auto":False})
ut("auto null counts as absent", {"version":1,"requestId":R2,"auto":None}, {"requestId":R2,"retry":False,"auto":False})
ut("auto as a string", {"version":1,"requestId":R2,"auto":"true"}, "reject")
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

# Text messages (sms_draft1, docs/protocol.md "Text messages"). smsRequest, smsSend: decoded by the phone. smsStatus,
# smsMessage, smsSendStatus: decoded by the Mac. Expected values are normalised: absent optionals are null.
R2 = "5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293"
smsreq = []
def sms_q(name, kind, p, expect, raw=False): smsreq.append({"name":name, "kind":kind, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
sms_q("threads, newest", "sms.threads", {"version":1,"requestId":R2,"limit":30}, {"requestId":R2,"limit":30,"before":None})
sms_q("threads, older page", "sms.threads", {"version":1,"requestId":R2.upper(),"limit":50,"before":1761500000000}, {"requestId":R2,"limit":50,"before":1761500000000})
sms_q("threads, null before is absent", "sms.threads", {"version":1,"requestId":R2,"limit":1,"before":None}, {"requestId":R2,"limit":1,"before":None})
sms_q("threads, limit 0", "sms.threads", {"version":1,"requestId":R2,"limit":0}, "reject")
sms_q("threads, limit 51", "sms.threads", {"version":1,"requestId":R2,"limit":51}, "reject")
sms_q("threads, negative before", "sms.threads", {"version":1,"requestId":R2,"limit":5,"before":-1}, "reject")
sms_q("threads, limit written as 30.0", "sms.threads", '{"version":1,"requestId":"%s","limit":30.0}' % R2, {"requestId":R2,"limit":30,"before":None}, raw=True)
sms_q("messages, newest", "sms.messages", {"version":1,"requestId":R2,"threadId":12,"limit":50}, {"requestId":R2,"threadId":12,"limit":50,"before":None})
sms_q("messages, older page", "sms.messages", {"version":1,"requestId":R2,"threadId":12,"limit":100,"before":{"date":1761500000000,"id":"m45"}},
   {"requestId":R2,"threadId":12,"limit":100,"before":{"date":1761500000000,"id":"m45"}})
sms_q("messages, before id not a message id", "sms.messages", {"version":1,"requestId":R2,"threadId":12,"limit":5,"before":{"date":1,"id":"x45"}}, "reject")
sms_q("messages, before without date", "sms.messages", {"version":1,"requestId":R2,"threadId":12,"limit":5,"before":{"id":"s1"}}, "reject")
sms_q("messages, threadId 0", "sms.messages", {"version":1,"requestId":R2,"threadId":0,"limit":5}, "reject")
sms_q("messages, threadId missing", "sms.messages", {"version":1,"requestId":R2,"limit":5}, "reject")
sms_q("messages, limit 101", "sms.messages", {"version":1,"requestId":R2,"threadId":3,"limit":101}, "reject")
sms_q("sync", "sms.sync", {"version":1,"requestId":R2,"since":{"sms":1200,"mms":45},"limit":100}, {"requestId":R2,"since":{"sms":1200,"mms":45},"limit":100})
sms_q("sync from zero", "sms.sync", {"version":1,"requestId":R2,"since":{"sms":0,"mms":0},"limit":200}, {"requestId":R2,"since":{"sms":0,"mms":0},"limit":200})
sms_q("sync, since missing", "sms.sync", {"version":1,"requestId":R2,"limit":100}, "reject")
sms_q("sync, mms missing", "sms.sync", {"version":1,"requestId":R2,"since":{"sms":1},"limit":100}, "reject")
sms_q("sync, negative cursor", "sms.sync", {"version":1,"requestId":R2,"since":{"sms":-1,"mms":0},"limit":100}, "reject")
sms_q("sync, limit 201", "sms.sync", {"version":1,"requestId":R2,"since":{"sms":1,"mms":0},"limit":201}, "reject")
sms_q("attachment", "sms.attachment", {"version":1,"requestId":R2,"partId":"p77"}, {"requestId":R2,"partId":"p77"})
sms_q("attachment, not a part id", "sms.attachment", {"version":1,"requestId":R2,"partId":"../77"}, "reject")
sms_q("attachment, part id of 21 characters", "sms.attachment", {"version":1,"requestId":R2,"partId":"p"+"1"*20}, "reject")
sms_q("contacts", "sms.contacts", {"version":1,"requestId":R2,"query":"  Anna "}, {"requestId":R2,"query":"Anna"})
sms_q("contacts, unicode", "sms.contacts", {"version":1,"requestId":R2,"query":"Аня"}, {"requestId":R2,"query":"Аня"})
sms_q("contacts, only spaces", "sms.contacts", {"version":1,"requestId":R2,"query":"   "}, "reject")
sms_q("contacts, 65 characters", "sms.contacts", {"version":1,"requestId":R2,"query":"a"*65}, "reject")
sms_q("requestId not a UUID", "sms.threads", {"version":1,"requestId":"page-1","limit":5}, "reject")
sms_q("version 2", "sms.threads", {"version":2,"requestId":R2,"limit":5}, "reject")
sms_q("version missing", "sms.sync", {"requestId":R2,"since":{"sms":1,"mms":0},"limit":100}, "reject")
sms_q("unknown fields are ignored", "sms.threads", {"version":1,"requestId":R2,"limit":5,"filter":"unread"}, {"requestId":R2,"limit":5,"before":None})
sms_q("over 1 KiB", "sms.threads", sized('{"version":1,"requestId":"%s","limit":5,"pad":"' % R2, 1025), "reject", raw=True)
sms_q("exactly 1 KiB", "sms.threads", sized('{"version":1,"requestId":"%s","limit":5,"pad":"' % R2, 1024), {"requestId":R2,"limit":5,"before":None}, raw=True)
sms_q("lenient JSON", "sms.threads", "{version:1,requestId:'%s',limit:5}" % R2, "reject", raw=True)
# Managing conversations from the Mac: mark read through the phone's notification action, and Android's Blocked numbers screen.
sms_q("mark read, one conversation", "sms.mark_read", {"version":1,"requestId":R2,"threadIds":[12]}, {"requestId":R2,"threadIds":[12]})
sms_q("mark read, several, repeats count once", "sms.mark_read", {"version":1,"requestId":R2.upper(),"threadIds":[12,7,12,3]}, {"requestId":R2,"threadIds":[12,7,3]})
sms_q("mark read, 50 conversations", "sms.mark_read", {"version":1,"requestId":R2,"threadIds":list(range(1,51))}, {"requestId":R2,"threadIds":list(range(1,51))})
sms_q("mark read, 51 conversations", "sms.mark_read", {"version":1,"requestId":R2,"threadIds":list(range(1,52))}, "reject")
sms_q("mark read, none", "sms.mark_read", {"version":1,"requestId":R2,"threadIds":[]}, "reject")
sms_q("mark read, threadId 0", "sms.mark_read", {"version":1,"requestId":R2,"threadIds":[4,0]}, "reject")
sms_q("mark read, threadId as a string", "sms.mark_read", {"version":1,"requestId":R2,"threadIds":["4"]}, "reject")
sms_q("mark read, threadIds not an array", "sms.mark_read", {"version":1,"requestId":R2,"threadIds":4}, "reject")
sms_q("mark read, threadIds missing", "sms.mark_read", {"version":1,"requestId":R2}, "reject")
sms_q("blocked numbers", "sms.blocked_numbers", {"version":1,"requestId":R2}, {"requestId":R2,"address":None})
sms_q("blocked numbers with the number", "sms.blocked_numbers", {"version":1,"requestId":R2,"address":"+91 98765-43210"}, {"requestId":R2,"address":"+919876543210"})
sms_q("blocked numbers, null number is absent", "sms.blocked_numbers", {"version":1,"requestId":R2,"address":None}, {"requestId":R2,"address":None})
sms_q("blocked numbers, a sender name is not a number", "sms.blocked_numbers", {"version":1,"requestId":R2,"address":"HDFCBK"}, "reject")
sms_q("blocked numbers, number as a number", "sms.blocked_numbers", {"version":1,"requestId":R2,"address":5550100}, "reject")

smssend = []
def sms_s(name, p, expect, raw=False): smssend.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
def sx(body, threadId=None, address=None, notificationId=None, subId=None):
    return {"requestId":R2,"body":body,"threadId":threadId,"address":address,"notificationId":notificationId,"subId":subId}
sms_s("to a conversation", {"version":1,"requestId":R2,"body":"On my way","threadId":12}, sx("On my way", threadId=12))
sms_s("to a conversation from a chosen SIM", {"version":1,"requestId":R2,"body":"Ok","threadId":12,"subId":2}, sx("Ok", threadId=12, subId=2))
sms_s("to a new number", {"version":1,"requestId":R2,"body":"Hello","address":"+91 98765-43210"}, sx("Hello", address="+919876543210"))
sms_s("number with brackets and dots", {"version":1,"requestId":R2,"body":"Hi","address":"(022) 555.0101"}, sx("Hi", address="0225550101"))
sms_s("a reply to a notification", {"version":1,"requestId":R2,"body":"Thanks!","notificationId":"a1b2"}, sx("Thanks!", notificationId="a1b2"))
sms_s("body keeps its spaces and lines", {"version":1,"requestId":R2,"body":"  two\nlines ","threadId":1}, sx("  two\nlines ", threadId=1))
sms_s("body of 2,000 units", {"version":1,"requestId":R2,"body":"a"*2000,"threadId":1}, sx("a"*2000, threadId=1))
sms_s("body of 2,001 units", {"version":1,"requestId":R2,"body":"a"*2001,"threadId":1}, "reject")
sms_s("emoji count as two units", {"version":1,"requestId":R2,"body":"\U0001F600"*1000,"threadId":1}, sx("\U0001F600"*1000, threadId=1))
sms_s("1,001 emoji", {"version":1,"requestId":R2,"body":"\U0001F600"*1001,"threadId":1}, "reject")
sms_s("empty body", {"version":1,"requestId":R2,"body":"","threadId":1}, "reject")
sms_s("body of spaces", {"version":1,"requestId":R2,"body":" \n ","threadId":1}, "reject")
sms_s("no target", {"version":1,"requestId":R2,"body":"Hi"}, "reject")
sms_s("two targets", {"version":1,"requestId":R2,"body":"Hi","threadId":1,"address":"+15550100"}, "reject")
sms_s("null targets count as absent", {"version":1,"requestId":R2,"body":"Hi","threadId":None,"address":"5550100","notificationId":None}, sx("Hi", address="5550100"))
sms_s("letters in the number", {"version":1,"requestId":R2,"body":"Hi","address":"HDFCBK"}, "reject")
sms_s("plus in the middle", {"version":1,"requestId":R2,"body":"Hi","address":"55+50100"}, "reject")
sms_s("one digit", {"version":1,"requestId":R2,"body":"Hi","address":"5"}, "reject")
sms_s("21 digits", {"version":1,"requestId":R2,"body":"Hi","address":"1"*21}, "reject")
sms_s("threadId 0", {"version":1,"requestId":R2,"body":"Hi","threadId":0}, "reject")
sms_s("empty notificationId", {"version":1,"requestId":R2,"body":"Hi","notificationId":""}, "reject")
sms_s("notificationId of 513", {"version":1,"requestId":R2,"body":"Hi","notificationId":"n"*513}, "reject")
sms_s("subId as a string", {"version":1,"requestId":R2,"body":"Hi","threadId":1,"subId":"2"}, "reject")
sms_s("negative subId", {"version":1,"requestId":R2,"body":"Hi","threadId":1,"subId":-1}, "reject")
sms_s("null subId is absent", {"version":1,"requestId":R2,"body":"Hi","threadId":1,"subId":None}, sx("Hi", threadId=1))
sms_s("requestId not a UUID", {"version":1,"requestId":"send-1","body":"Hi","threadId":1}, "reject")
sms_s("version 2", {"version":2,"requestId":R2,"body":"Hi","threadId":1}, "reject")
sms_s("over 8 KiB", sized('{"version":1,"requestId":"%s","body":"Hi","threadId":1,"pad":"' % R2, 8193), "reject", raw=True)
sms_s("lenient JSON", "{version:1,requestId:'%s',body:'Hi',threadId:1}" % R2, "reject", raw=True)

smsstatus = []
def sms_st(name, p, expect, raw=False): smsstatus.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
SIM1 = {"subId":1,"slot":0,"label":"Jio"}
SIM2 = {"subId":2,"slot":1,"label":"Airtel"}
sms_st("dual SIM, everything allowed", {"version":1,"read":True,"send":True,"contacts":True,"sims":[SIM1,SIM2],"cursor":{"sms":1200,"mms":45}},
   {"read":True,"send":True,"contacts":True,"sims":[SIM1,SIM2],"cursor":{"sms":1200,"mms":45}})
sms_st("nothing allowed yet, no SIM list", {"version":1,"read":False,"send":False,"contacts":False,"sims":[],"cursor":{"sms":0,"mms":0}},
   {"read":False,"send":False,"contacts":False,"sims":[],"cursor":{"sms":0,"mms":0}})
sms_st("sims missing reads as none", {"version":1,"read":True,"send":False,"contacts":False,"cursor":{"sms":3,"mms":0}},
   {"read":True,"send":False,"contacts":False,"sims":[],"cursor":{"sms":3,"mms":0}})
sms_st("more than 4 SIM entries", {"version":1,"read":True,"send":True,"contacts":True,"sims":[{"subId":"1","slot":0,"label":"x"},{"subId":3,"slot":4,"label":"x"},{"subId":4,"slot":0,"label":"l"*65},{"subId":5,"slot":1},SIM2],"cursor":{"sms":1,"mms":1}},
   "reject")
sms_st("invalid SIM entries are dropped", {"version":1,"read":True,"send":True,"contacts":True,"sims":[{"subId":"1","slot":0,"label":"x"},{"subId":3,"slot":4,"label":"x"},{"subId":5,"slot":1},SIM2],"cursor":{"sms":1,"mms":1}},
   {"read":True,"send":True,"contacts":True,"sims":[SIM2],"cursor":{"sms":1,"mms":1}})
sms_st("unicode SIM label", {"version":1,"read":True,"send":True,"contacts":True,"sims":[{"subId":7,"slot":0,"label":"МТС"}],"cursor":{"sms":1,"mms":0}},
   {"read":True,"send":True,"contacts":True,"sims":[{"subId":7,"slot":0,"label":"МТС"}],"cursor":{"sms":1,"mms":0}})
sms_st("read as a number", {"version":1,"read":1,"send":True,"contacts":True,"sims":[],"cursor":{"sms":1,"mms":0}}, "reject")
sms_st("cursor missing", {"version":1,"read":True,"send":True,"contacts":True,"sims":[]}, "reject")
sms_st("negative cursor", {"version":1,"read":True,"send":True,"contacts":True,"sims":[],"cursor":{"sms":-5,"mms":0}}, "reject")
sms_st("version 2", {"version":2,"read":True,"send":True,"contacts":True,"sims":[],"cursor":{"sms":1,"mms":0}}, "reject")
sms_st("over 2 KiB", sized('{"version":1,"read":true,"send":true,"contacts":true,"sims":[],"cursor":{"sms":1,"mms":0},"pad":"', 2049), "reject", raw=True)
sms_st("lenient JSON", "{version:1,read:true,send:true,contacts:true,sims:[],cursor:{sms:1,mms:0}}", "reject", raw=True)

smsmsg = []
def sms_m(name, p, expect, raw=False): smsmsg.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
def mx(id="s101", threadId=12, direction="in", status="received", date=1761500000000, address="+919876543210", body="See you at 6",
       truncated=False, subId=None, read=True, parts=None):
    return {"id":id,"threadId":threadId,"direction":direction,"status":status,"date":date,"address":address,"body":body,
            "truncated":truncated,"subId":subId,"read":read,"parts":parts or []}
base = {"id":"s101","threadId":12,"direction":"in","status":"received","date":1761500000000,"address":"+919876543210","body":"See you at 6"}
sms_m("received SMS", base, mx())
sms_m("unread, on SIM 2", {**base,"read":False,"subId":2}, mx(read=False, subId=2))
sms_m("sent and delivered", {**base,"id":"s102","direction":"out","status":"delivered"}, mx(id="s102", direction="out", status="delivered"))
for status in ["pending","sent","failed"]:
    sms_m("outgoing " + status, {**base,"direction":"out","status":status}, mx(direction="out", status=status))
sms_m("unknown status, incoming, reads as received", {**base,"status":"seen"}, mx())
sms_m("unknown status, outgoing, reads as sent", {**base,"direction":"out","status":"seen"}, mx(direction="out", status="sent"))
sms_m("status missing reads as the direction's default", {k:v for k,v in base.items() if k != "status"}, mx())
sms_m("MMS with an image", {**base,"id":"m45","body":"","parts":[{"partId":"p77","mimeType":"image/jpeg","size":120034}]},
   mx(id="m45", body="", parts=[{"partId":"p77","mimeType":"image/jpeg","size":120034}]))
sms_m("outgoing MMS has no address", {**base,"id":"m46","direction":"out","status":"sent","address":"","parts":[{"partId":"p78","mimeType":"image/png"}]},
   mx(id="m46", direction="out", status="sent", address="", parts=[{"partId":"p78","mimeType":"image/png","size":None}]))
sms_m("parts that are not images or not valid are dropped", {**base,"id":"m47","parts":[{"partId":"p1","mimeType":"text/plain"},{"partId":"q2","mimeType":"image/gif"},
   {"partId":"p3","mimeType":"image/gif","size":-4},"p4",{"partId":"p5","mimeType":"image/jpeg"}]},
   mx(id="m47", parts=[{"partId":"p3","mimeType":"image/gif","size":None},{"partId":"p5","mimeType":"image/jpeg","size":None}]))
sms_m("only the first 8 images", {**base,"id":"m48","parts":[{"partId":"p%d" % i,"mimeType":"image/jpeg"} for i in range(10)]},
   mx(id="m48", parts=[{"partId":"p%d" % i,"mimeType":"image/jpeg","size":None} for i in range(8)]))
sms_m("cut body", {**base,"body":"b"*4000,"truncated":True}, mx(body="b"*4000, truncated=True))
sms_m("body of 4,001 units", {**base,"body":"b"*4001}, "reject")
sms_m("negative subId reads as none", {**base,"subId":-1}, mx())
sms_m("read not a boolean reads as read", {**base,"read":0}, mx())
sms_m("truncated not a boolean reads as false", {**base,"truncated":"yes"}, mx())
sms_m("unknown fields are ignored", {**base,"reactions":["+1"]}, mx())
sms_m("id of another kind", {**base,"id":"x101"}, "reject")
sms_m("id of 21 characters", {**base,"id":"s"+"1"*20}, "reject")
sms_m("threadId 0", {**base,"threadId":0}, "reject")
sms_m("direction both", {**base,"direction":"both"}, "reject")
sms_m("date missing", {k:v for k,v in base.items() if k != "date"}, "reject")
sms_m("date as a string", {**base,"date":"1761500000000"}, "reject")
sms_m("address missing", {k:v for k,v in base.items() if k != "address"}, "reject")
sms_m("address of 65", {**base,"address":"1"*65}, "reject")
sms_m("body as a number", {**base,"body":5}, "reject")
sms_m("not an object", ["s101"], "reject")

smssent = []
def sms_d(name, p, expect, raw=False): smssent.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
def dx(status, reason=None, via=None): return {"requestId":R2,"status":status,"reason":reason,"via":via}
sms_d("sending", {"version":1,"requestId":R2,"status":"sending","via":"sms"}, dx("sending", via="sms"))
sms_d("sent through the messaging app", {"version":1,"requestId":R2.upper(),"status":"sent","via":"app"}, dx("sent", via="app"))
sms_d("delivered", {"version":1,"requestId":R2,"status":"delivered","via":"sms"}, dx("delivered", via="sms"))
for reason in ["disabled","permission","invalid","group","no_sim","rate_limited","not_found"]:
    sms_d("refused " + reason, {"version":1,"requestId":R2,"status":"refused","reason":reason}, dx("refused", reason))
for reason in ["radio_off","no_service","failed"]:
    sms_d("failed " + reason, {"version":1,"requestId":R2,"status":"failed","reason":reason,"via":"sms"}, dx("failed", reason, "sms"))
sms_d("an unknown reason reads as failed", {"version":1,"requestId":R2,"status":"failed","reason":"cosmic_rays"}, dx("failed", "failed"))
sms_d("a missing reason reads as failed", {"version":1,"requestId":R2,"status":"refused"}, dx("refused", "failed"))
sms_d("a reason on sent is ignored", {"version":1,"requestId":R2,"status":"sent","reason":"group"}, dx("sent"))
sms_d("an unknown via is ignored", {"version":1,"requestId":R2,"status":"sent","via":"pigeon"}, dx("sent"))
sms_d("unknown status", {"version":1,"requestId":R2,"status":"read"}, "reject")
sms_d("status missing", {"version":1,"requestId":R2}, "reject")
sms_d("requestId not a UUID", {"version":1,"requestId":"send-1","status":"sent"}, "reject")
sms_d("version 2", {"version":2,"requestId":R2,"status":"sent"}, "reject")
sms_d("over 1 KiB", sized('{"version":1,"requestId":"%s","status":"sent","pad":"' % R2, 1025), "reject", raw=True)
sms_d("lenient JSON", "{version:1,requestId:'%s',status:'sent'}" % R2, "reject", raw=True)

smsmark = []
def sms_mr(name, p, expect, raw=False): smsmark.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
def mrx(results, error=None): return {"requestId":R2,"results":[{"threadId":t,"result":r} for t, r in results],"error":error}
sms_mr("every result", {"version":1,"requestId":R2,"results":[{"threadId":12,"result":"marked"},{"threadId":7,"result":"not_shown"},{"threadId":3,"result":"no_action"},{"threadId":9,"result":"failed"}]},
   mrx([(12,"marked"),(7,"not_shown"),(3,"no_action"),(9,"failed")]))
sms_mr("disabled on the phone", {"version":1,"requestId":R2.upper(),"results":[],"error":"disabled"}, mrx([], "disabled"))
sms_mr("results missing reads as none", {"version":1,"requestId":R2,"error":"disabled"}, mrx([], "disabled"))
sms_mr("an unknown result reads as failed", {"version":1,"requestId":R2,"results":[{"threadId":12,"result":"snoozed"}]}, mrx([(12,"failed")]))
sms_mr("invalid entries are dropped", {"version":1,"requestId":R2,"results":[{"threadId":0,"result":"marked"},{"threadId":"5","result":"marked"},{"threadId":6},"x",{"threadId":8,"result":"marked"}]},
   mrx([(8,"marked")]))
sms_mr("an unknown error is ignored", {"version":1,"requestId":R2,"results":[{"threadId":1,"result":"marked"}],"error":"x"*40}, mrx([(1,"marked")]))
sms_mr("results not an array", {"version":1,"requestId":R2,"results":{"threadId":1,"result":"marked"}}, "reject")
sms_mr("more than 50 entries", {"version":1,"requestId":R2,"results":[{"threadId":i,"result":"marked"} for i in range(1,52)]}, "reject")
sms_mr("requestId not a UUID", {"version":1,"requestId":"mark-1","results":[]}, "reject")
sms_mr("version 2", {"version":2,"requestId":R2,"results":[]}, "reject")
sms_mr("over 4 KiB", sized('{"version":1,"requestId":"%s","results":[],"pad":"' % R2, 4097), "reject", raw=True)
sms_mr("lenient JSON", "{version:1,requestId:'%s',results:[]}" % R2, "reject", raw=True)

smsblock = []
def sms_b(name, p, expect, raw=False): smsblock.append({"name":name, ("plaintextString" if raw else "plaintext"):p, "expect":expect})
for outcome in ["opened","notified","unavailable"]:
    sms_b(outcome, {"version":1,"requestId":R2,"result":outcome}, {"requestId":R2,"result":outcome})
sms_b("an unknown result reads as unavailable", {"version":1,"requestId":R2.upper(),"result":"blocked"}, {"requestId":R2,"result":"unavailable"})
sms_b("result missing", {"version":1,"requestId":R2}, "reject")
sms_b("requestId not a UUID", {"version":1,"requestId":"block-1","result":"opened"}, "reject")
sms_b("version 2", {"version":2,"requestId":R2,"result":"opened"}, "reject")
sms_b("over 1 KiB", sized('{"version":1,"requestId":"%s","result":"opened","pad":"' % R2, 1025), "reject", raw=True)

out = {
  "description": "Bridgey Protocol v1 golden vectors. Android (ProtocolGoldenVectorsTest) and macOS (ProtocolGoldenVectorsTests) decode every vector and must get the same expected result. Frames: 'line' is one frame without its line ending (default LF; 'lineEnding' overrides); 'lineBase64' gives raw bytes; 'nest': N builds {\"kind\":\"x.y\",\"sessionId\":S,\"x\":[[...]]} nested N deep (the outer object is 1); 'padTo': N builds a pairing.offer whose deviceName is 'a' repeated until the frame is N bytes, and '@PAD@' in expect stands for that name. Payload 'plaintext' is serialised by each platform's own JSON encoder; 'plaintextString' is used byte for byte. offerId values compare lowercased. browseRef: a Files 2.0 ref object; expect is the ref both platforms read, or reject. Automation (v0.9): focusState is decoded by both platforms; actionsCatalog, actionsResult and cameraRequest by the phone, actionsRun and cameraStatus by the Mac. 'android' or 'mac' on a vector says that platform also writes exactly that plaintext: android {action, value?, sequence?} for actionsRun (requestId and sequence from the plaintext), android <status> for cameraStatus; mac {switches, apps, shortcuts, accessibilityTrusted} for actionsCatalog (ids, blocked and the app and Shortcut titles; the volume comes from the output device), mac {outcome, reason?, volume?} for actionsResult, mac true for cameraRequest. Update all: updatesStatus, updatesStart and updatesResult are decoded by both platforms; absent optional values are null in expect (auto and retry: false), and 'write': true means both platforms also write exactly that plaintext from the expected value. Screen sharing (v0.9): screenRequest is decoded by the phone (mac true: the Mac writes it), screenStatus by the Mac (android <status>: the phone writes it). screenStream vectors carry 'kind' and 'decoder' (mac, android or both); expect lists every field, requestId null when absent, keyframe false when absent; 'android' or 'mac' true means that platform writes exactly that plaintext. screenFrame: 'plaintextHex' is the frame plaintext; 'padTo': N appends zero bytes until it is N bytes long; expect is the decoded header with payloadHex, or payloadLength for padded vectors, or reject; 'android' true means the phone's writer produces exactly those bytes. UUIDs compare lowercased. In actionsRun, value null is absent and 'other' is present but not an integer. Text messages (sms_draft1): smsRequest (each vector names its kind) and smsSend are decoded by the phone, smsStatus, smsMessage (one message object of a page), smsSendStatus, smsMarkReadResult and smsBlockedNumbersResult by the Mac (the phone also writes exactly the expected plaintext for each valid one); requestId values compare lowercased, absent optionals expect null, lengths count UTF-16 units.",
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
  "screenRequest": screq,
  "screenStatus": scstat,
  "screenStream": sstream,
  "screenFrame": sframe,
  "smsRequest": smsreq,
  "smsSend": smssend,
  "smsStatus": smsstatus,
  "smsMessage": smsmsg,
  "smsSendStatus": smssent,
  "smsMarkReadResult": smsmark,
  "smsBlockedNumbersResult": smsblock,
}
open(OUT,'w').write(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
print(len(frames), len(feat), len(batt), len(rich), len(offers), len(inp), len(refs), len(focus), len(catalog), len(run), len(result), len(camreq), len(camstat), len(st), len(ustart), len(uresult),
      len(screq), len(scstat), len(sstream), len(sframe),
      len(smsreq), len(smssend), len(smsstatus), len(smsmsg), len(smssent), len(smsmark), len(smsblock))
