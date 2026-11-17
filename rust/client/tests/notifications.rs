//! Phone notifications, actions, codes and presence between two session clients, one sending what a phone sends.

mod common;

use bridgey_core::notifications::Presence;
use bridgey_core::Event;
use common::{pair, Peer};
use serde_json::json;

/// A paired "PC" and "phone" with notifications, routing, presence and codes on at both ends.
fn setup() -> (Peer, Peer) {
    let (pc, phone) = (Peer::new("Windows PC"), Peer::new("Test phone"));
    for p in [&pc, &phone] {
        for key in ["notifications", "notification_routing_draft1", "device_presence_draft1", "sms_codes_draft1"] {
            p.client.set_feature(None, key, true).unwrap();
        }
    }
    pair(&pc, &phone);
    pc.wait("the phone's map", |e| matches!(e, Event::Features { remote, .. } if remote.get("notifications") && remote.get("sms_codes_draft1")).then_some(()));
    phone.wait("the PC's map", |e| matches!(e, Event::Features { remote, .. } if remote.get("device_presence_draft1")).then_some(()));
    (pc, phone)
}

#[test]
fn notifications_arrive_with_actions_codes_and_quiet_and_go_away() {
    let (pc, phone) = setup();
    pc.client.set_codes(true, false);
    let post = json!({
        "packageName": "com.google.android.apps.messaging", "applicationName": "Messages", "notificationId": "0|sms|42",
        "title": "VM-HDFCBK", "text": "OTP is 482913 for txn of INR 2,499.00 at AMAZON PAY. Do not share OTP.", "timestamp": 1_794_000_000_000i64,
        "actions": [{"actionToken": "reply-1", "title": "Reply", "allowsReply": true}, {"actionToken": "read-1", "title": "Mark as read", "allowsReply": false}],
        "smsDefaultApp": true, "redacted": false, "presentation": "alert",
    });
    phone.client.send_as_phone_for_tests(&pc.id(), "notifications.post", &post.to_string()).unwrap();
    let n = pc.wait("the notification", |e| match e {
        Event::Notification { notification, .. } => Some(notification.clone()),
        _ => None,
    });
    assert_eq!(n.notification_id, "0|sms|42");
    assert_eq!(n.actions.len(), 2);
    assert!(!n.quiet);
    let code = n.code.expect("the code was found");
    assert_eq!((code.code.as_str(), code.service.as_str()), ("482913", "VM-HDFCBK"));

    // Quiet: history only.
    let quiet = json!({"packageName": "com.whatsapp", "applicationName": "WhatsApp", "notificationId": "w1", "title": "Ravi", "text": "On my way", "timestamp": 1, "presentation": "quiet"});
    phone.client.send_as_phone_for_tests(&pc.id(), "notifications.post", &quiet.to_string()).unwrap();
    assert!(pc.wait("the quiet one", |e| match e {
        Event::Notification { notification, .. } if notification.notification_id == "w1" => Some(notification.quiet),
        _ => None,
    }));

    // The PC replies and dismisses; the phone removes one.
    pc.client.notification_action(&phone.id(), "0|sms|42", "reply-1", Some("Thanks")).unwrap();
    pc.client.dismiss_notification(&phone.id(), "w1").unwrap();
    phone.client.send_as_phone_for_tests(&pc.id(), "notifications.remove", &json!({"notificationId": "0|sms|42", "callEnded": false}).to_string()).unwrap();
    pc.wait("removed", |e| matches!(e, Event::NotificationRemoved { notification_id, call_ended: false, .. } if notification_id == "0|sms|42").then_some(()));

    // Notifications off here for the phone: nothing more arrives.
    pc.client.set_feature(Some(&phone.id()), "notifications", false).unwrap();
    phone.wait("the PC turned notifications off", |e| matches!(e, Event::Features { remote, .. } if !remote.get("notifications")).then_some(()));
    pc.clear();
    let _ = phone.client.send_as_phone_for_tests(&pc.id(), "notifications.post", &json!({"notificationId": "late", "title": "x", "text": "y", "timestamp": 1}).to_string());
    std::thread::sleep(std::time::Duration::from_millis(500));
    assert!(!pc.saw(|e| matches!(e, Event::Notification { .. })));
    pc.stop();
    phone.stop();
}

#[test]
fn codes_status_link_and_advertising() {
    let (pc, phone) = setup();
    phone.client.send_as_phone_for_tests(&pc.id(), "codes.status", &json!({"version": 1, "status": "hidden"}).to_string()).unwrap();
    pc.wait("codes status", |e| matches!(e, Event::CodesStatus { status, .. } if status == "hidden").then_some(()));
    pc.client.codes_link_request(&phone.id()).unwrap();
    let uuid = "7e57d00d-0000-4000-8000-0000000000cc";
    phone.client.send_as_phone_for_tests(&pc.id(), "codes.advertise", &json!({"version": 1, "serviceUuid": uuid}).to_string()).unwrap();
    pc.wait("advertise", |e| matches!(e, Event::CodesAdvertise { service_uuid, start: true, .. } if service_uuid == uuid).then_some(()));
    pc.client.codes_advertise_result(&phone.id(), uuid, false, Some("unsupported")).unwrap();
    phone.client.send_as_phone_for_tests(&pc.id(), "codes.advertise_stop", &json!({"version": 1, "serviceUuid": uuid, "linked": true}).to_string()).unwrap();
    pc.wait("advertise stop", |e| matches!(e, Event::CodesAdvertise { start: false, linked: true, .. }).then_some(()));
    pc.client.set_presence(Presence::Input { idle: 3 });
    pc.client.set_presence(Presence::Locked);
    pc.stop();
    phone.stop();
}
