//! Phone notifications on this device (`notifications.send.v1`, `notifications.dismiss.v1`, docs/protocol.md
//! "Notifications"), activity-aware routing (`notification_routing_draft1`) and the coarse activity this device
//! reports for it (`presence.state`, `device_presence_draft1`), with the limits protocol/messages.json gives.
//!
//! Content is sensitive: nothing here logs it.

use serde_json::{json, Map, Value};

pub const ROUTING: &str = "notification_routing_draft1";
pub const PRESENCE: &str = "device_presence_draft1";
pub const SMS_CODES: &str = "sms_codes_draft1";
pub const EMAIL_CODES: &str = "email_codes_draft1";
/// Encoded at most 28 KiB, as the phone sends it.
const MAX_ICON: usize = 28 * 1024;
const MAX_ACTIONS: usize = 4;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Action {
    pub token: String,
    pub title: String,
    pub allows_reply: bool,
}

/// One `notifications.post`, checked and bounded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notification {
    pub package_name: String,
    pub application_name: String,
    pub notification_id: String,
    pub title: String,
    pub text: String,
    pub timestamp: i64,
    /// Base64 PNG.
    pub icon: Option<String>,
    pub call_type: Option<String>,
    pub actions: Vec<Action>,
    pub sms_default_app: Option<bool>,
    pub redacted: Option<bool>,
    pub email_app: Option<bool>,
    pub preview: Option<String>,
    /// `presentation: quiet`: keep it (history, codes) but show no banner and make no sound.
    pub quiet: bool,
    pub event_id: Option<String>,
    /// A code found in it (when Codes from messages is on here).
    pub code: Option<crate::codes::Found>,
}

/// Visible text, at most `max` characters; line breaks stay, other control and invisible characters go.
fn clean(value: Option<&Value>, max: usize) -> String {
    let text = value.and_then(Value::as_str).unwrap_or("");
    text.chars().filter(|c| *c == '\n' || !crate::session::invisible(*c)).take(max).collect()
}

fn optional_bool(o: &Map<String, Value>, key: &str) -> Result<Option<bool>, ()> {
    match o.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        Some(_) => Err(()),
    }
}

/// A JSON object whose top-level keys are unique, as the apps require for `notifications.post` and `presence.state`
/// (a JSON library that keeps one of two duplicates could disagree with the other app about a quiet notification).
pub fn strict_object(plain: &[u8]) -> Option<Map<String, Value>> {
    use serde::de::{Deserializer, MapAccess, Visitor};
    struct Unique;
    impl<'de> Visitor<'de> for Unique {
        type Value = Map<String, Value>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("an object with unique keys")
        }
        fn visit_map<A: MapAccess<'de>>(self, mut access: A) -> Result<Self::Value, A::Error> {
            let mut map = Map::new();
            while let Some((key, value)) = access.next_entry::<String, Value>()? {
                if map.insert(key, value).is_some() {
                    return Err(serde::de::Error::custom("duplicate key"));
                }
            }
            Ok(map)
        }
    }
    let mut de = serde_json::Deserializer::from_slice(plain);
    let map = de.deserialize_map(Unique).ok()?;
    de.end().ok()?;
    Some(map)
}

/// `notifications.post`. `routing` is whether both ends advertised notification routing (a `presentation` is only
/// valid then). None for a payload the apps would reject.
pub fn decode_post(plain: &[u8], routing: bool) -> Option<Notification> {
    let o = strict_object(plain)?;
    let notification_id = o.get("notificationId")?.as_str()?.to_string();
    if notification_id.is_empty() || notification_id.chars().count() > 512 {
        return None;
    }
    let timestamp = o.get("timestamp").and_then(Value::as_i64).unwrap_or(0);
    let icon = o.get("applicationIcon").and_then(Value::as_str).filter(|i| !i.is_empty() && i.len() <= MAX_ICON).map(str::to_string);
    let call_type = o.get("callType").and_then(Value::as_str).filter(|c| matches!(*c, "incoming" | "ongoing" | "screening" | "unknown")).map(str::to_string);
    let mut actions = Vec::new();
    if let Some(Value::Array(list)) = o.get("actions") {
        for a in list.iter().take(MAX_ACTIONS) {
            let (Some(token), Some(title)) = (a.get("actionToken").and_then(Value::as_str), a.get("title").and_then(Value::as_str)) else { continue };
            if token.is_empty() || token.chars().count() > 64 {
                continue;
            }
            actions.push(Action { token: token.to_string(), title: clean(Some(&Value::String(title.into())), 64), allows_reply: a.get("allowsReply").and_then(Value::as_bool).unwrap_or(false) });
        }
    }
    let quiet = match o.get("presentation") {
        None => false,
        Some(Value::String(p)) if routing && p == "alert" => false,
        Some(Value::String(p)) if routing && p == "quiet" => true,
        // A presentation without negotiated routing, or another value, is rejected.
        _ => return None,
    };
    let event_id = match o.get("eventId") {
        None => None,
        Some(Value::String(e)) if routing && call_type.is_none() && o.get("callType").is_none() && e.len() == 64 && e.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)) => Some(e.clone()),
        _ => return None,
    };
    Some(Notification {
        package_name: clean(o.get("packageName"), 256),
        application_name: clean(o.get("applicationName"), 128),
        notification_id,
        title: clean(o.get("title"), 1_024),
        text: clean(o.get("text"), 8_192),
        timestamp,
        icon,
        call_type,
        actions,
        sms_default_app: optional_bool(&o, "smsDefaultApp").ok()?,
        redacted: optional_bool(&o, "redacted").ok()?,
        email_app: optional_bool(&o, "emailApp").ok()?,
        preview: o.get("preview").and_then(Value::as_str).map(|p| p.chars().take(600).collect()),
        quiet,
        event_id,
        code: None,
    })
}

/// `notifications.remove`: the notification ID and whether a call ended.
pub fn decode_remove(plain: &[u8]) -> Option<(String, bool)> {
    let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(plain) else { return None };
    let id = o.get("notificationId")?.as_str()?;
    if id.is_empty() || id.chars().count() > 512 {
        return None;
    }
    Some((id.to_string(), o.get("callEnded").and_then(Value::as_bool).unwrap_or(false)))
}

pub fn dismiss_payload(id: &str) -> String {
    json!({"notificationId": id}).to_string()
}

/// `notifications.action`: the token the phone gave, and a reply of at most 4,096 characters.
pub fn action_payload(id: &str, token: &str, reply: Option<&str>) -> String {
    let mut o = json!({"notificationId": id, "actionToken": token});
    if let Some(r) = reply.filter(|r| !r.is_empty()) {
        o["replyText"] = json!(r.chars().take(4_096).collect::<String>());
    }
    o.to_string()
}

impl Notification {
    pub fn to_json(&self) -> Value {
        json!({
            "packageName": self.package_name,
            "applicationName": self.application_name,
            "notificationId": self.notification_id,
            "title": self.title,
            "text": self.text,
            "timestamp": self.timestamp,
            "icon": self.icon,
            "callType": self.call_type,
            "actions": self.actions.iter().map(|a| json!({"token": a.token, "title": a.title, "allowsReply": a.allows_reply})).collect::<Vec<_>>(),
            "quiet": self.quiet,
            "redacted": self.redacted.unwrap_or(false),
            "code": self.code.as_ref().map(|c| json!({"code": c.code, "service": c.service, "channel": c.channel.wire()})),
        })
    }
}

/// This device's coarse activity for `presence.state`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Presence {
    /// Input within the last `idle` seconds (under 120: active; 120 to 86400: idle).
    Input { idle: u32 },
    Locked,
    Unknown,
}

/// The `presence.state` plaintext: version 1, the session's sequence, the state, and idleSeconds only for active and
/// idle (protocol/test-vectors/device-presence-v1.json).
pub fn presence_payload(sequence: u64, presence: Presence) -> String {
    match presence {
        Presence::Input { idle } => {
            let idle = idle.min(86_400);
            let state = if idle < 120 { "active" } else { "idle" };
            json!({"version": 1, "sequence": sequence, "state": state, "idleSeconds": idle}).to_string()
        }
        Presence::Locked => json!({"version": 1, "sequence": sequence, "state": "locked"}).to_string(),
        Presence::Unknown => json!({"version": 1, "sequence": sequence, "state": "unknown"}).to_string(),
    }
}

/// `codes.status` from the phone: whether Android shows Bridgey the text of code messages.
pub fn decode_codes_status(plain: &[u8]) -> Option<String> {
    let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(plain) else { return None };
    if o.get("version").and_then(Value::as_i64) != Some(1) {
        return None;
    }
    o.get("status").and_then(Value::as_str).filter(|s| matches!(*s, "allowed" | "hidden" | "not_linked")).map(str::to_string)
}

/// `codes.advertise` (start, with a UUID) or `codes.advertise_stop` (with `linked`).
pub fn decode_advertise(plain: &[u8]) -> Option<(String, Option<bool>)> {
    let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(plain) else { return None };
    if o.get("version").and_then(Value::as_i64) != Some(1) {
        return None;
    }
    let uuid = o.get("serviceUuid")?.as_str().filter(|u| crate::crypto::is_uuid(u))?.to_ascii_lowercase();
    Some((uuid, o.get("linked").and_then(Value::as_bool)))
}

pub fn advertise_result_payload(uuid: &str, ok: bool, reason: Option<&str>) -> String {
    let mut o = json!({"version": 1, "serviceUuid": uuid, "ok": ok});
    if !ok {
        let reason = reason.filter(|r| matches!(*r, "bluetooth_off" | "unauthorized" | "unsupported" | "failed")).unwrap_or("failed");
        o["reason"] = json!(reason);
    }
    o.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn posts_are_bounded_and_checked() {
        let post = json!({
            "packageName": "com.google.android.apps.messaging", "applicationName": "Messages", "notificationId": "0|com.x|1|null|10",
            "title": "HDFC\u{202E}", "text": "line one\nline two\u{200B}", "timestamp": 1_794_000_000_000i64,
            "actions": [{"actionToken": "a1", "title": "Reply", "allowsReply": true}, {"actionToken": "a2", "title": "Mark as read", "allowsReply": false}, {"actionToken": "", "title": "x"}],
            "smsDefaultApp": true, "redacted": false, "callType": "bogus",
        });
        let n = decode_post(post.to_string().as_bytes(), false).unwrap();
        assert_eq!((n.title.as_str(), n.text.as_str()), ("HDFC", "line one\nline two"));
        assert_eq!(n.actions.len(), 2);
        assert!(n.actions[0].allows_reply && !n.quiet && n.call_type.is_none());
        assert_eq!(n.sms_default_app, Some(true));
        assert!(decode_post(br#"{"title":"no id"}"#, false).is_none());
        let quiet = json!({"notificationId": "1", "presentation": "quiet"}).to_string();
        assert!(decode_post(quiet.as_bytes(), false).is_none(), "presentation without negotiated routing is rejected");
        assert!(decode_post(quiet.as_bytes(), true).unwrap().quiet);
        assert!(decode_post(json!({"notificationId": "1", "presentation": "loud"}).to_string().as_bytes(), true).is_none());
        assert!(decode_post(json!({"notificationId": "1", "smsDefaultApp": "yes"}).to_string().as_bytes(), false).is_none());
        assert!(decode_post(br#"{"notificationId":"1","presentation":"alert","presentation":"quiet"}"#, true).is_none(), "duplicate keys");
        let event = "a".repeat(64);
        assert!(decode_post(json!({"notificationId": "1", "eventId": event}).to_string().as_bytes(), true).unwrap().event_id.is_some());
        assert!(decode_post(json!({"notificationId": "1", "eventId": event, "callType": "incoming"}).to_string().as_bytes(), true).is_none(), "never on a call");
    }

    /// Every presence this device can send is one the shared vectors call valid.
    #[test]
    fn presence_matches_the_shared_vectors() {
        let v: Value = serde_json::from_str(&std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/device-presence-v1.json")).unwrap()).unwrap();
        let mut matched = 0;
        for case in v["state"].as_array().unwrap().iter().filter(|c| c["valid"] == true) {
            let p = &case["plaintext"];
            let sequence = p["sequence"].as_u64().unwrap();
            let presence = match p["state"].as_str().unwrap() {
                "active" | "idle" => Presence::Input { idle: p["idleSeconds"].as_u64().unwrap() as u32 },
                "locked" => Presence::Locked,
                _ => Presence::Unknown,
            };
            let ours: Value = serde_json::from_str(&presence_payload(sequence, presence)).unwrap();
            assert_eq!(&ours, p, "{}", case["name"]);
            matched += 1;
        }
        assert!(matched >= 7);
        let clamped: Value = serde_json::from_str(&presence_payload(1, Presence::Input { idle: 999_999 })).unwrap();
        assert_eq!(clamped["idleSeconds"], 86_400);
    }

    #[test]
    fn replies_and_codes_messages() {
        let a: Value = serde_json::from_str(&action_payload("n1", "t1", Some(&"x".repeat(5000)))).unwrap();
        assert_eq!(a["replyText"].as_str().unwrap().len(), 4096);
        assert!(serde_json::from_str::<Value>(&action_payload("n1", "t1", None)).unwrap().get("replyText").is_none());
        assert_eq!(decode_codes_status(br#"{"version":1,"status":"hidden"}"#).as_deref(), Some("hidden"));
        assert_eq!(decode_codes_status(br#"{"version":1,"status":"other"}"#), None);
        let id = crate::crypto::uuid4();
        assert_eq!(decode_advertise(format!(r#"{{"version":1,"serviceUuid":"{id}"}}"#).as_bytes()), Some((id.clone(), None)));
        let r: Value = serde_json::from_str(&advertise_result_payload(&id, false, Some("weird"))).unwrap();
        assert_eq!(r["reason"], "failed");
    }
}
