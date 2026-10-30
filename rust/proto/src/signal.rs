//! Sealed signalling plaintexts (spec 6.4). The same shapes travel in-band as `connect.*` messages.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const MAX_CANDIDATES: usize = 24;

/// `{"k":"host|prflx|srflx|mapped|relay","a":"<ip>","p":<port>,"net":"lan|vpn|public6|cell|wifi","pri":<u32>,"relay":"bom"}`
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Candidate {
    pub k: String,
    pub a: String,
    pub p: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub net: Option<String>,
    pub pri: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct NetInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nat: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub v6: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t")]
pub enum Signal {
    #[serde(rename = "offer")]
    Offer(Description),
    #[serde(rename = "answer")]
    Answer(Description),
    #[serde(rename = "cand")]
    Cand { sid: String, cands: Vec<Candidate>, done: bool, ts: u64, seq: u64 },
    #[serde(rename = "restart")]
    Restart { sid: String, ufrag: String, pwd: String, reason: String, ts: u64, seq: u64 },
    #[serde(rename = "bye")]
    Bye { sid: String, reason: String, ts: u64, seq: u64 },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Description {
    pub sid: String,
    pub v: u32,
    pub ufrag: String,
    pub pwd: String,
    pub cands: Vec<Candidate>,
    /// `certSha256`: SHA-256 of the sender's DER certificate, base64url.
    pub cert: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rtts: Option<BTreeMap<String, u32>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub net: Option<NetInfo>,
    pub ts: u64,
    pub seq: u64,
}

impl Signal {
    pub fn sid(&self) -> &str {
        match self {
            Signal::Offer(d) | Signal::Answer(d) => &d.sid,
            Signal::Cand { sid, .. } | Signal::Restart { sid, .. } | Signal::Bye { sid, .. } => sid,
        }
    }

    pub fn ts(&self) -> u64 {
        match self {
            Signal::Offer(d) | Signal::Answer(d) => d.ts,
            Signal::Cand { ts, .. } | Signal::Restart { ts, .. } | Signal::Bye { ts, .. } => *ts,
        }
    }

    pub fn seq(&self) -> u64 {
        match self {
            Signal::Offer(d) | Signal::Answer(d) => d.seq,
            Signal::Cand { seq, .. } | Signal::Restart { seq, .. } | Signal::Bye { seq, .. } => *seq,
        }
    }

    /// Size and count limits; `ts` must be within 5 minutes of `now_ms`.
    pub fn valid(&self, now_ms: u64) -> bool {
        let fresh = self.ts().abs_diff(now_ms) <= 300_000;
        let shape = match self {
            Signal::Offer(d) | Signal::Answer(d) => {
                d.v == 1 && d.ufrag.len() == 8 && d.pwd.len() == 24 && d.cands.len() <= MAX_CANDIDATES && d.cert.len() <= 64
            }
            Signal::Cand { cands, .. } => cands.len() <= MAX_CANDIDATES,
            Signal::Restart { ufrag, pwd, .. } => ufrag.len() == 8 && pwd.len() == 24,
            Signal::Bye { reason, .. } => reason.len() <= 32,
        };
        fresh && shape
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes() {
        let offer = Signal::Offer(Description {
            sid: "s".into(),
            v: 1,
            ufrag: "abcdefgh".into(),
            pwd: "abcdefghijklmnopqrstuvwx".into(),
            cands: vec![Candidate { k: "relay".into(), a: "192.0.2.1".into(), p: 50000, net: None, pri: 1, relay: Some("bom".into()) }],
            cert: "c".into(),
            rtts: None,
            net: None,
            ts: 1000,
            seq: 1,
        });
        let text = serde_json::to_string(&offer).unwrap();
        assert!(text.starts_with(r#"{"t":"offer","sid":"s""#));
        let back: Signal = serde_json::from_str(&text).unwrap();
        assert_eq!(back, offer);
        assert!(back.valid(1000));
        assert!(!back.valid(1000 + 300_001));
    }
}
