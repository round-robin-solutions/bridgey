//! The phone's screen against the golden vectors the Mac and Android check (protocol-v1.json `screen*`,
//! phone-control-v1.json, display-v1.json `connection`), and the frame assembler and control sender's rules.

use super::*;

fn file(name: &str) -> Value {
    let text = match name {
        "protocol" => include_str!("../../../../protocol/test-vectors/protocol-v1.json"),
        "control" => include_str!("../../../../protocol/test-vectors/phone-control-v1.json"),
        _ => include_str!("../../../../protocol/test-vectors/display-v1.json"),
    };
    serde_json::from_str(text).unwrap()
}

fn group(name: &str, key: &str) -> Vec<Value> {
    let list = file(name)[key].as_array().unwrap_or_else(|| panic!("{key}")).clone();
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
    let failed = group("protocol", "screenStatus")
        .into_iter()
        .filter(|v| {
            let got = decode_status(&plaintext(v)).map(|s| {
                let mut o = json!({"requestId": s.request_id, "status": s.status});
                if let Some(n) = s.needs {
                    o["needs"] = json!(n);
                }
                o
            });
            got.unwrap_or(json!("reject")) != v["expect"]
        })
        .map(|v| v["name"].to_string())
        .collect();
    check("screenStatus", failed);
}

#[test]
fn request_as_this_device_writes_it() {
    let mut checked = 0;
    for v in group("protocol", "screenRequest").into_iter().filter(|v| v["mac"] == json!(true)) {
        checked += 1;
        assert_eq!(request_payload(v["plaintext"]["requestId"].as_str().unwrap()), v["plaintext"]);
    }
    assert!(checked >= 1);
}

/// The phone's stream messages (and either side's stop), as this device reads them.
#[test]
fn stream_as_this_device_reads_it() {
    let mut checked = 0;
    let mut failed = Vec::new();
    for v in group("protocol", "screenStream") {
        if !matches!(v["decoder"].as_str(), Some("mac" | "both")) {
            continue;
        }
        checked += 1;
        let p = plaintext(&v);
        let got = match v["kind"].as_str().unwrap() {
            "screen.start" => decode_start(&p).map(|s| {
                let mut o = json!({"streamId": s.stream_id, "sequence": s.sequence, "requestId": s.request_id, "codec": "h264", "width": s.width, "height": s.height, "fps": s.fps, "bitrate": s.bitrate});
                if s.screenshots {
                    o["mode"] = json!("screenshots");
                }
                o
            }),
            "screen.stats" => decode_stats(&p).map(|s| {
                json!({"streamId": s.stream_id, "sequence": s.sequence, "latencyMs": s.latency_ms, "rttMs": s.rtt_ms, "bitrate": s.bitrate, "sentBitrate": s.sent_bitrate, "fps": s.fps, "dropped": s.dropped})
            }),
            "screen.stop" => decode_stop(&p).map(|(id, seq, reason)| json!({"streamId": id, "sequence": seq, "reason": reason})),
            other => panic!("{other}"),
        };
        if got.clone().unwrap_or(json!("reject")) != v["expect"] {
            failed.push(format!("{}: {}", v["name"], got.unwrap_or(json!("reject"))));
        }
    }
    check("screenStream", failed);
    assert!(checked >= 30);
}

/// What this device writes on a stream (started, ack, stop) is exactly the plaintext the phone reads.
#[test]
fn stream_as_this_device_writes_it() {
    let mut checked = 0;
    for v in group("protocol", "screenStream").into_iter().filter(|v| v["mac"] == json!(true)) {
        checked += 1;
        let p = &v["plaintext"];
        let (id, seq) = (p["streamId"].as_str().unwrap(), p["sequence"].as_u64().unwrap());
        let written = match v["kind"].as_str().unwrap() {
            "screen.started" => started_payload(id, seq),
            "screen.ack" => ack_payload(id, seq, p["frame"].as_u64().unwrap() as u32, p["decodeMs"].as_u64().unwrap() as u32, p["keyframe"].as_bool().unwrap_or(false)),
            "screen.stop" => stop_payload(id, seq, p["reason"].as_str().unwrap()),
            other => panic!("{other}"),
        };
        assert_eq!(&written, p, "{}", v["name"]);
    }
    assert!(checked >= 8);
}

#[test]
fn frame_header() {
    let mut failed = Vec::new();
    for v in group("protocol", "screenFrame") {
        let mut data = hex(v["plaintextHex"].as_str().unwrap_or(""));
        if let Some(total) = v["padTo"].as_u64() {
            data.resize(total as usize, 0);
        }
        let got = decode_part(&data).map(|p| {
            let mut o = json!({"streamId": p.stream_id, "sequence": p.sequence, "frame": p.frame, "part": p.part, "key": p.key, "parameterSets": p.parameter_sets, "last": p.last, "captureMicros": p.capture_micros});
            if v.get("padTo").is_some() {
                o["payloadLength"] = json!(p.payload.len());
            } else {
                o["payloadHex"] = json!(hex_string(&p.payload));
            }
            o
        });
        if got.clone().unwrap_or(json!("reject")) != v["expect"] {
            failed.push(format!("{}: {}", v["name"], got.unwrap_or(json!("reject"))));
            continue;
        }
        // What the phone writes (vectors marked android) is exactly what the encoder here produces too.
        if v["android"] == json!(true) {
            if let Some(part) = decode_part(&data) {
                if encode_part(&part) != data {
                    failed.push(format!("{}: encodes differently", v["name"]));
                }
            }
        }
    }
    check("screenFrame", failed);
}

#[test]
fn start_control_objects_decode_or_make_the_stream_view_only() {
    for v in group("control", "startControl") {
        let name = v["name"].to_string();
        let start = decode_start(&plaintext(&v)).unwrap_or_else(|| panic!("{name}: the start itself stays valid"));
        match v["expect"].as_object() {
            None => assert!(start.control.is_none(), "{name}"),
            Some(e) => {
                let c = start.control.unwrap_or_else(|| panic!("{name}"));
                assert_eq!(c.stream, e["stream"].as_u64().unwrap(), "{name}");
                assert_eq!(c.transport, e["transport"].as_u64().unwrap(), "{name}");
                assert_eq!(serde_json::to_value(c.geometry).unwrap(), e["geometry"], "{name}");
                assert_eq!(c.capabilities, capabilities(Some(&e["capabilities"])).unwrap(), "{name}");
                assert_eq!(json!(c.allowed), e["allowed"], "{name}");
            }
        }
    }
}

#[test]
fn phone_stream_messages() {
    let mut failed = Vec::new();
    for v in group("control", "phoneStream") {
        let p = plaintext(&v);
        let got = match v["kind"].as_str().unwrap() {
            "screen.geometry" => decode_geometry(&p).map(|(_, _, g)| json!({"geometry": g})),
            "screen.control" => decode_control(&p).map(|(_, _, s)| match s {
                ControlState::Waiting => json!({"state": "waiting"}),
                ControlState::Active { session, input } => json!({"state": "active", "session": session, "input": input}),
                ControlState::Ended(r) => json!({"state": "ended", "reason": r}),
                ControlState::Refused(r) => json!({"state": "refused", "reason": r}),
                ControlState::Available(a) => json!({"state": "available", "allowed": a}),
            }),
            other => panic!("{other}"),
        };
        if got.clone().unwrap_or(Value::Null) != v["expect"] {
            failed.push(format!("{}: {}", v["name"], got.unwrap_or(Value::Null)));
        }
    }
    check("phoneStream", failed);
}

#[test]
fn control_as_this_device_writes_it() {
    let mut written = 0;
    for v in group("control", "macStream").into_iter().filter(|v| v["write"] == json!(true)) {
        let p = &v["plaintext"];
        let (id, seq) = (p["streamId"].as_str().unwrap(), p["sequence"].as_u64().unwrap());
        let payload = if p["action"] == json!("begin") { control_begin_payload(id, seq) } else { control_end_payload(id, seq) };
        assert_eq!(&payload, p, "{}", v["name"]);
        written += 1;
    }
    assert!(written >= 2);
}

#[test]
fn negotiated_input_with_each_phone() {
    for v in group("control", "negotiated") {
        let host = capabilities(Some(&v["host"])).unwrap();
        let controller = capabilities(Some(&v["controller"])).unwrap();
        let input = sc::Capabilities::negotiated_input(host, controller).ok();
        assert_eq!(input.map(|i| json!(i)).unwrap_or(Value::Null), v["expect"], "{}", v["name"]);
    }
    // This device offers what the Mac offers as a controller.
    let mac = group("control", "negotiated").into_iter().find(|v| v["name"] == json!("Android 16 and the Mac")).unwrap();
    assert_eq!(capabilities(Some(&mac["controller"])).unwrap(), controller_capabilities());
}

#[test]
fn connection_nonce() {
    for v in group("display", "connection") {
        let key: [u8; 32] = hex(v["keyHex"].as_str().unwrap()).try_into().unwrap();
        let nonce = crate::session::screen_connection(&key, v["sessionId"].as_str().unwrap());
        assert_eq!(json!(nonce.to_vec()), v["expect"], "{}", v["name"]);
    }
}

fn part(frame: u32, index: u16, key: bool, last: bool) -> Part {
    let payload = if index == 0 { vec![0, 0, 0, 1, 0x65, frame as u8] } else { vec![index as u8; 4] };
    Part { stream_id: "6c2e9a14-3b5d-4e7f-8a90-1b2c3d4e5f60".into(), sequence: u64::from(frame) * 10 + u64::from(index), frame, part: index, key, parameter_sets: key, last, capture_micros: 1, payload }
}

#[test]
fn assembler_puts_parts_together_and_loses_broken_frames() {
    let mut a = Assembler::default();
    assert_eq!(a.add(part(1, 0, true, false)), Assembled::Pending);
    match a.add(part(1, 1, true, true)) {
        Assembled::Complete(f) => {
            assert!(f.key);
            assert_eq!(f.data, vec![0, 0, 0, 1, 0x65, 1, 1, 1, 1, 1]);
        }
        other => panic!("{other:?}"),
    }
    // A part of a finished frame is ignored; a missing part 0 loses the frame.
    assert_eq!(a.add(part(1, 1, true, true)), Assembled::Ignored);
    assert_eq!(a.add(part(2, 1, false, true)), Assembled::Lost(2));
    // A later frame before this one finished: the earlier one is lost, and a P frame after a loss is too.
    assert_eq!(a.add(part(3, 0, false, false)), Assembled::Pending);
    assert_eq!(a.add(part(4, 0, false, true)), Assembled::Lost(4));
    // A key frame after a loss is complete.
    assert_eq!(a.add(part(5, 0, false, false)), Assembled::Pending);
    assert!(matches!(a.add(part(6, 0, true, true)), Assembled::Complete(f) if f.frame == 6));
    // Out of order within a frame.
    assert_eq!(a.add(part(7, 0, false, false)), Assembled::Pending);
    assert_eq!(a.add(part(7, 2, false, true)), Assembled::Lost(7));
}

#[test]
fn the_frame_queue_drops_what_the_host_did_not_take() {
    let q = FrameQueue::default();
    for n in 1..=QUEUED as u32 {
        assert!(q.push(Frame { frame: n, key: false, parameter_sets: false, capture_micros: 0, data: vec![1] }).is_empty());
    }
    let dropped = q.push(Frame { frame: 99, key: true, parameter_sets: true, capture_micros: 0, data: vec![2] });
    assert_eq!(dropped, (1..=QUEUED as u32).collect::<Vec<_>>());
    assert_eq!(q.take(Duration::ZERO).unwrap().unwrap().frame, 99);
    assert!(q.take(Duration::from_millis(10)).unwrap().is_none());
    q.close();
    assert!(q.take(Duration::ZERO).is_err());
}

const ALL: sc::InputCapabilities = sc::InputCapabilities { pointer: true, touch: true, keys: true, text: true, navigation: true };
const BINDING: Binding = Binding { transport: 3, connection: [7; 16], stream: 1 };

fn ops(packets: &[sc::Packet]) -> Vec<String> {
    packets.iter().map(|p| serde_json::to_value(&p.input).unwrap()["op"].as_str().unwrap().to_string()).collect()
}

#[test]
fn control_starts_with_geometry_ack_and_numbers_in_order() {
    let mut s = Sender::new(0);
    assert!(!s.submit(Action::Navigate(sc::Navigation::Home)), "no session yet");
    let first = s.begin(1, ALL, BINDING, 1, 0);
    assert_eq!(ops(&first), vec!["geometry_ack"]);
    assert_eq!((first[0].seq, first[0].geometry, first[0].connection), (1, 1, [7; 16]));
    assert!(s.submit(Action::Touch { contact: 0, phase: sc::TouchPhase::Down, x: 0.5, y: 0.5 }));
    for i in 0..10 {
        assert!(s.submit(Action::Touch { contact: 0, phase: sc::TouchPhase::Move, x: 0.5, y: 0.1 * f64::from(i) / 2.0 }));
    }
    assert!(s.submit(Action::Touch { contact: 0, phase: sc::TouchPhase::Up, x: 0.5, y: 0.45 }));
    let packets = s.flush(10);
    // Ten moves coalesced into one; numbered after geometry_ack.
    assert_eq!(ops(&packets), vec!["touch", "touch", "touch"]);
    assert_eq!(packets.iter().map(|p| p.seq).collect::<Vec<_>>(), vec![2, 3, 4]);
    // Refused: off the picture, an up without a down, Control.
    assert!(!s.submit(Action::Touch { contact: 1, phase: sc::TouchPhase::Down, x: 1.5, y: 0.5 }));
    assert!(!s.submit(Action::Touch { contact: 2, phase: sc::TouchPhase::Up, x: 0.5, y: 0.5 }));
    assert!(!s.submit(Action::Key { key: sc::Key::Control, down: true }));
    assert_eq!(s.dropped, 3);
}

#[test]
fn text_joins_keys_press_and_scroll_splits() {
    let mut s = Sender::new(0);
    s.begin(1, ALL, BINDING, 1, 0);
    assert!(s.submit(Action::Text("Hel".into())));
    assert!(s.submit(Action::Text("lo".into())));
    assert!(s.press(sc::Key::Enter, true));
    assert!(s.submit(Action::Scroll { dx: 0, dy: 1_500, x: 0.5, y: 0.5 }));
    assert!(s.submit(Action::Scroll { dx: 0, dy: 100, x: 0.5, y: 0.5 }));
    let packets = s.flush(10);
    assert_eq!(ops(&packets), vec!["text", "key", "key", "key", "key", "scroll", "scroll"]);
    let values: Vec<Value> = packets.iter().map(|p| serde_json::to_value(&p.input).unwrap()).collect();
    assert_eq!(values[0]["text"], json!("Hello"));
    assert_eq!((values[5]["dy"].clone(), values[6]["dy"].clone()), (json!(1_000), json!(600)));
    assert!(!s.submit(Action::Text("\u{7}".into())), "control characters are refused");
}

#[test]
fn rates_heartbeats_geometry_and_stop() {
    let mut s = Sender::new(0);
    s.begin(1, ALL, BINDING, 1, 0);
    for _ in 0..40 {
        s.submit(Action::Navigate(sc::Navigation::Back));
    }
    // 16 discrete packets a second: the rest wait.
    assert_eq!(s.flush(0).len(), 16);
    assert_eq!(s.pending(), 24);
    assert_eq!(s.flush(500).len(), 8);
    // A new geometry drops what has not gone and is acknowledged first.
    let ack = s.geometry_changed(2, 600);
    assert_eq!(ops(&ack), vec!["geometry_ack"]);
    assert_eq!(ack[0].geometry, 2);
    assert_eq!(s.pending(), 0);
    assert!(s.geometry_changed(2, 700).is_empty(), "the same generation once");
    // A heartbeat after 2 seconds of nothing.
    assert_eq!(ops(&s.flush(2_700)), vec!["heartbeat"]);
    // Stop is never rate limited and ends the session.
    for _ in 0..40 {
        s.submit(Action::Navigate(sc::Navigation::Home));
    }
    s.flush(2_800);
    let stop = s.stop().unwrap();
    assert_eq!(ops(&[stop]), vec!["stop"]);
    assert!(!s.active());
    // Without typing on the phone (Android 12), text and keys are refused.
    let mut old = Sender::new(0);
    old.begin(1, sc::InputCapabilities { touch: true, pointer: true, navigation: true, ..Default::default() }, BINDING, 1, 0);
    assert!(!old.submit(Action::Text("a".into())));
    assert!(!old.press(sc::Key::Enter, false));
}

#[test]
fn packets_decode_as_the_contract_reads_them() {
    let mut s = Sender::new(0);
    let packets = s.begin(4, ALL, BINDING, 1, 0);
    let bytes = serde_json::to_vec(&packets[0]).unwrap();
    assert!(bytes.len() <= sc::MAX_PACKET_BYTES);
    assert_eq!(sc::Packet::decode(&bytes).unwrap(), packets[0]);
}

#[test]
fn the_simulated_clip_splits_into_ten_frames() {
    let frames = sim_frames();
    assert_eq!(frames.len(), 10);
    assert_eq!(frames.iter().map(|f| f.0).collect::<Vec<_>>(), vec![true, false, false, false, false, true, false, false, false, false]);
    assert!(frames[0].1 && frames[5].1);
    assert!(frames.iter().all(|f| starts_with_start_code(&f.2) && f.2.len() <= PART));
}
