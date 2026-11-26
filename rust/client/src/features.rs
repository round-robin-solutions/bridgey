//! `features.update`: the map each device sends after pairing and whenever its local policy changes
//! (docs/protocol.md "Session negotiation", protocol/messages.json `features`). Decoding follows
//! ProtocolDecoding.kt `decodeFeatureState` and the Mac's `ProtocolDecoding.swift`.

use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// Upstream v1 keys every map must carry; a peer that leaves one out sent an invalid state.
pub const REQUIRED: [&str; 5] = ["clipboard", "files", "notifications", "battery", "find_device"];
/// Later upstream keys: missing means false, but a present value must be a boolean.
pub const OPTIONAL: [&str; 4] = ["ping", "links", "media", "calls"];
/// Every other key in protocol/messages.json. Each is read from any map, whatever else it holds, as Android and the
/// Mac read the keys they know (docs/protocol.md "Session negotiation"); a test keeps the list complete.
pub const EDITION: [&str; 37] = [
    "clipboard_files_draft1", "remote_input_draft1", "sms_codes_draft1", "email_codes_draft1", "folders_draft1",
    "places_draft1", "files_browse_draft1", "folders_receive_draft1", "mac_actions_draft1", "links_open_draft1",
    "focus_sync_draft1", "camera_draft1", "updates_draft1", "screen_draft1", "screen_control_draft1",
    "phone_control_draft1", "files_fast_draft1", "files_resume_draft1", "sms_draft1", "settings_sync_draft1",
    "connect_draft1", "lan_first_draft1", "lan_first_draft2", "agent_draft1", "notify_draft1", "ask_draft1",
    "clipboard_request_draft1", "agent_codes_draft1", "agents_mirror_draft1", "codes_detect_draft1",
    "agent_notifications_draft1", "call_quiet_draft1", "dialer_draft1", "device_presence_draft1",
    "share_receive_draft1", "notification_routing_draft1", "handoff_takeover_draft1",
];
/// The longest key a map may carry; longer unknown keys are ignored.
const MAX_KEY: usize = 64;
/// A map carries at most this many keys. Unknown keys are kept, for the host app, until the map holds this many.
const MAX_KEYS: usize = 128;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FeatureMap {
    values: BTreeMap<String, bool>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Decoded {
    State(FeatureMap),
    /// A version this client does not know: keep the previous state.
    Ignored,
    /// Malformed: the apps close the session.
    Invalid,
}

fn upstream(key: &str) -> bool {
    REQUIRED.contains(&key) || OPTIONAL.contains(&key)
}

impl FeatureMap {
    pub fn new() -> FeatureMap {
        FeatureMap::default()
    }

    /// Every upstream key off: what a device that has sent nothing yet is assumed to allow.
    pub fn all_off() -> FeatureMap {
        let mut map = FeatureMap::new();
        for key in REQUIRED.iter().chain(OPTIONAL.iter()) {
            map.set(key, false);
        }
        map
    }

    pub fn get(&self, key: &str) -> bool {
        self.values.get(key).copied().unwrap_or(false)
    }

    pub fn set(&mut self, key: &str, on: bool) {
        self.values.insert(key.to_string(), on);
    }

    pub fn keys(&self) -> impl Iterator<Item = (&str, bool)> {
        self.values.iter().map(|(k, v)| (k.as_str(), *v))
    }

    /// A feature is available only when both ends report it on.
    pub fn both(&self, remote: &FeatureMap, key: &str) -> bool {
        self.get(key) && remote.get(key)
    }

    /// The plaintext of `features.update`: every upstream key, plus the draft keys that are set.
    pub fn encode(&self) -> Vec<u8> {
        let mut features = Map::new();
        for key in REQUIRED.iter().chain(OPTIONAL.iter()) {
            features.insert((*key).into(), Value::Bool(self.get(key)));
        }
        for (key, on) in &self.values {
            if !upstream(key) && *on {
                features.insert(key.clone(), Value::Bool(true));
            }
        }
        let mut payload = Map::new();
        payload.insert("version".into(), Value::from(1));
        payload.insert("features".into(), Value::Object(features));
        Value::Object(payload).to_string().into_bytes()
    }

    pub fn to_json(&self) -> Value {
        Value::Object(self.values.iter().map(|(k, v)| (k.clone(), Value::Bool(*v))).collect())
    }
}

/// An integral JSON number (both apps accept 1 and 1.0).
fn integer(v: Option<&Value>) -> Option<i64> {
    let n = v?.as_number()?;
    n.as_i64().or_else(|| n.as_f64().filter(|f| f.fract() == 0.0 && f.abs() < 9.007e15).map(|f| f as i64))
}

pub fn decode(plaintext: &[u8]) -> Decoded {
    let Ok(Value::Object(payload)) = serde_json::from_slice::<Value>(plaintext) else { return Decoded::Invalid };
    let Some(Value::Object(values)) = payload.get("features") else { return Decoded::Invalid };
    if integer(payload.get("version")) != Some(1) {
        return Decoded::Ignored;
    }
    let mut map = FeatureMap::new();
    for key in REQUIRED {
        match values.get(key) {
            Some(Value::Bool(on)) => map.set(key, *on),
            _ => return Decoded::Invalid,
        }
    }
    for key in OPTIONAL {
        match values.get(key) {
            None => map.set(key, false),
            Some(Value::Bool(on)) => map.set(key, *on),
            Some(_) => return Decoded::Invalid,
        }
    }
    // Edition keys: true only when JSON true; anything else reads false. A known key is read wherever it is in the map;
    // unknown ones fill what is left of the 128, so a crowded map never hides a known key.
    for key in EDITION {
        if values.get(key) == Some(&Value::Bool(true)) {
            map.set(key, true);
        }
    }
    for (key, value) in values.iter().filter(|(k, _)| !upstream(k) && !EDITION.contains(&k.as_str())) {
        if map.values.len() >= MAX_KEYS {
            break;
        }
        if key.len() <= MAX_KEY && *value == Value::Bool(true) {
            map.set(key, true);
        }
    }
    Decoded::State(map)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_keeps_upstream_keys_and_set_drafts() {
        let mut map = FeatureMap::all_off();
        map.set("clipboard", true);
        map.set("ping", true);
        map.set("device_presence_draft1", true);
        map.set("clipboard_files_draft1", false);
        let text = String::from_utf8(map.encode()).unwrap();
        assert!(text.contains("\"find_device\":false"));
        assert!(!text.contains("clipboard_files_draft1"));
        let Decoded::State(back) = decode(text.as_bytes()) else { panic!("decodes") };
        assert!(back.get("clipboard") && back.get("ping") && back.get("device_presence_draft1"));
        assert!(!back.get("files") && !back.get("clipboard_files_draft1"));
    }

    #[test]
    fn missing_required_key_is_invalid() {
        let text = br#"{"version":1,"features":{"clipboard":true,"files":true,"notifications":true,"battery":true}}"#;
        assert_eq!(decode(text), Decoded::Invalid);
    }

    #[test]
    fn optional_keys_default_off_and_must_be_boolean() {
        let base = r#""clipboard":true,"files":false,"notifications":false,"battery":false,"find_device":false"#;
        let Decoded::State(m) = decode(format!(r#"{{"version":1,"features":{{{base}}}}}"#).as_bytes()) else { panic!() };
        assert!(!m.get("ping"));
        assert_eq!(decode(format!(r#"{{"version":1,"features":{{{base},"ping":1}}}}"#).as_bytes()), Decoded::Invalid);
        let Decoded::State(m) = decode(format!(r#"{{"version":1.0,"features":{{{base},"x_draft1":"yes"}}}}"#).as_bytes()) else { panic!() };
        assert!(!m.get("x_draft1"));
    }

    #[test]
    fn unknown_version_is_ignored_and_garbage_invalid() {
        assert_eq!(decode(br#"{"version":2,"features":{}}"#), Decoded::Ignored);
        assert_eq!(decode(br#"{"version":1}"#), Decoded::Invalid);
        assert_eq!(decode(b"[]"), Decoded::Invalid);
        assert_eq!(decode(b"\xff"), Decoded::Invalid);
    }

    /// protocol-v1.json featuresUpdate, as Android and the Mac read it: the same outcome, and every key their expect lists
    /// reads the same here. The two size cases: a map of 128 keys is kept whole, and a crowded one still shows every
    /// known key.
    #[test]
    fn golden_feature_maps() {
        let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/protocol-v1.json")).unwrap();
        let doc: Value = serde_json::from_str(&text).unwrap();
        for v in doc["featuresUpdate"].as_array().unwrap() {
            let name = v["name"].as_str().unwrap();
            let plain = match v.get("plaintextString") {
                Some(s) => s.as_str().unwrap().as_bytes().to_vec(),
                None => v["plaintext"].to_string().into_bytes(),
            };
            let decoded = decode(&plain);
            match (&decoded, &v["expect"]) {
                (Decoded::Invalid, e) if e == "invalid" => {}
                (Decoded::Ignored, e) if e == "ignored" => {}
                (Decoded::State(map), Value::Object(e)) => {
                    for (key, on) in e["features"].as_object().unwrap().iter().chain(e["drafts"].as_object().unwrap()) {
                        // remote_input_draft1: Android and the Mac close on a non-boolean; this client never offers remote
                        // input, so it reads such a value as false and the vectors have no such case.
                        assert_eq!(map.get(key), on.as_bool().unwrap(), "{name}: {key}");
                    }
                    if name == "a map of 128 keys is read in full" {
                        let sent = v["plaintext"]["features"].as_object().unwrap();
                        assert_eq!(sent.len(), MAX_KEYS);
                        for (key, on) in sent {
                            assert_eq!(map.get(key), on.as_bool().unwrap(), "{name}: {key}");
                        }
                    }
                    if name == "over 128 keys, every known key is still read" {
                        let sent = v["plaintext"]["features"].as_object().unwrap();
                        assert!(sent.len() > MAX_KEYS);
                        for key in EDITION.iter().filter(|k| sent.get(**k) == Some(&Value::Bool(true))) {
                            assert!(map.get(key), "{name}: {key}");
                        }
                        assert_eq!(map.keys().count(), MAX_KEYS);
                    }
                }
                (got, e) => panic!("{name}: decoded {got:?}, expected {e}"),
            }
        }
    }

    /// Every feature key the contract lists decodes as the contract says.
    #[test]
    fn contract_feature_keys() {
        let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/messages.json")).unwrap();
        let contract: Value = serde_json::from_str(&text).unwrap();
        let mut required = Vec::new();
        for f in contract["features"].as_array().unwrap() {
            let key = f["key"].as_str().unwrap();
            if f["requiredInMap"] == Value::Bool(true) {
                required.push(key.to_string());
            } else if f["status"] == "upstream-v1" {
                assert!(OPTIONAL.contains(&key), "{key} is an optional upstream key");
            }
        }
        required.sort();
        let mut ours: Vec<String> = REQUIRED.iter().map(|s| s.to_string()).collect();
        ours.sort();
        assert_eq!(required, ours);
        let listed: Vec<&str> = contract["features"].as_array().unwrap().iter().map(|f| f["key"].as_str().unwrap()).filter(|k| !upstream(k)).collect();
        assert_eq!(listed, EDITION, "EDITION lists every other key in protocol/messages.json, in its order");
    }
}
