//! Bridgey Rendezvous v1: WebSocket text frames, one JSON object each, type in `t` (spec 6.2, 6.3).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_FRAME_BYTES: usize = 16 * 1024;
pub const MAX_SIGNAL_BODY: usize = 6 * 1024;
pub const MAX_IDS: usize = 64;
/// The single-flight sign-in: the client's [FastHello] (JSON, base64url) in this upgrade request header.
pub const HELLO_HEADER: &str = "x-bridgey-hello";
/// The service took the [FastHello]: `welcome` is the first frame and no `hello` frame follows.
pub const WELCOME_HEADER: &str = "x-bridgey-welcome";
/// How far a [FastHello] timestamp may be from the service's clock.
pub const FAST_HELLO_WINDOW_MS: u64 = 120_000;
/// `relay.grant` session IDs for a node's own (warm) relay credentials and a reclaimed allocation's.
pub const WARM_SID: &str = "warm";
pub const RECLAIM_SID: &str = "reclaim";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    pub max_ids: u32,
    pub max_signal_bytes: u32,
    pub signals_per_minute: u32,
}

/// A relay in the pool, as `welcome` lists it: its ID and where its STUN answers (for the RTT probe and the
/// permissions a warm allocation installs for every relay).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RelayInfo {
    pub id: String,
    /// `host:port` of the relay's STUN/TURN listener (UDP).
    pub stun: String,
}

/// What a node asks for its own relay allocation, kept warm across sessions (docs/connect-anywhere-latency.md).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WarmRequest {
    /// Measured round trips per relay ID, for the choice.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rtts: Option<BTreeMap<String, u32>>,
    /// Relays that failed for this node.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exclude: Option<Vec<String>>,
    /// The username of this node's earlier warm allocation (a process that was killed left it on the relay):
    /// the service hands back its credential only to the node it was made for, so the node can end it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reclaim: Option<Reclaim>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Reclaim {
    pub relay: String,
    pub username: String,
}

/// The single-flight sign-in, sent as JSON (base64url) in the [HELLO_HEADER] of the upgrade request:
/// hello, auth and register in one flight. `sig` covers [crate::derive::auth_message_v2].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FastHello {
    pub v: u32,
    pub node: String,
    pub app: String,
    pub keepalive: u32,
    pub ts: u64,
    /// base64url, 16 random bytes; used once.
    pub cnonce: String,
    pub sig: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ids: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warm: Option<WarmRequest>,
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        relays: Option<Vec<RelayInfo>>,
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
    /// Credentials for the node's own relay allocation (granted as `relay.grant` with sid [WARM_SID]), and
    /// optionally an earlier warm allocation's credential back (sid [RECLAIM_SID]).
    #[serde(rename = "relay.warm")]
    RelayWarm {
        #[serde(flatten)]
        request: WarmRequest,
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

/// A node's warm relay username: `"<expiry>:w.<tag>"`, tag = base64url(HMAC-SHA256(secret,
/// "bridgey-warm-v1" \0 nodeId \0 expiry)[0..9]). Only the service (it holds the secret) can tie it to the node,
/// so it can give the credential back to that node alone; the relay sees an opaque name.
pub fn warm_username(secret: &[u8], expiry_unix_s: u64, node_id: &str) -> String {
    let expiry = expiry_unix_s.to_string();
    let mac = crate::derive::hmac_sha256(secret, &[b"bridgey-warm-v1\0", node_id.as_bytes(), b"\0", expiry.as_bytes()]);
    format!("{expiry}:w.{}", crate::b64::url_encode(&mac[..9]))
}

/// The credential for any TURN REST username: base64(HMAC-SHA1(secret, username)).
pub fn turn_rest_credential(secret: &[u8], username: &str) -> String {
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, secret);
    crate::b64::std_encode(ring::hmac::sign(&key, username.as_bytes()).as_ref())
}

/// The expiry of a warm username made for `node_id` with `secret`, or `None` if it was not.
pub fn warm_username_expiry(secret: &[u8], username: &str, node_id: &str) -> Option<u64> {
    let (expiry, rest) = username.split_once(':')?;
    rest.strip_prefix("w.")?;
    let expiry: u64 = expiry.parse().ok()?;
    let expected = warm_username(secret, expiry, node_id);
    let same = expected.len() == username.len() && expected.bytes().zip(username.bytes()).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0;
    same.then_some(expiry)
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
        assert!(matches!(welcome, Some(Msg::Welcome { relays: None, .. })));
        let welcome = Msg::parse(r#"{"t":"welcome","nodeId":"x","now":1,"limits":{"maxIds":64,"maxSignalBytes":6144,"signalsPerMinute":120},"relays":[{"id":"sin","stun":"relay-sg.roundrobin.in:3478"}]}"#);
        assert!(matches!(welcome, Some(Msg::Welcome { relays: Some(r), .. }) if r[0].id == "sin"));
        let warm = Msg::parse(r#"{"t":"relay.warm","rtts":{"sin":70},"reclaim":{"relay":"sin","username":"1:w.x"}}"#).unwrap();
        assert!(matches!(warm, Msg::RelayWarm { request } if request.reclaim.as_ref().unwrap().relay == "sin"));
        assert_eq!(Msg::RelayWarm { request: WarmRequest::default() }.to_text(), r#"{"t":"relay.warm"}"#);
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
        assert_eq!(turn_rest_credential(b"secret", &user), cred);
    }

    #[test]
    fn warm_names() {
        let user = warm_username(b"secret", 1_761_407_200, "nodeA");
        assert!(user.starts_with("1761407200:w.") && user.len() == "1761407200:w.".len() + 12);
        assert_eq!(warm_username_expiry(b"secret", &user, "nodeA"), Some(1_761_407_200));
        assert_eq!(warm_username_expiry(b"secret", &user, "nodeB"), None);
        assert_eq!(warm_username_expiry(b"other", &user, "nodeA"), None);
        assert_eq!(warm_username_expiry(b"secret", "1761407200:q7Lw0d3x.0", "nodeA"), None);
    }
}
