//! `features.update`: the map each device sends after pairing and whenever its local policy changes
//! (docs/protocol.md "Session negotiation", protocol/messages.json `features`). Decoding follows
//! ProtocolDecoding.kt `decodeFeatureState` and the Mac's `ProtocolDecoding.swift`.

use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// Upstream v1 keys every map must carry; a peer that leaves one out sent an invalid state.
pub const REQUIRED: [&str; 5] = ["clipboard", "files", "notifications", "battery", "find_device"];
/// Later upstream keys: missing means false, but a present value must be a boolean.
pub const OPTIONAL: [&str; 4] = ["ping", "links", "media", "calls"];
/// The longest key this client keeps from a peer's map.
const MAX_KEY: usize = 64;
/// At most this many keys are kept from a peer's map.
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
    // Draft keys: true only when JSON true; anything else reads false.
    for (key, value) in values.iter().filter(|(k, _)| !upstream(k)).take(MAX_KEYS) {
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
    }
}
