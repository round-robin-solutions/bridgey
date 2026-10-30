//! Bridgey Rendezvous v1: WebSocket text frames, one JSON object each, type in `t` (spec 6.2, 6.3).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_FRAME_BYTES: usize = 16 * 1024;
pub const MAX_SIGNAL_BODY: usize = 6 * 1024;
pub const MAX_IDS: usize = 64;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    pub max_ids: u32,
    pub max_signal_bytes: u32,
    pub signals_per_minute: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayGrant {
    pub id: String,
    pub kind: String,
    pub urls: Vec<String>,
    pub username: String,
    pub credential: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spki: Option<String>,
    pub expires_at: u64,
    pub max_kbps: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t")]
pub enum Msg {
    #[serde(rename = "hello")]
    Hello { v: u32, node: String, app: String, keepalive: u32 },
    #[serde(rename = "challenge")]
    Challenge { nonce: String, pow: u32 },
    #[serde(rename = "auth")]
    Auth {
        sig: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pow: Option<String>,
    },
    #[serde(rename = "welcome")]
    Welcome {
        #[serde(rename = "nodeId")]
        node_id: String,
        now: u64,
        limits: Limits,
    },
    #[serde(rename = "register")]
    Register { ids: Vec<String> },
    #[serde(rename = "registered")]
    Registered { online: Vec<String> },
    #[serde(rename = "presence")]
    Presence { rdv: String, online: bool },
    #[serde(rename = "signal")]
    Signal { rdv: String, side: u8, sid: String, body: String },
    #[serde(rename = "undeliverable")]
    Undeliverable { rdv: String, sid: String },
    #[serde(rename = "relay.request")]
    RelayRequest {
        rdv: String,
        sid: String,
        side: u8,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        rtts: Option<BTreeMap<String, u32>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        need: Option<String>,
        #[serde(default, rename = "estBytes", skip_serializing_if = "Option::is_none")]
        est_bytes: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exclude: Option<Vec<String>>,
    },
    #[serde(rename = "relay.claim")]
    RelayClaim { rdv: String, sid: String, side: u8 },
    #[serde(rename = "relay.grant")]
    RelayGrantMsg { sid: String, relay: RelayGrant },
    #[serde(rename = "relay.denied")]
    RelayDenied {
        sid: String,
        code: String,
        #[serde(rename = "retryAfterMs")]
        retry_after_ms: u64,
    },
    #[serde(rename = "relay.release")]
    RelayRelease { sid: String },
    #[serde(rename = "error")]
    Error {
        code: String,
        #[serde(default, rename = "retryAfterMs", skip_serializing_if = "Option::is_none")]
        retry_after_ms: Option<u64>,
    },
}

impl Msg {
    pub fn to_text(&self) -> String {
        serde_json::to_string(self).expect("serialise")
    }

    /// Parses one frame; oversized or malformed frames are `None`.
    pub fn parse(text: &str) -> Option<Msg> {
        if text.len() > MAX_FRAME_BYTES {
            return None;
        }
        serde_json::from_str(text).ok()
    }
}

/// A rendezvous ID: base64url of 16 bytes (22 characters).
pub fn valid_rdv(id: &str) -> bool {
    id.len() == 22 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// A session ID: base64url of 16 bytes.
pub fn valid_sid(sid: &str) -> bool {
    valid_rdv(sid)
}

/// TURN REST credentials (draft-uberti-behave-turn-rest-00, coturn `use-auth-secret`):
/// `username = "<expiry>:<first 8 chars of sid>.<side>"`, `credential = base64(HMAC-SHA1(secret, username))`.
pub fn turn_rest_credentials(secret: &[u8], expiry_unix_s: u64, sid: &str, side: u8) -> (String, String) {
    let prefix: String = sid.chars().take(8).collect();
    let username = format!("{expiry_unix_s}:{prefix}.{side}");
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, secret);
    let tag = ring::hmac::sign(&key, username.as_bytes());
    (username, crate::b64::std_encode(tag.as_ref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_names() {
        let hello = Msg::Hello { v: 1, node: "n".into(), app: "a".into(), keepalive: 120 };
        assert_eq!(hello.to_text(), r#"{"t":"hello","v":1,"node":"n","app":"a","keepalive":120}"#);
        let welcome = Msg::parse(r#"{"t":"welcome","nodeId":"x","now":1,"limits":{"maxIds":64,"maxSignalBytes":6144,"signalsPerMinute":120}}"#);
        assert!(matches!(welcome, Some(Msg::Welcome { .. })));
        let request = Msg::parse(r#"{"t":"relay.request","rdv":"r","sid":"s","side":0,"rtts":{"bom":31},"need":"udp","estBytes":5}"#).unwrap();
        assert!(matches!(request, Msg::RelayRequest { est_bytes: Some(5), .. }));
        assert!(Msg::parse(r#"{"t":"nope"}"#).is_none());
        assert!(Msg::parse(&format!(r#"{{"t":"register","ids":["{}"]}}"#, "a".repeat(MAX_FRAME_BYTES))).is_none());
    }

    #[test]
    fn turn_rest() {
        let (user, cred) = turn_rest_credentials(b"secret", 1_761_407_200, "q7Lw0d3xV2c9kP1sR8uT4w", 0);
        assert_eq!(user, "1761407200:q7Lw0d3x.0");
        assert_eq!(cred.len(), 28);
    }
}
