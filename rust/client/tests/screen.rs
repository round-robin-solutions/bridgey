//! The phone's screen between two session clients: a "PC" and a simulated phone that streams a synthetic H.264 clip
//! as unattended screenshots, answers control and records the input it gets (Client::simulate_phone_for_tests).

mod common;

use bridgey_core::phone::Area;
use bridgey_core::Event;
use common::{pair, Peer};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

fn setup() -> (Peer, Peer) {
    let (pc, phone) = (Peer::new("Windows PC"), Peer::new("Test phone"));
    phone.client.simulate_phone_for_tests(true);
    for p in [&pc, &phone] {
        for key in ["screen_draft1", "phone_control_draft1"] {
            p.client.set_feature(None, key, true).unwrap();
        }
    }
    pair(&pc, &phone);
    pc.wait("the phone's screen key", |e| matches!(e, Event::Features { remote, .. } if remote.get("screen_draft1") && remote.get("phone_control_draft1")).then_some(()));
    (pc, phone)
}

fn screen(pc: &Peer, phone: &Peer, command: Value) -> Value {
    let answer = pc.client.phone(Area::Screen, &phone.id(), &command);
    assert_eq!(answer["ok"], json!(true), "{command}: {answer}");
    answer
}

/// A Screen event `what` on `peer`, with its detail.
fn wait_screen(peer: &Peer, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    peer.wait(what, |e| match e {
        Event::Phone { area: Area::Screen, what: w, json, .. } if w == what => {
            let v: Value = serde_json::from_str(json).unwrap();
            f(&v).then_some(v)
        }
        _ => None,
    })
}

#[test]
fn the_phone_screen_shows_and_the_phone_is_controlled() {
    let (pc, phone) = setup();
    let request = screen(&pc, &phone, json!({"op": "request"}))["requestId"].as_str().unwrap().to_string();
    // A second ask while one is open is the same request; the phone says it is waiting, then starts.
    assert_eq!(screen(&pc, &phone, json!({"op": "request"}))["waiting"], json!(true));
    assert_eq!(wait_screen(&pc, "status", |v| v["requestId"] == json!(request))["status"], json!("waiting"));
    let started = wait_screen(&pc, "started", |_| true);
    assert_eq!((started["width"].as_u64(), started["height"].as_u64()), (Some(96), Some(160)));
    assert_eq!(started["screenshots"], json!(true), "unattended access: Slower mode");
    assert_eq!(started["control"]["capable"], json!(true));
    let stream = started["stream"].as_u64().unwrap();

    // Frames come through the pull call, the first a key frame with its parameter sets, and each is acknowledged.
    let mut buffer = vec![0u8; 64 * 1024];
    let mut frames = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while frames.len() < 6 && Instant::now() < deadline {
        if let Some(frame) = pc.client.screen_frame(stream, Duration::from_millis(500), buffer.len()).unwrap() {
            frames.push(frame);
        }
    }
    assert!(frames.len() >= 6, "frames arrived: {}", frames.len());
    assert!(frames[0].key && frames[0].parameter_sets);
    assert!(frames.iter().all(|f| f.data.starts_with(&[0, 0, 0, 1]) || f.data.starts_with(&[0, 0, 1])));
    assert!(frames.windows(2).all(|w| w[1].frame > w[0].frame));
    wait_screen(&phone, "sim_ack", |v| v["frame"] == json!(frames[5].frame));
    // Too small a buffer leaves the frame next.
    buffer.truncate(4);
    let too_small = (0..30).find_map(|_| pc.client.screen_frame(stream, Duration::from_millis(200), 4).err());
    assert!(matches!(too_small, Some(Some(n)) if n > 4));
    assert!(pc.client.screen_frame(stream, Duration::from_millis(500), 64 * 1024).unwrap().is_some());
    wait_screen(&pc, "stats", |v| v["fps"] == json!(10));

    // Control: begin, the phone allows it, and geometry_ack goes first with this session's connection nonce.
    screen(&pc, &phone, json!({"op": "control_begin"}));
    wait_screen(&pc, "control", |v| v["phase"] == json!("active"));
    let ack = wait_screen(&phone, "sim_input", |v| v["op"] == json!("geometry_ack"));
    assert_eq!((ack["seq"].as_u64(), ack["connection"].as_bool()), (Some(1), Some(true)));
    for (phase, y) in [("down", 0.2), ("move", 0.4), ("move", 0.6), ("up", 0.6)] {
        assert_eq!(screen(&pc, &phone, json!({"op": "touch", "contact": 0, "phase": phase, "x": 0.5, "y": y}))["taken"], json!(true));
    }
    wait_screen(&phone, "sim_input", |v| v["op"] == json!("touch") && v["seq"].as_u64() >= Some(4));
    assert_eq!(screen(&pc, &phone, json!({"op": "text", "text": "Hello"}))["taken"], json!(true));
    wait_screen(&phone, "sim_input", |v| v["op"] == json!("text"));
    assert_eq!(screen(&pc, &phone, json!({"op": "press", "key": "enter"}))["taken"], json!(true));
    assert_eq!(screen(&pc, &phone, json!({"op": "key", "key": "control", "down": true}))["taken"], json!(false));
    // Back: the simulated phone also rotates, so a new geometry is acknowledged before more input.
    screen(&pc, &phone, json!({"op": "navigate", "action": "back"}));
    let geometry = wait_screen(&pc, "geometry", |_| true);
    assert_eq!((geometry["width"].as_u64(), geometry["height"].as_u64()), (Some(160), Some(96)));
    wait_screen(&phone, "sim_input", |v| v["op"] == json!("geometry_ack") && v["geometry"] == json!(2));
    screen(&pc, &phone, json!({"op": "control_end"}));
    wait_screen(&phone, "sim_input", |v| v["op"] == json!("stop"));
    assert_eq!(screen(&pc, &phone, json!({"op": "navigate", "action": "home"}))["taken"], json!(false), "control is over");

    // Stop: the phone hears closed, the pull call says the stream ended.
    screen(&pc, &phone, json!({"op": "stop"}));
    assert_eq!(wait_screen(&phone, "sim_stop", |_| true)["reason"], json!("closed"));
    wait_screen(&pc, "stopped", |v| v["reason"] == json!("closed"));
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut ended = false;
    while !ended && Instant::now() < deadline {
        ended = pc.client.screen_frame(stream, Duration::from_millis(50), 64 * 1024).is_err();
    }
    assert!(ended, "frames left then the end");
    // Asking again within 3 s is too soon.
    assert_eq!(pc.client.phone(Area::Screen, &phone.id(), &json!({"op": "request"}))["error"], json!("too_soon"));
    pc.stop();
    phone.stop();
}

#[test]
fn turning_show_phone_screens_off_stops_the_stream() {
    let (pc, phone) = setup();
    screen(&pc, &phone, json!({"op": "request"}));
    let stream = wait_screen(&pc, "started", |_| true)["stream"].as_u64().unwrap();
    pc.client.set_feature(None, "screen_draft1", false).unwrap();
    assert_eq!(wait_screen(&phone, "sim_stop", |_| true)["reason"], json!("disabled"));
    wait_screen(&pc, "stopped", |v| v["stream"] == json!(stream) && v["reason"] == json!("disabled"));
    assert_eq!(pc.client.phone(Area::Screen, &phone.id(), &json!({"op": "request"}))["error"], json!("feature_off"));
    pc.stop();
    phone.stop();
}

#[test]
fn a_disconnect_ends_the_stream_here() {
    let (pc, phone) = setup();
    screen(&pc, &phone, json!({"op": "request"}));
    let stream = wait_screen(&pc, "started", |_| true)["stream"].as_u64().unwrap();
    phone.stop();
    wait_screen(&pc, "stopped", |v| v["stream"] == json!(stream) && v["reason"] == json!("disconnected"));
    pc.stop();
}
