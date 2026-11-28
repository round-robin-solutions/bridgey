//! A Mac's screen between two session clients: a viewer (as the iOS app is) and a simulated Mac that streams a
//! synthetic H.264 clip with Allow without asking, answers control and records the input it gets
//! (Client::simulate_phone_for_tests).

mod common;

use bridgey_core::phone::Area;
use bridgey_core::Event;
use common::{pair, Peer};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

fn setup() -> (Peer, Peer) {
    let (viewer, mac) = (Peer::new("Test iPad"), Peer::new("Test Mac"));
    mac.client.simulate_phone_for_tests(true);
    for p in [&viewer, &mac] {
        p.client.set_feature(None, "screen_control_draft1", true).unwrap();
    }
    pair(&viewer, &mac);
    viewer.wait("the Mac's screen key", |e| matches!(e, Event::Features { remote, .. } if remote.get("screen_control_draft1")).then_some(()));
    (viewer, mac)
}

fn display(viewer: &Peer, mac: &Peer, command: Value) -> Value {
    let answer = viewer.client.phone(Area::Display, &mac.id(), &command);
    assert_eq!(answer["ok"], json!(true), "{command}: {answer}");
    answer
}

/// A Display event `what` on `peer`, with its detail.
fn wait_display(peer: &Peer, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    peer.wait(what, |e| match e {
        Event::Phone { area: Area::Display, what: w, json, .. } if w == what => {
            let v: Value = serde_json::from_str(json).unwrap();
            f(&v).then_some(v)
        }
        _ => None,
    })
}

#[test]
fn the_mac_screen_shows_and_the_mac_is_controlled() {
    let (viewer, mac) = setup();
    let status = display(&viewer, &mac, json!({"op": "status"}));
    assert_eq!((status["enabled"].as_bool(), status["available"].as_bool()), (Some(true), Some(true)));
    let request = display(&viewer, &mac, json!({"op": "request"}))["requestId"].as_str().unwrap().to_string();
    assert_eq!(display(&viewer, &mac, json!({"op": "request"}))["waiting"], json!(true), "one open request");
    assert_eq!(wait_display(&viewer, "status", |v| v["requestId"] == json!(request))["status"], json!("waiting"));
    let started = wait_display(&viewer, "started", |_| true);
    assert_eq!((started["width"].as_u64(), started["height"].as_u64()), (Some(96), Some(160)));
    assert_eq!(started["screenshots"], json!(false));
    assert_eq!(started["displayName"], json!("Built-in Retina Display"));
    assert_eq!((started["control"]["capable"].as_bool(), started["control"]["allowed"].as_bool(), started["control"]["phase"].as_str()), (Some(true), Some(true), Some("off")));
    let stream = started["stream"].as_u64().unwrap();
    assert_eq!(display(&viewer, &mac, json!({"op": "request"}))["showing"], json!(true));

    // Frames come through the same pull call as a phone's, the first a key frame with its parameter sets, each one
    // acknowledged to the Mac.
    let mut frames = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while frames.len() < 6 && Instant::now() < deadline {
        if let Some(frame) = viewer.client.screen_frame(stream, Duration::from_millis(500), 64 * 1024).unwrap() {
            frames.push(frame);
        }
    }
    assert!(frames.len() >= 6, "frames arrived: {}", frames.len());
    assert!(frames[0].key && frames[0].parameter_sets);
    assert!(frames.iter().all(|f| f.data.starts_with(&[0, 0, 0, 1]) || f.data.starts_with(&[0, 0, 1])));
    assert!(frames.windows(2).all(|w| w[1].frame > w[0].frame));
    wait_display(&mac, "sim_ack", |v| v["frame"] == json!(frames[5].frame));
    wait_display(&viewer, "stats", |v| v["fps"] == json!(10) && v["stream"] == json!(stream));

    // A Mac takes a pointer: touches and navigation are not for it, and nothing is taken before control.
    assert_eq!(viewer.client.phone(Area::Display, &mac.id(), &json!({"op": "touch", "contact": 0, "phase": "down", "x": 0.5, "y": 0.5}))["error"], json!("unsupported"));
    assert_eq!(viewer.client.phone(Area::Display, &mac.id(), &json!({"op": "navigate", "action": "home"}))["error"], json!("unsupported"));
    assert_eq!(display(&viewer, &mac, json!({"op": "pointer", "x": 0.5, "y": 0.5}))["taken"], json!(false));

    // Control: begin, the Mac allows it, and geometry_ack goes first with this session's nonce and the stream's counters.
    display(&viewer, &mac, json!({"op": "control_begin"}));
    let active = wait_display(&viewer, "control", |v| v["phase"] == json!("active"));
    assert_eq!(active["input"], json!({"pointer": true, "touch": false, "keys": true, "text": true, "navigation": false}));
    let ack = wait_display(&mac, "sim_input", |v| v["op"] == json!("geometry_ack"));
    assert_eq!((ack["seq"].as_u64(), ack["connection"].as_bool(), ack["geometry"].as_u64()), (Some(1), Some(true), Some(1)));
    assert_eq!((ack["session"].as_u64(), ack["stream"].as_u64(), ack["transport"].as_u64()), (Some(1), Some(1), Some(1)));
    for (x, y) in [(0.1, 0.1), (0.2, 0.2), (0.3, 0.3)] {
        assert_eq!(display(&viewer, &mac, json!({"op": "pointer", "x": x, "y": y}))["taken"], json!(true));
    }
    wait_display(&mac, "sim_input", |v| v["op"] == json!("pointer"));
    for down in [true, false] {
        assert_eq!(display(&viewer, &mac, json!({"op": "button", "button": "primary", "down": down, "x": 0.3, "y": 0.3}))["taken"], json!(true));
    }
    wait_display(&mac, "sim_input", |v| v["op"] == json!("button") && v["input"]["down"] == json!(false));
    assert_eq!(display(&viewer, &mac, json!({"op": "button", "button": "primary", "down": false, "x": 0.3, "y": 0.3}))["taken"], json!(false), "not held");
    assert_eq!(display(&viewer, &mac, json!({"op": "scroll", "dx": 0, "dy": -120, "x": 0.5, "y": 0.5}))["taken"], json!(true));
    wait_display(&mac, "sim_input", |v| v["op"] == json!("scroll"));
    assert_eq!(display(&viewer, &mac, json!({"op": "text", "text": "Hello"}))["taken"], json!(true));
    wait_display(&mac, "sim_input", |v| v["op"] == json!("text"));
    assert_eq!(display(&viewer, &mac, json!({"op": "press", "key": "enter"}))["taken"], json!(true));
    wait_display(&mac, "sim_input", |v| v["op"] == json!("key") && v["input"]["key"] == json!("enter") && v["input"]["down"] == json!(false));
    assert_eq!(display(&viewer, &mac, json!({"op": "key", "key": "meta", "down": true}))["taken"], json!(false), "no Command key");
    // Every packet so far carried this session's nonce and geometry 1.
    assert!(!mac.saw(|e| matches!(e, Event::Phone { area: Area::Display, what, json, .. } if what == "sim_input" && (json.contains("\"connection\":false") || !json.contains("\"geometry\":1")))));

    // The Mac's display changes size: a new geometry, acknowledged before more input.
    assert!(mac.client.simulate_display_change_for_tests(&viewer.id()));
    let geometry = wait_display(&viewer, "geometry", |_| true);
    assert_eq!((geometry["generation"].as_u64(), geometry["width"].as_u64(), geometry["height"].as_u64()), (Some(2), Some(160), Some(96)));
    wait_display(&mac, "sim_input", |v| v["op"] == json!("geometry_ack") && v["geometry"] == json!(2));
    assert_eq!(display(&viewer, &mac, json!({"op": "pointer", "x": 0.9, "y": 0.9}))["taken"], json!(true));
    wait_display(&mac, "sim_input", |v| v["op"] == json!("pointer") && v["geometry"] == json!(2));

    // Ending control sends the contract's stop and leaves the stream running.
    display(&viewer, &mac, json!({"op": "control_end"}));
    wait_display(&mac, "sim_input", |v| v["op"] == json!("stop"));
    assert_eq!(display(&viewer, &mac, json!({"op": "pointer", "x": 0.5, "y": 0.5}))["taken"], json!(false), "control is over");
    assert!(display(&viewer, &mac, json!({"op": "status"}))["stream"].is_object(), "the stream goes on");

    // Stop: the Mac hears user, the pull call says the stream ended.
    display(&viewer, &mac, json!({"op": "stop"}));
    assert_eq!(wait_display(&mac, "sim_stop", |_| true)["reason"], json!("user"));
    wait_display(&viewer, "stopped", |v| v["reason"] == json!("user") && v["by"] == json!("here"));
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut ended = false;
    while !ended && Instant::now() < deadline {
        ended = viewer.client.screen_frame(stream, Duration::from_millis(50), 64 * 1024).is_err();
    }
    assert!(ended, "frames left then the end");
    assert_eq!(viewer.client.phone(Area::Display, &mac.id(), &json!({"op": "request"}))["error"], json!("too_soon"));
    viewer.stop();
    mac.stop();
}

#[test]
fn leaving_the_screen_stops_with_its_reason() {
    let (viewer, mac) = setup();
    display(&viewer, &mac, json!({"op": "request"}));
    wait_display(&viewer, "started", |_| true);
    assert_eq!(viewer.client.phone(Area::Display, &mac.id(), &json!({"op": "stop", "reason": "sideways"}))["error"], json!("invalid"));
    display(&viewer, &mac, json!({"op": "stop", "reason": "left_screen"}));
    assert_eq!(wait_display(&mac, "sim_stop", |_| true)["reason"], json!("left_screen"));
    viewer.stop();
    mac.stop();
}

#[test]
fn the_mac_turning_its_grant_off_ends_the_stream() {
    let (viewer, mac) = setup();
    display(&viewer, &mac, json!({"op": "request"}));
    let stream = wait_display(&viewer, "started", |_| true)["stream"].as_u64().unwrap();
    mac.client.set_feature(None, "screen_control_draft1", false).unwrap();
    wait_display(&viewer, "stopped", |v| v["stream"] == json!(stream) && v["reason"] == json!("disabled") && v["by"] == json!("mac"));
    assert_eq!(viewer.client.phone(Area::Display, &mac.id(), &json!({"op": "request"}))["error"], json!("feature_off"));
    viewer.stop();
    mac.stop();
}

#[test]
fn turning_see_mac_screens_off_here_stops_the_stream() {
    let (viewer, mac) = setup();
    display(&viewer, &mac, json!({"op": "request"}));
    let stream = wait_display(&viewer, "started", |_| true)["stream"].as_u64().unwrap();
    viewer.client.set_feature(None, "screen_control_draft1", false).unwrap();
    assert_eq!(wait_display(&mac, "sim_stop", |_| true)["reason"], json!("user"));
    wait_display(&viewer, "stopped", |v| v["stream"] == json!(stream) && v["by"] == json!("here"));
    assert_eq!(viewer.client.phone(Area::Display, &mac.id(), &json!({"op": "status"}))["enabled"], json!(false));
    viewer.stop();
    mac.stop();
}

#[test]
fn a_disconnect_ends_the_stream_here() {
    let (viewer, mac) = setup();
    display(&viewer, &mac, json!({"op": "request"}));
    let stream = wait_display(&viewer, "started", |_| true)["stream"].as_u64().unwrap();
    mac.stop();
    wait_display(&viewer, "stopped", |v| v["stream"] == json!(stream) && v["reason"] == json!("disconnected"));
    viewer.stop();
}
