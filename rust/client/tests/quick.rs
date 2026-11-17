//! Links both ways and the phone's media controls between two session clients, one sending what a phone sends.

mod common;

use bridgey_core::{Event, SendStatus};
use common::{pair, Peer};
use serde_json::json;

fn setup() -> (Peer, Peer) {
    let (pc, phone) = (Peer::new("Windows PC"), Peer::new("Test phone"));
    for p in [&pc, &phone] {
        for key in ["links", "media", "links_open_draft1"] {
            p.client.set_feature(None, key, true).unwrap();
        }
    }
    pair(&pc, &phone);
    pc.wait("the phone's map", |e| matches!(e, Event::Features { remote, .. } if remote.get("links") && remote.get("media")).then_some(()));
    phone.wait("the PC's map", |e| matches!(e, Event::Features { remote, .. } if remote.get("links")).then_some(()));
    (pc, phone)
}

fn request(id: &str, feature: &str, action: &str, value: &str, sequence: u64) -> String {
    json!({"version": 1, "requestId": id, "feature": feature, "action": action, "value": value, "sequence": sequence}).to_string()
}

#[test]
fn links_both_ways_and_open_right_away() {
    let (pc, phone) = setup();
    let uuid = || bridgey_core::crypto::uuid4();
    // Asked to open at once with Open links right away on (the default): opened; too soon after: offered.
    phone.client.send_as_phone_for_tests(&pc.id(), "quick.request", &request(&uuid(), "links", "open", "https://example.com/one", 1)).unwrap();
    pc.wait("opened", |e| matches!(e, Event::Link { url, open: true, .. } if url == "https://example.com/one").then_some(()));
    phone.client.send_as_phone_for_tests(&pc.id(), "quick.request", &request(&uuid(), "links", "open", "https://example.com/two", 2)).unwrap();
    pc.wait("offered", |e| matches!(e, Event::Link { url, open: false, .. } if url == "https://example.com/two").then_some(()));
    // An offer waits for the person; an old sequence never runs; a bad link is refused.
    phone.client.send_as_phone_for_tests(&pc.id(), "quick.request", &request(&uuid(), "links", "offer", "https://example.com/three", 3)).unwrap();
    pc.wait("an offer", |e| matches!(e, Event::Link { url, open: false, .. } if url.ends_with("/three")).then_some(()));
    phone.client.send_as_phone_for_tests(&pc.id(), "quick.request", &request(&uuid(), "links", "offer", "https://example.com/old", 2)).unwrap();
    phone.client.send_as_phone_for_tests(&pc.id(), "quick.request", &request(&uuid(), "links", "offer", "javascript:alert(1)", 4)).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(400));
    assert!(!pc.saw(|e| matches!(e, Event::Link { url, .. } if url.ends_with("/old") || url.starts_with("javascript"))));
    // Open links right away off: a link asked to open at once is only offered.
    pc.client.set_links_open(false);
    std::thread::sleep(std::time::Duration::from_secs(3));
    phone.client.send_as_phone_for_tests(&pc.id(), "quick.request", &request(&uuid(), "links", "open", "https://example.com/five", 5)).unwrap();
    pc.wait("offered with the setting off", |e| matches!(e, Event::Link { url, open: false, .. } if url.ends_with("/five")).then_some(()));

    // The PC sends a link: the other end keeps it and answers delivered.
    let r = pc.client.send_link(&phone.id(), "https://roundrobin.in/bridgey").unwrap();
    phone.wait("the link at the phone", |e| matches!(e, Event::Link { url, .. } if url == "https://roundrobin.in/bridgey").then_some(()));
    pc.wait("delivered", |e| matches!(e, Event::LinkSent { request, status: SendStatus::Delivered, .. } if *request == r).then_some(()));
    assert!(pc.client.send_link(&phone.id(), "ftp://x").is_err());
    pc.stop();
    phone.stop();
}

#[test]
fn the_phone_controls_this_devices_player() {
    let (pc, phone) = setup();
    let id = bridgey_core::crypto::uuid4();
    phone.client.send_as_phone_for_tests(&pc.id(), "quick.request", &request(&id, "media", "seek", "95", 1)).unwrap();
    let (request_id, action, value) = pc.wait("the command", |e| match e {
        Event::MediaCommand { request_id, action, value, .. } => Some((request_id.clone(), action.clone(), *value)),
        _ => None,
    });
    assert_eq!((request_id.as_str(), action.as_str(), value), (id.as_str(), "seek", Some(95)));
    pc.client.media_result(&phone.id(), &request_id, true).unwrap();
    pc.client.set_media_state(Some(&json!({"player": "Spotify", "title": "Song", "artist": "Band", "playing": true, "position": 95, "duration": 200, "controls": ["toggle", "next"]}).to_string())).unwrap();
    // Media off here: the next command is refused without reaching the host.
    pc.client.set_feature(Some(&phone.id()), "media", false).unwrap();
    phone.wait("media off", |e| matches!(e, Event::Features { remote, .. } if !remote.get("media")).then_some(()));
    pc.clear();
    let _ = phone.client.send_as_phone_for_tests(&pc.id(), "quick.request", &request(&bridgey_core::crypto::uuid4(), "media", "toggle", "", 2));
    std::thread::sleep(std::time::Duration::from_millis(400));
    assert!(!pc.saw(|e| matches!(e, Event::MediaCommand { .. })));
    pc.stop();
    phone.stop();
}
