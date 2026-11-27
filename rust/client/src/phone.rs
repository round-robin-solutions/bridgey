//! The phone's own features on this device (docs/session-client.md): text messages (`sms.rs`), the Calls window, the
//! phone's files and its screen, one module each.
//!
//! Each area follows one pattern, so a host learns it once:
//! - The session hands every encrypted message of an area's kinds, opened and within the kind's size, to the client
//!   (`incoming` below) when this device has the area's feature on for that phone. A payload that does not open is
//!   dropped and the session stays, as for every draft.
//! - The area's module checks and decodes it, keeps what it needs in memory, and tells the host what changed with one
//!   event kind per area (`Event::Phone`): `what` names the change, `json` carries the detail.
//! - The host asks with one JSON command per call (`bridgey_phone` with the area, `Client::phone` in Rust) and gets a
//!   JSON answer at once: `{"ok": true, ...}` or `{"ok": false, "error": "..."}`. Requests to the phone answer later
//!   through events, matched by the request ID the command returned.
//!
//! Content is sensitive: nothing in these modules logs message text, numbers, names or file names.

use serde_json::{json, Value};

/// The event kind each area's events use (BridgeyEventKind 32 to 35 in the C ABI).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Area {
    Sms,
    Calls,
    PhoneFiles,
    Screen,
}

impl Area {
    /// The C ABI's event kind.
    pub fn event_kind(self) -> u32 {
        match self {
            Area::Sms => 32,
            Area::Calls => 33,
            Area::PhoneFiles => 34,
            Area::Screen => 35,
        }
    }
}

/// An encrypted kind an area takes from a phone: its feature key (the switch on this device that lets it in) and the
/// largest plaintext accepted (protocol/messages.json `maxPlaintextBytes`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Incoming {
    pub area: Area,
    pub kind: &'static str,
    pub feature: &'static str,
    pub max: usize,
}

/// Each area's state, kept by the client.
#[derive(Default)]
pub struct State {
    pub(crate) sms: std::sync::Mutex<crate::sms::State>,
}

/// The area kind a session passes on, if any.
pub fn incoming(kind: &str) -> Option<Incoming> {
    crate::sms::incoming(kind)
}

/// A message of an area from a phone, opened by the session (the area's feature is on here).
pub(crate) fn receive(inner: &crate::client::Inner, area: Area, device_id: &str, kind: &str, plain: &[u8]) {
    match area {
        Area::Sms => crate::sms::receive(inner, device_id, kind, plain),
        // No kinds of their own yet (incoming lists none).
        Area::Calls | Area::PhoneFiles | Area::Screen => {}
    }
}

/// A host command for an area with a trusted device.
pub(crate) fn command(inner: &crate::client::Inner, area: Area, device_id: &str, command: &Value) -> Value {
    match area {
        Area::Sms => crate::sms::command(inner, device_id, command),
        Area::Calls | Area::PhoneFiles | Area::Screen => error("unsupported"),
    }
}

/// Either side's switches changed for a connected device.
pub(crate) fn features_changed(inner: &crate::client::Inner, device_id: &str) {
    crate::sms::features_changed(inner, device_id);
}

/// The session with the device ended: requests in flight are dropped, what is kept stays.
pub(crate) fn disconnected(inner: &crate::client::Inner, device_id: &str) {
    crate::sms::disconnected(inner, device_id);
}

/// The device was forgotten: everything kept for it goes.
pub(crate) fn forgotten(inner: &crate::client::Inner, device_id: &str) {
    crate::sms::forgotten(inner, device_id);
}

/// A command's answer when it worked.
pub fn ok(mut fields: Value) -> Value {
    if let Value::Object(o) = &mut fields {
        o.insert("ok".into(), Value::Bool(true));
        return fields;
    }
    json!({"ok": true})
}

/// A command's answer when it did not: `not_connected`, `feature_off`, `invalid`, `busy`, `unsupported`, ...
pub fn error(code: &str) -> Value {
    json!({"ok": false, "error": code})
}

/// What a command's `op` names, or None.
pub fn op(command: &Value) -> Option<&str> {
    command.get("op").and_then(Value::as_str)
}

/// A lowercase UUID request ID from a phone's answer (any letter case on the wire), as the apps accept it.
pub fn request_id(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?;
    if text.len() != 36 || !crate::crypto::is_uuid(&text.to_ascii_lowercase()) {
        return None;
    }
    Some(text.to_ascii_lowercase())
}

/// An integral JSON number (both apps read 30 and 30.0 alike).
pub fn integer(value: Option<&Value>) -> Option<i64> {
    let n = value?.as_number()?;
    n.as_i64().or_else(|| n.as_f64().filter(|f| f.fract() == 0.0 && f.abs() < 9.007e15).map(|f| f as i64))
}

/// A length in UTF-16 units, as Android and the Mac count text limits.
pub fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// JSON as the apps' strict decoders take it: unique keys in every object and at most 32 levels deep.
pub fn strict(plain: &[u8]) -> Option<Value> {
    use serde::de::{DeserializeSeed, Deserializer, MapAccess, SeqAccess, Visitor};
    struct Strict(usize);
    impl<'de> DeserializeSeed<'de> for Strict {
        type Value = Value;
        fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
            d.deserialize_any(self)
        }
    }
    impl<'de> Visitor<'de> for Strict {
        type Value = Value;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("JSON with unique keys")
        }
        fn visit_bool<E>(self, v: bool) -> Result<Value, E> {
            Ok(Value::Bool(v))
        }
        fn visit_i64<E>(self, v: i64) -> Result<Value, E> {
            Ok(Value::from(v))
        }
        fn visit_u64<E>(self, v: u64) -> Result<Value, E> {
            Ok(Value::from(v))
        }
        fn visit_f64<E>(self, v: f64) -> Result<Value, E> {
            Ok(serde_json::Number::from_f64(v).map(Value::Number).unwrap_or(Value::Null))
        }
        fn visit_str<E>(self, v: &str) -> Result<Value, E> {
            Ok(Value::String(v.to_string()))
        }
        fn visit_string<E>(self, v: String) -> Result<Value, E> {
            Ok(Value::String(v))
        }
        fn visit_unit<E>(self) -> Result<Value, E> {
            Ok(Value::Null)
        }
        fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
            if self.0 >= 32 {
                return Err(serde::de::Error::custom("too deep"));
            }
            let mut list = Vec::new();
            while let Some(v) = seq.next_element_seed(Strict(self.0 + 1))? {
                list.push(v);
            }
            Ok(Value::Array(list))
        }
        fn visit_map<A: MapAccess<'de>>(self, mut access: A) -> Result<Value, A::Error> {
            if self.0 >= 32 {
                return Err(serde::de::Error::custom("too deep"));
            }
            let mut map = serde_json::Map::new();
            while let Some(key) = access.next_key::<String>()? {
                let value = access.next_value_seed(Strict(self.0 + 1))?;
                if map.insert(key, value).is_some() {
                    return Err(serde::de::Error::custom("duplicate key"));
                }
            }
            Ok(Value::Object(map))
        }
    }
    let mut de = serde_json::Deserializer::from_slice(plain);
    let value = Strict(0).deserialize(&mut de).ok()?;
    de.end().ok()?;
    Some(value)
}

/// A JSON object with unique keys and `version: 1`, at most `max` bytes, as the apps decode drafts.
pub fn versioned(plain: &[u8], max: usize) -> Option<serde_json::Map<String, Value>> {
    if plain.len() > max {
        return None;
    }
    let Value::Object(o) = strict(plain)? else { return None };
    (integer(o.get("version")) == Some(1)).then_some(o)
}

/// A non-negative integer.
pub fn non_negative(value: Option<&Value>) -> Option<i64> {
    integer(value).filter(|n| *n >= 0)
}

/// A JSON boolean (never a number).
pub fn boolean(value: Option<&Value>) -> Option<bool> {
    value?.as_bool()
}

/// Delays a piece of work on the client's runtime; it runs only while the client is alive.
pub(crate) fn after(inner: &crate::client::Inner, delay: std::time::Duration, work: impl FnOnce(&crate::client::Inner) + Send + 'static) {
    let me = std::sync::Arc::downgrade(&inner.arc());
    inner.rt.spawn(async move {
        tokio::time::sleep(delay).await;
        if let Some(inner) = me.upgrade() {
            work(&inner);
        }
    });
}

/// Tells the host about a change in one of the areas.
pub(crate) fn emit(inner: &crate::client::Inner, area: Area, device_id: &str, what: &str, id: u64, detail: Value) {
    inner.emit(crate::events::Event::Phone { area, device_id: device_id.to_string(), what: what.to_string(), id, json: detail.to_string() });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_ids_are_lowercase_uuids() {
        assert_eq!(request_id(Some(&json!("5B6C7D8E-9F01-4A2B-8C3D-4E5F60718293"))).as_deref(), Some("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293"));
        assert!(request_id(Some(&json!("block-1"))).is_none());
        assert!(request_id(Some(&json!(5))).is_none());
        assert!(request_id(None).is_none());
    }

    #[test]
    fn strict_json() {
        assert!(strict(br#"{"a":{"b":1,"b":2}}"#).is_none());
        assert!(strict(br#"[{"a":1},{"a":2}]"#).is_some());
        assert!(strict(format!("{}{}", "[".repeat(33), "]".repeat(33)).as_bytes()).is_none());
        assert!(strict(format!("{}{}", "[".repeat(32), "]".repeat(32)).as_bytes()).is_some());
        assert!(strict(br#"{"a":1} x"#).is_none());
    }

    #[test]
    fn versioned_objects() {
        assert!(versioned(br#"{"version":1}"#, 64).is_some());
        assert!(versioned(br#"{"version":1.0}"#, 64).is_some());
        assert!(versioned(br#"{"version":2}"#, 64).is_none());
        assert!(versioned(br#"{"version":1,"a":1,"a":2}"#, 64).is_none());
        assert!(versioned(br#"{"version":1}"#, 4).is_none());
    }

    /// Every kind an area takes is in protocol/messages.json with its limit, and its feature is the kind's (or, for a
    /// kind two keys gate, the switch this device uses for it).
    #[test]
    fn incoming_kinds_match_the_contract() {
        let contract: Value = serde_json::from_str(include_str!("../../../protocol/messages.json")).unwrap();
        let mut checked = 0;
        for m in contract["messages"].as_array().unwrap() {
            let kind = m["kind"].as_str().unwrap();
            let Some(spec) = incoming(kind) else { continue };
            checked += 1;
            assert_eq!(spec.kind, kind);
            if let Some(max) = m["maxPlaintextBytes"].as_u64() {
                assert_eq!(spec.max as u64, max, "{kind}: the limit in protocol/messages.json");
            }
            let feature = m["feature"].as_str().unwrap_or("");
            assert!(feature.split(" | ").any(|f| f == spec.feature) || spec.feature == "files", "{kind}: feature {} is not {feature}", spec.feature);
        }
        let _ = checked;
    }

    #[test]
    fn utf16_counts_like_the_apps() {
        assert_eq!(utf16_len("abc"), 3);
        assert_eq!(utf16_len("😀"), 2);
    }
}
