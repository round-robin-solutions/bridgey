//! Text messages between two session clients: a "PC" and a simulated phone that answers sms.* requests with canned
//! conversations (Client::simulate_phone_for_tests).

mod common;

use bridgey_core::phone::Area;
use bridgey_core::Event;
use common::{pair, Peer};
use serde_json::{json, Value};

fn setup() -> (Peer, Peer) {
    let (pc, phone) = (Peer::new("Windows PC"), Peer::new("Test phone"));
    phone.client.simulate_phone_for_tests(true);
    for p in [&pc, &phone] {
        p.client.set_feature(None, "sms_draft1", true).unwrap();
    }
    pair(&pc, &phone);
    (pc, phone)
}

fn sms(pc: &Peer, phone: &Peer, command: Value) -> Value {
    let answer = pc.client.phone(Area::Sms, &phone.id(), &command);
    assert_eq!(answer["ok"], json!(true), "{command}: {answer}");
    answer
}

/// An Sms event `what`, with its detail.
fn wait_sms(pc: &Peer, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    pc.wait(what, |e| match e {
        Event::Phone { area: Area::Sms, what: w, json, .. } if w == what => {
            let v: Value = serde_json::from_str(json).unwrap();
            f(&v).then_some(v)
        }
        _ => None,
    })
}

#[test]
fn conversations_load_unread_first_and_messages_send() {
    let (pc, phone) = setup();
    // The phone's status after the features: the baseline, then the newest conversations.
    wait_sms(&pc, "status", |v| v["phone"]["read"] == json!(true));
    wait_sms(&pc, "changed", |v| v["threads"] == json!(true));
    let threads = sms(&pc, &phone, json!({"op": "threads"}))["threads"].as_array().unwrap().clone();
    assert_eq!(threads.iter().map(|t| t["threadId"].as_i64().unwrap()).collect::<Vec<_>>(), vec![12, 7, 3], "unread first, then newest");
    assert_eq!(threads[0]["title"], json!("Asha"));
    assert_eq!(threads[0]["unread"], json!(2));
    assert_eq!(threads[2]["group"], json!(true));
    let unread = sms(&pc, &phone, json!({"op": "threads", "filter": "unread"}))["threads"].as_array().unwrap().len();
    assert_eq!(unread, 1);

    // Open a conversation: its newest page loads.
    pc.clear();
    sms(&pc, &phone, json!({"op": "open", "threadId": 12}));
    wait_sms(&pc, "changed", |v| v["threadId"] == json!(12));
    let open = sms(&pc, &phone, json!({"op": "messages", "threadId": 12}));
    let bodies: Vec<&str> = open["messages"].as_array().unwrap().iter().map(|m| m["body"].as_str().unwrap()).collect();
    assert_eq!(bodies, vec!["See you at 6", "Are you coming?", "Running late"]);
    assert_eq!(open["canSend"], json!(true));

    // Read here: the phone is asked to mark it read, and says it did.
    sms(&pc, &phone, json!({"op": "mark_read", "threadIds": [12]}));
    let notice = wait_sms(&pc, "notice", |v| v["kind"] == json!("mark_read"));
    assert_eq!((notice["total"].as_i64(), notice["marked"].as_i64()), (Some(1), Some(1)));
    let first = &sms(&pc, &phone, json!({"op": "threads"}))["threads"][0];
    assert_eq!(first["unread"], json!(0), "{first}");

    // Send: sending, then sent and delivered.
    let id = sms(&pc, &phone, json!({"op": "send", "threadId": 12, "body": "On my way"}))["requestId"].as_str().unwrap().to_string();
    wait_sms(&pc, "send", |v| v["requestId"] == json!(id) && v["state"] == json!("delivered"));
    // Malformed sends never leave this device.
    assert_eq!(pc.client.phone(Area::Sms, &phone.id(), &json!({"op": "send", "threadId": 12, "body": "   "}))["error"], json!("invalid"));
    assert_eq!(pc.client.phone(Area::Sms, &phone.id(), &json!({"op": "send", "address": "*123#", "body": "Hi"}))["error"], json!("invalid"));
    // A refused send says why.
    let refused = sms(&pc, &phone, json!({"op": "send", "address": "112", "body": "Hi"}))["requestId"].as_str().unwrap().to_string();
    let r = wait_sms(&pc, "send", |v| v["requestId"] == json!(refused) && v["state"] == json!("refused"));
    assert_eq!(r["reason"], json!("invalid"));

    // A picture, and contacts for a new message.
    sms(&pc, &phone, json!({"op": "image", "partId": "p42"}));
    let image = wait_sms(&pc, "image", |v| v["partId"] == json!("p42"));
    assert_eq!(image["width"], json!(1));
    assert!(image["data"].as_str().unwrap().starts_with("iVBOR"));
    sms(&pc, &phone, json!({"op": "contacts", "query": "As"}));
    let contacts = wait_sms(&pc, "contacts", |_| true);
    assert_eq!(contacts["contacts"][0]["name"], json!("Asha"));

    // Block on phone opens Blocked numbers there (here: a notification on the phone).
    sms(&pc, &phone, json!({"op": "block", "address": "+447700900123"}));
    assert_eq!(wait_sms(&pc, "notice", |v| v["kind"] == json!("blocked"))["result"], json!("notified"));
    pc.stop();
    phone.stop();
}

#[test]
fn turning_text_messages_off_forgets_the_phone_s_conversations() {
    let storage = std::sync::Arc::new(bridgey_core::MemoryStorage::default());
    let pc = Peer::start("Windows PC", storage.clone(), 0, common::Codes::Accept);
    let phone = Peer::new("Test phone");
    phone.client.simulate_phone_for_tests(true);
    for p in [&pc, &phone] {
        p.client.set_feature(None, "sms_draft1", true).unwrap();
    }
    pair(&pc, &phone);
    wait_sms(&pc, "changed", |v| v["threads"] == json!(true));
    let key = format!("sms-{}", phone.id());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while bridgey_core::Storage::load(storage.as_ref(), &key).unwrap().is_none() {
        assert!(std::time::Instant::now() < deadline, "the cache is written within a second or so");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    pc.client.set_feature(Some(&phone.id()), "sms_draft1", false).unwrap();
    assert!(bridgey_core::Storage::load(storage.as_ref(), &key).unwrap().is_none(), "the cache went");
    assert!(sms(&pc, &phone, json!({"op": "threads"}))["threads"].as_array().unwrap().is_empty());
    assert_eq!(pc.client.phone(Area::Sms, &phone.id(), &json!({"op": "refresh"}))["error"], json!("feature_off"));
    pc.stop();
    phone.stop();
}

#[test]
fn commands_for_unknown_devices_and_bad_ops_are_refused() {
    let pc = Peer::new("Windows PC");
    assert_eq!(pc.client.phone(Area::Sms, "nobody", &json!({"op": "threads"}))["error"], json!("unknown_device"));
    pc.stop();
}
