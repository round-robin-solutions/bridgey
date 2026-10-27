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
drafts_none = {"clipboard_files_draft1":False,"folders_draft1":False,"places_draft1":False,"sms_codes_draft1":False}
feat = []
def fe(name, plaintext, expect, raw=False):
    feat.append({"name": name, ("plaintextString" if raw else "plaintext"): plaintext, "expect": expect})
fe("edition Mac", {"version":1,"features":{**features_all,"clipboard_files_draft1":True,"folders_draft1":True,"places_draft1":False,"sms_codes_draft1":True}},
   {"features":features_all,"drafts":{"clipboard_files_draft1":True,"folders_draft1":True,"places_draft1":False,"sms_codes_draft1":True}})
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

out = {
  "description": "Bridgey Protocol v1 golden vectors. Android (ProtocolGoldenVectorsTest) and macOS (ProtocolGoldenVectorsTests) decode every vector and must get the same expected result. Frames: 'line' is one frame without its line ending (default LF; 'lineEnding' overrides); 'lineBase64' gives raw bytes; 'nest': N builds {\"kind\":\"x.y\",\"sessionId\":S,\"x\":[[...]]} nested N deep (the outer object is 1); 'padTo': N builds a pairing.offer whose deviceName is 'a' repeated until the frame is N bytes, and '@PAD@' in expect stands for that name. Payload 'plaintext' is serialised by each platform's own JSON encoder; 'plaintextString' is used byte for byte. offerId values compare lowercased.",
  "sessionId": S,
  "frames": frames,
  "featuresUpdate": feat,
  "batteryUpdate": batt,
  "clipboardRich": rich,
  "clipboardOffer": offers,
  "remoteInput": inp,
}
open(OUT,'w').write(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
print(len(frames), len(feat), len(batt), len(rich), len(offers), len(inp))
