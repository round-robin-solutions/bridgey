//! A Mac's screen against the golden vectors the Mac and Android check (display-v1.json): what this device reads from
//! the Mac (status, start, the stream), what it writes (the request, started, ack, control, stop), the frames, the
//! connection nonce and the letterbox, and the control sender's pointer and button rules.

use super::*;

fn vectors() -> Value {
    serde_json::from_str(include_str!("../../../../protocol/test-vectors/display-v1.json")).unwrap()
}

fn group(key: &str) -> Vec<Value> {
    let list = vectors()[key].as_array().unwrap_or_else(|| panic!("{key}")).clone();
    assert!(!list.is_empty(), "{key}");
    list
}

fn plaintext(v: &Value) -> Vec<u8> {
    match v.get("plaintextString").and_then(Value::as_str) {
        Some(raw) => raw.as_bytes().to_vec(),
        None => serde_json::to_vec(&v["plaintext"]).unwrap(),
    }
}

fn hex(text: &str) -> Vec<u8> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect()
}

fn hex_string(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn check(name: &str, failed: Vec<String>) {
    assert!(failed.is_empty(), "{name} vectors this device reads or writes differently: {failed:#?}");
}

#[test]
fn status() {
    let failed: Vec<String> = group("status")
        .into_iter()
        .filter(|v| decode_status(&plaintext(v)).map(|(r, s)| json!({"requestId": r, "status": s})).unwrap_or(json!("reject")) != v["expect"])
        .map(|v| v["name"].to_string())
        .collect();
    check("status", failed);
}

/// The request as this device writes it, and its capabilities as the Mac reads them: a viewer and controller, never a
/// source or an input host.
#[test]
fn request_as_this_device_writes_it() {
    let first = &group("request")[0];
    assert_eq!(first["name"], json!("see the screen"));
    assert_eq!(request_payload(first["plaintext"]["requestId"].as_str().unwrap()), first["plaintext"]);
    let written = screen::capabilities(Some(&request_payload("3f2e1d0c-4b5a-4968-8776-a5b4c3d2e1f0")["capabilities"])).unwrap();
    assert_eq!(written, viewer_capabilities());
    assert_eq!(serde_json::to_value(written).unwrap(), first["expect"]["capabilities"]);
    assert!(!written.screen_source && !written.full_display_source && !written.h264_encode);
    assert_eq!(written.input_host, sc::InputCapabilities::default(), "never an input host");
}

#[test]
fn start() {
    let failed: Vec<String> = group("start")
        .into_iter()
        .filter(|v| {
            let got = decode_start(&plaintext(v)).map(|s| {
                json!({"streamId": s.stream_id, "sequence": s.sequence, "requestId": s.request_id, "fps": s.fps, "bitrate": s.bitrate,
                       "stream": s.stream, "transport": s.transport, "geometry": s.geometry, "capabilities": s.capabilities,
                       "control": s.control, "displayName": s.display_name})
            });
            got.unwrap_or(json!("reject")) != v["expect"]
        })
        .map(|v| v["name"].to_string())
        .collect();
    check("start", failed);
}

/// The Mac's stream messages, as this device reads them.
#[test]
fn stream_as_this_device_reads_it() {
    let mut failed = Vec::new();
    for v in group("viewerStream") {
        let p = plaintext(&v);
        let got = match v["kind"].as_str().unwrap() {
            "display.stats" => screen::decode_stats(&p).map(|s| {
                json!({"streamId": s.stream_id, "sequence": s.sequence, "latencyMs": s.latency_ms, "rttMs": s.rtt_ms, "bitrate": s.bitrate,
                       "sentBitrate": s.sent_bitrate, "fps": s.fps, "dropped": s.dropped})
            }),
            "display.geometry" => screen::decode_geometry(&p).map(|(id, seq, g)| json!({"streamId": id, "sequence": seq, "geometry": g})),
            "display.control" => decode_control(&p).map(|(id, seq, state)| match state {
                ControlState::Active { session, input } => json!({"streamId": id, "sequence": seq, "state": "active", "session": session, "input": input, "reason": null}),
                ControlState::Ended(r) => json!({"streamId": id, "sequence": seq, "state": "ended", "session": null, "input": null, "reason": r}),
                ControlState::Refused(r) => json!({"streamId": id, "sequence": seq, "state": "refused", "session": null, "input": null, "reason": r}),
            }),
            "display.stop" => decode_stop(&p).map(|(id, seq, reason)| json!({"streamId": id, "sequence": seq, "reason": reason})),
            other => panic!("{other}"),
        };
        if got.unwrap_or(json!("reject")) != v["expect"] {
            failed.push(v["name"].to_string());
        }
    }
    check("viewerStream", failed);
}

/// What this device writes on a stream, exactly as the vectors the Mac reads have it.
#[test]
fn stream_as_this_device_writes_it() {
    let mut checked = 0;
    for v in group("sourceStream").into_iter().filter(|v| v["expect"].is_object()) {
        let e = &v["expect"];
        let (id, seq) = (e["streamId"].as_str().unwrap(), e["sequence"].as_u64().unwrap());
        let written = match v["kind"].as_str().unwrap() {
            "display.started" => started_payload(id, seq),
            "display.ack" => ack_payload(id, seq, e["frame"].as_u64().unwrap() as u32, e["decodeMs"].as_u64().unwrap() as u32, e["keyframe"] == json!(true)),
            "display.control" => control_payload(id, seq, e["action"].as_str().unwrap()),
            "display.stop" if ["user", "left_screen", "screen_off"].contains(&e["reason"].as_str().unwrap()) => stop_payload(id, seq, e["reason"].as_str().unwrap()),
            // A reason only a source sends, or an unknown one this device never writes.
            _ => continue,
        };
        checked += 1;
        assert_eq!(written, v["plaintext"], "{}", v["name"]);
    }
    assert!(checked >= 7, "{checked}");
    // A stop this device reads back from the Mac's own vectors: its reasons and the unknown one.
    for v in group("sourceStream").into_iter().filter(|v| v["kind"] == json!("display.stop")) {
        let (_, _, reason) = decode_stop(&plaintext(&v)).unwrap();
        assert_eq!(json!(reason), v["expect"]["reason"], "{}", v["name"]);
    }
}

#[test]
fn frames() {
    let failed: Vec<String> = group("frame")
        .into_iter()
        .filter(|v| {
            let got = screen::decode_part(&hex(v["hex"].as_str().unwrap())).map(|p| {
                json!({"streamId": p.stream_id, "sequence": p.sequence, "frame": p.frame, "part": p.part, "key": p.key, "parameterSets": p.parameter_sets,
                       "last": p.last, "captureMicros": p.capture_micros, "payloadHex": hex_string(&p.payload)})
            });
            got.unwrap_or(json!("reject")) != v["expect"]
        })
        .map(|v| v["name"].to_string())
        .collect();
    check("frame", failed);
}

#[test]
fn connection_nonce() {
    for v in group("connection") {
        let key: [u8; 32] = hex(v["keyHex"].as_str().unwrap()).try_into().unwrap();
        let got = crate::session::screen_connection(&key, v["sessionId"].as_str().unwrap());
        assert_eq!(json!(got.to_vec()), v["expect"], "{}", v["name"]);
    }
}

#[test]
fn letterbox_vectors() {
    for v in group("letterbox") {
        let pair = |k: &str| (v[k][0].as_f64().unwrap(), v[k][1].as_f64().unwrap());
        let got = letterbox(pair("view"), pair("video"), pair("touch"));
        match v["expect"].as_array() {
            None => assert!(got.is_none(), "{}: {got:?}", v["name"]),
            Some(e) => {
                let (x, y) = got.unwrap_or_else(|| panic!("{}: on the letterbox", v["name"]));
                assert!((x - e[0].as_f64().unwrap()).abs() < 1e-9 && (y - e[1].as_f64().unwrap()).abs() < 1e-9, "{}: {x}, {y}", v["name"]);
            }
        }
    }
}

#[test]
fn kinds_and_limits() {
    for kind in ["display.status", "display.start", "display.frame", "display.stats", "display.geometry", "display.control", "display.stop"] {
        let spec = incoming(kind).unwrap();
        assert_eq!((spec.area, spec.feature), (Area::Display, FEATURE));
    }
    assert!(incoming("display.request").is_none() && incoming("display.input").is_none(), "a source's kinds are not this device's");
    assert!(is_stream("display.frame") && is_stream("display.input") && !is_stream("display.request") && !is_stream("display.status"));
}

fn binding() -> Binding {
    Binding { transport: 2, connection: [7; 16], stream: 3 }
}

fn mac_input() -> sc::InputCapabilities {
    sc::InputCapabilities { pointer: true, keys: true, text: true, ..Default::default() }
}

fn ops(packets: &[sc::Packet]) -> Vec<String> {
    packets.iter().map(|p| serde_json::to_value(&p.input).unwrap()["op"].as_str().unwrap().to_string()).collect()
}

/// Pointer motion coalesces before numbering; button transitions never do, and a release always goes.
#[test]
fn pointer_and_buttons() {
    let mut s = Sender::new(0);
    assert_eq!(ops(&s.begin(1, mac_input(), binding(), 1, 0)), ["geometry_ack"]);
    assert!(s.submit(Action::Pointer { x: 0.1, y: 0.1 }));
    assert!(s.submit(Action::Pointer { x: 0.2, y: 0.2 }));
    assert_eq!(s.pending(), 1, "two moves are one packet");
    assert!(s.submit(Action::Button { button: sc::Button::Primary, down: true, x: 0.2, y: 0.2 }));
    assert!(!s.submit(Action::Button { button: sc::Button::Primary, down: true, x: 0.2, y: 0.2 }), "already down");
    assert!(s.submit(Action::Pointer { x: 0.3, y: 0.3 }));
    assert!(s.submit(Action::Button { button: sc::Button::Primary, down: false, x: 0.3, y: 0.3 }));
    assert!(!s.submit(Action::Button { button: sc::Button::Secondary, down: false, x: 0.3, y: 0.3 }), "not held");
    assert!(!s.submit(Action::Pointer { x: 1.5, y: 0.3 }), "off the display");
    assert!(!s.submit(Action::Touch { contact: 0, phase: sc::TouchPhase::Down, x: 0.1, y: 0.1 }), "a Mac takes no touch");
    let sent = s.flush(1);
    assert_eq!(ops(&sent), ["pointer", "button", "pointer", "button"]);
    assert_eq!(sent.iter().map(|p| p.seq).collect::<Vec<_>>(), [2, 3, 4, 5]);
    assert!(sent.iter().all(|p| p.session == 1 && p.transport == 2 && p.stream == 3 && p.geometry == 1 && p.connection == [7; 16]));
    // A geometry change forgets what was held (the Mac released it) and acknowledges first.
    assert!(s.submit(Action::Button { button: sc::Button::Secondary, down: true, x: 0.5, y: 0.5 }));
    assert_eq!(ops(&s.geometry_changed(2, 2)), ["geometry_ack"]);
    assert!(s.submit(Action::Button { button: sc::Button::Secondary, down: true, x: 0.5, y: 0.5 }), "nothing is held after the change");
    assert_eq!(ops(&s.stop().into_iter().collect::<Vec<_>>()), ["stop"]);
    assert!(!s.active());
}

#[test]
fn start_needs_its_request_and_a_known_reason_set() {
    let v = &group("start")[0];
    let s = decode_start(&plaintext(v)).unwrap();
    assert!(sc::Capabilities::negotiated_input(s.capabilities, viewer_capabilities()).is_ok(), "the vector's Mac can be controlled from here");
    let input = sc::Capabilities::negotiated_input(s.capabilities, viewer_capabilities()).unwrap();
    assert_eq!(input, mac_input());
}
