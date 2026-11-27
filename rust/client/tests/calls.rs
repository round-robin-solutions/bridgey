//! The Calls window between two session clients: a "PC" and a simulated phone that answers dialer.* and calls.request
//! with a canned address book and call log (Client::simulate_phone_for_tests).

mod common;

use bridgey_core::phone::Area;
use bridgey_core::Event;
use common::{pair, Peer};
use serde_json::{json, Value};
use std::time::Duration;

fn setup(phone_keys: &[&str]) -> (Peer, Peer) {
    let (pc, phone) = (Peer::new("Windows PC"), Peer::new("Test phone"));
    phone.client.simulate_phone_for_tests(true);
    for key in ["dialer_draft1", "calls"] {
        pc.client.set_feature(None, key, true).unwrap();
    }
    for key in phone_keys {
        phone.client.set_feature(None, key, true).unwrap();
    }
    pair(&pc, &phone);
    (pc, phone)
}

fn calls(pc: &Peer, phone: &Peer, command: Value) -> Value {
    pc.client.phone(Area::Calls, &phone.id(), &command)
}

fn ok(pc: &Peer, phone: &Peer, command: Value) -> Value {
    let answer = calls(pc, phone, command.clone());
    assert_eq!(answer["ok"], json!(true), "{command}: {answer}");
    answer
}

fn wait_calls(pc: &Peer, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    pc.wait(what, |e| match e {
        Event::Phone { area: Area::Calls, what: w, json, .. } if w == what => {
            let v: Value = serde_json::from_str(json).unwrap();
            f(&v).then_some(v)
        }
        _ => None,
    })
}

/// Waits until `state` satisfies `f`.
fn wait_state(pc: &Peer, phone: &Peer, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    let deadline = std::time::Instant::now() + common::WAIT;
    loop {
        let state = ok(pc, phone, json!({"op": "state"}));
        if f(&state) {
            return state;
        }
        assert!(std::time::Instant::now() < deadline, "{what}: {state}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn row_ids(answer: &Value) -> Vec<String> {
    answer["rows"].as_array().unwrap().iter().map(|r| r["rowId"].as_str().unwrap().to_string()).collect()
}

#[test]
fn the_calls_window_searches_lists_and_calls_through_the_phone() {
    let (pc, phone) = setup(&["dialer_draft1", "calls"]);
    // The phone's status, then its recent calls.
    let state = wait_state(&pc, &phone, "recent calls", |s| s["recentsLoaded"] == json!(true));
    assert_eq!(state["available"], json!(true));
    assert_eq!(state["phone"]["sims"].as_array().unwrap().len(), 2);
    assert_eq!(row_ids(&ok(&pc, &phone, json!({"op": "rows", "query": ""}))), ["r:501", "r:500", "r:499"]);

    // Contacts for what is typed: a moment after typing stops.
    ok(&pc, &phone, json!({"op": "search", "query": "an"}));
    ok(&pc, &phone, json!({"op": "search", "query": "anna"}));
    wait_state(&pc, &phone, "contacts", |s| s["contactsQuery"] == json!("anna") && s["searching"] == json!(false));
    let rows = ok(&pc, &phone, json!({"op": "rows", "query": "anna"}));
    assert_eq!(row_ids(&rows), ["c:7"]);
    assert_eq!(rows["rows"][0]["whatsapp"][0]["voice"], json!(4211));

    // Two SIMs and nothing chosen: this PC asks which.
    let ask = calls(&pc, &phone, json!({"op": "call", "address": "+44 7700 900123"}));
    assert_eq!(ask["error"], json!("choose_sim"));
    assert_eq!(ask["sims"].as_array().unwrap().len(), 2);
    let id = ok(&pc, &phone, json!({"op": "call", "address": "+44 7700 900123", "subId": 2}))["requestId"].as_str().unwrap().to_string();
    let started = wait_calls(&pc, "call", |v| v["requestId"] == json!(id) && v["result"] == json!("started"));
    assert_eq!(started["via"], json!("phone"));
    // One every 3 seconds.
    assert_eq!(calls(&pc, &phone, json!({"op": "call", "address": "100200", "prefer": "sim1"}))["error"], json!("too_soon"));
    // A number the phone would refuse never leaves this PC.
    assert_eq!(calls(&pc, &phone, json!({"op": "call", "address": "*#06#"}))["error"], json!("invalid"));

    std::thread::sleep(Duration::from_millis(3_100));
    let wa = ok(&pc, &phone, json!({"op": "whatsapp", "dataId": 4211, "video": false}))["requestId"].as_str().unwrap().to_string();
    let confirm = wait_calls(&pc, "call", |v| v["requestId"] == json!(wa) && v["result"] == json!("confirm"));
    assert_eq!(confirm["via"], json!("whatsapp_voice"));

    std::thread::sleep(Duration::from_millis(3_100));
    let emergency = ok(&pc, &phone, json!({"op": "call", "address": "112", "prefer": "sim1"}))["requestId"].as_str().unwrap().to_string();
    let refused = wait_calls(&pc, "call", |v| v["requestId"] == json!(emergency) && v["result"] == json!("refused"));
    assert_eq!(refused["reason"], json!("emergency"));

    // The Calls window off here: what was kept goes.
    pc.client.set_feature(Some(&phone.id()), "dialer_draft1", false).unwrap();
    let state = ok(&pc, &phone, json!({"op": "state"}));
    assert_eq!(state["available"], json!(false));
    assert!(state["recents"].as_array().unwrap().is_empty());
    pc.stop();
    phone.stop();
}

/// A phone without the Calls window for this PC still takes the upstream call request, answered by message ID.
#[test]
fn without_the_calls_window_a_call_goes_as_a_call_request() {
    let (pc, phone) = setup(&["calls"]);
    let state = wait_state(&pc, &phone, "the phone's map", |s| s["upstream"] == json!(true));
    assert_eq!(state["available"], json!(false));
    let id = ok(&pc, &phone, json!({"op": "call", "address": "+44 20 7946 0000"}))["requestId"].as_str().unwrap().to_string();
    let answer = wait_calls(&pc, "call", |v| v["requestId"] == json!(id) && v["result"] != json!("sent"));
    assert_eq!((answer["result"].clone(), answer["via"].clone()), (json!("confirm"), json!("calls")));
    std::thread::sleep(Duration::from_millis(3_100));
    let id = ok(&pc, &phone, json!({"op": "call", "address": "112"}))["requestId"].as_str().unwrap().to_string();
    assert_eq!(wait_calls(&pc, "call", |v| v["requestId"] == json!(id) && v["result"] != json!("sent"))["result"], json!("refused"));
    // WhatsApp needs the Calls window.
    assert_eq!(calls(&pc, &phone, json!({"op": "whatsapp", "dataId": 4211}))["error"], json!("feature_off"));
    pc.stop();
    phone.stop();
}

/// Agent devices never get calls, whatever their map says.
#[test]
fn agents_never_get_calls() {
    let (pc, phone) = setup(&["dialer_draft1", "calls", "agent_draft1"]);
    pc.wait("the agent's map", |e| matches!(e, Event::Features { remote, .. } if remote.get("agent_draft1")).then_some(()));
    let state = ok(&pc, &phone, json!({"op": "state"}));
    assert_eq!((state["available"].clone(), state["upstream"].clone()), (json!(false), json!(false)));
    assert_eq!(calls(&pc, &phone, json!({"op": "call", "address": "100200"}))["error"], json!("feature_off"));
    assert!(!pc.saw(|e| matches!(e, Event::Phone { area: Area::Calls, what, .. } if what == "call")));
    pc.stop();
    phone.stop();
}
