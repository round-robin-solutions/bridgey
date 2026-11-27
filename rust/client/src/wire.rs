//! The native frame: one JSON object per line, at most 65,536 bytes (docs/protocol-contract.md), and the
//! protocol 2 envelope tag over the sender's device ID and every envelope field in a fixed order.

use crate::crypto::{b64, length_prefixed, unb64};
use bridgey_connect_proto::derive::hmac_sha256;
use serde_json::{Map, Value};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::net::tcp::OwnedReadHalf;
use tokio::sync::mpsc;

pub const MAX_FRAME: usize = 65_536;
const MAX_DEPTH: usize = 32;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Message {
    pub kind: String,
    pub session_id: String,
    pub device_id: Option<String>,
    pub device_name: Option<String>,
    pub public_key: Option<String>,
    pub identity_key: Option<String>,
    pub proof: Option<String>,
    pub signature: Option<String>,
    pub message_id: Option<String>,
    pub nonce: Option<String>,
    pub ciphertext: Option<String>,
    pub transfer_id: Option<String>,
    pub sequence: Option<i64>,
    pub target_device_id: Option<String>,
    pub commitment: Option<String>,
    pub protocol_version: Option<i64>,
    pub tag: Option<String>,
    pub reason: Option<String>,
}

const MAX_SAFE: i64 = 9_007_199_254_740_991;

fn depth(v: &Value) -> usize {
    match v {
        Value::Array(a) => 1 + a.iter().map(depth).max().unwrap_or(0),
        Value::Object(o) => 1 + o.values().map(depth).max().unwrap_or(0),
        _ => 0,
    }
}

impl Message {
    pub fn new(kind: &str, session_id: &str) -> Message {
        Message { kind: kind.into(), session_id: session_id.into(), ..Default::default() }
    }

    /// A frame (without its line feed). Any error closes the session before dispatch.
    pub fn decode(line: &[u8]) -> Result<Message, &'static str> {
        if line.len() > MAX_FRAME {
            return Err("frame over 65,536 bytes");
        }
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        let value: Value = serde_json::from_slice(line).map_err(|_| "not JSON")?;
        if depth(&value) > MAX_DEPTH {
            return Err("too deep");
        }
        let Value::Object(o) = value else { return Err("not an object") };
        let string = |name: &str| -> Result<Option<String>, &'static str> {
            match o.get(name) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if s.is_empty() => Ok(None),
                Some(Value::String(s)) => Ok(Some(s.clone())),
                Some(_) => Err("wrong field type"),
            }
        };
        let integer = |name: &str| -> Result<Option<i64>, &'static str> {
            match o.get(name) {
                None | Some(Value::Null) => Ok(None),
                // An integral number, also when written as 1.0 (both apps take it).
                Some(Value::Number(n)) => n
                    .as_i64()
                    .or_else(|| n.as_f64().filter(|f| f.fract() == 0.0 && f.abs() <= MAX_SAFE as f64).map(|f| f as i64))
                    .filter(|v| v.abs() <= MAX_SAFE)
                    .map(Some)
                    .ok_or("not an integer"),
                Some(_) => Err("wrong field type"),
            }
        };
        let kind = match o.get("kind") {
            Some(Value::String(k)) if !k.is_empty() && k.len() <= 64 => k.clone(),
            _ => return Err("bad kind"),
        };
        let session_id = match o.get("sessionId") {
            Some(Value::String(s)) if s.len() <= 128 => s.clone(),
            _ => return Err("bad sessionId"),
        };
        if session_id.is_empty() && kind != "pairing.cancel" {
            return Err("empty sessionId");
        }
        let reason = string("reason")?;
        if reason.as_ref().is_some_and(|r| r.len() > 32) {
            return Err("reason over 32 bytes");
        }
        Ok(Message {
            kind,
            session_id,
            device_id: string("deviceId")?,
            device_name: string("deviceName")?,
            public_key: string("publicKey")?,
            identity_key: string("identityKey")?,
            proof: string("proof")?,
            signature: string("signature")?,
            message_id: string("messageId")?,
            nonce: string("nonce")?,
            ciphertext: string("ciphertext")?,
            transfer_id: string("transferId")?,
            sequence: integer("sequence")?,
            target_device_id: string("targetDeviceId")?,
            commitment: string("commitment")?,
            protocol_version: integer("protocolVersion")?,
            tag: string("tag")?,
            reason,
        })
    }

    pub fn encode(&self) -> String {
        let mut o = Map::new();
        o.insert("kind".into(), Value::String(self.kind.clone()));
        o.insert("sessionId".into(), Value::String(self.session_id.clone()));
        let mut put = |name: &str, v: &Option<String>| {
            if let Some(v) = v.as_ref().filter(|v| !v.is_empty()) {
                o.insert(name.into(), Value::String(v.clone()));
            }
        };
        put("deviceId", &self.device_id);
        put("deviceName", &self.device_name);
        put("publicKey", &self.public_key);
        put("identityKey", &self.identity_key);
        put("proof", &self.proof);
        put("signature", &self.signature);
        put("messageId", &self.message_id);
        put("nonce", &self.nonce);
        put("ciphertext", &self.ciphertext);
        put("transferId", &self.transfer_id);
        put("targetDeviceId", &self.target_device_id);
        put("commitment", &self.commitment);
        put("tag", &self.tag);
        put("reason", &self.reason);
        if let Some(s) = self.sequence {
            o.insert("sequence".into(), Value::from(s));
        }
        if let Some(v) = self.protocol_version {
            o.insert("protocolVersion".into(), Value::from(v));
        }
        Value::Object(o).to_string()
    }

    fn tag_input(&self, sender: &str) -> Vec<u8> {
        let seq = self.sequence.map(|s| s.to_string());
        let pv = self.protocol_version.map(|v| v.to_string());
        length_prefixed(&[
            Some("bridgey-envelope-v2"),
            Some(sender),
            Some(&self.kind),
            Some(&self.session_id),
            self.device_id.as_deref(),
            self.device_name.as_deref(),
            self.public_key.as_deref(),
            self.identity_key.as_deref(),
            self.proof.as_deref(),
            self.signature.as_deref(),
            self.message_id.as_deref(),
            self.nonce.as_deref(),
            self.ciphertext.as_deref(),
            self.transfer_id.as_deref(),
            seq.as_deref(),
            self.target_device_id.as_deref(),
            self.commitment.as_deref(),
            pv.as_deref(),
            self.reason.as_deref(),
        ])
    }

    pub fn compute_tag(&self, envelope_key: &[u8; 32], sender: &str) -> String {
        b64(&hmac_sha256(envelope_key, &[&self.tag_input(sender)]))
    }

    pub fn tag_matches(&self, envelope_key: &[u8; 32], sender: &str) -> bool {
        let Some(received) = self.tag.as_deref().and_then(unb64) else { return false };
        let expected = hmac_sha256(envelope_key, &[&self.tag_input(sender)]);
        crate::crypto::ct_eq(&received, &expected)
    }
}

// MARK: reading a session's byte stream: JSON lines and binary frames (files_fast_draft1)

/// Bytes read ahead of the session loop. Above the largest window a fast sender keeps unacknowledged (32 MiB), so the
/// reader always drains the socket while the loop writes. It also bounds what a misbehaving peer can make this end hold.
pub const READ_BUDGET: usize = 48 * 1024 * 1024;
/// Frames read ahead of the session loop.
pub const READ_QUEUE: usize = 4096;

/// What the reader hands the session loop. Both the session client (session.rs) and the agent CLI read their streams
/// with [read_frames] in a task of its own, so a frame split across several reads is never lost when another branch
/// of the session's loop wins.
pub enum ReadFrame {
    /// One JSON frame, without its LF.
    Line(Vec<u8>),
    /// A binary frame (files_fast_draft1): its kind and body, the length already checked.
    Binary { kind: u8, body: Vec<u8> },
    End,
    Failed(&'static str),
}

/// Aborts the reader task when the session loop returns.
pub struct AbortOnDrop(pub tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Reads frames until the stream ends or a frame breaks the rules: JSON lines of at most 65,536 bytes, and binary
/// frames whose header declares 1 to 1,048,677 bytes (any other length closes: the stream can no longer be split).
/// Each frame takes its size from `budget` until the session loop has handled it.
pub async fn read_frames(mut reader: BufReader<OwnedReadHalf>, tx: mpsc::Sender<(ReadFrame, Option<tokio::sync::OwnedSemaphorePermit>)>, budget: Arc<tokio::sync::Semaphore>) {
    let mut line = Vec::with_capacity(4096);
    loop {
        let read = match read_frame(&mut reader, &mut line).await {
            Ok(Some(Frame::Line)) => ReadFrame::Line(std::mem::replace(&mut line, Vec::with_capacity(4096))),
            Ok(Some(Frame::Binary(kind, body))) => ReadFrame::Binary { kind, body },
            Ok(None) => ReadFrame::End,
            Err(reason) => ReadFrame::Failed(reason),
        };
        let size = match &read {
            ReadFrame::Line(l) => l.len(),
            ReadFrame::Binary { body, .. } => body.len(),
            _ => 0,
        };
        let last = matches!(read, ReadFrame::End | ReadFrame::Failed(_));
        let permit = budget.clone().acquire_many_owned(size.max(1) as u32).await.ok();
        if tx.send((read, permit)).await.is_err() || last {
            return;
        }
    }
}

enum Frame {
    Line,
    Binary(u8, Vec<u8>),
}

/// One frame. Ok(None) at the end of the stream.
async fn read_frame(reader: &mut BufReader<OwnedReadHalf>, line: &mut Vec<u8>) -> Result<Option<Frame>, &'static str> {
    line.clear();
    loop {
        let buf = match reader.fill_buf().await {
            Ok(buf) => buf,
            // Windows resets a connection the other end closed with data unread: between frames, that is the end.
            Err(e) if line.is_empty() && matches!(e.kind(), std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted) => return Ok(None),
            Err(_) => return Err("read_failed"),
        };
        if buf.is_empty() {
            return if line.is_empty() { Ok(None) } else { Err("truncated") };
        }
        if line.is_empty() && buf[0] == crate::fast::MARKER {
            let mut header = [0u8; crate::fast::HEADER];
            reader.read_exact(&mut header).await.map_err(|_| "truncated")?;
            let Some(len) = crate::fast::body_length(&header) else { return Err("bad_binary_length") };
            let mut body = vec![0u8; len];
            reader.read_exact(&mut body).await.map_err(|_| "truncated")?;
            return Ok(Some(Frame::Binary(header[1], body)));
        }
        match buf.iter().position(|b| *b == b'\n') {
            Some(i) => {
                line.extend_from_slice(&buf[..i]);
                reader.consume(i + 1);
                if line.len() > MAX_FRAME {
                    return Err("frame_too_large");
                }
                return Ok(Some(Frame::Line));
            }
            None => {
                let n = buf.len();
                line.extend_from_slice(buf);
                reader.consume(n);
                if line.len() > MAX_FRAME {
                    return Err("frame_too_large");
                }
            }
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn envelope_tag_vector() {
        let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/crypto-v1.properties")).unwrap();
        let p: HashMap<&str, &str> = text.lines().filter_map(|l| l.split_once('=')).collect();
        let key: [u8; 32] = unb64(p["expectedEnvelopeKey"]).unwrap().try_into().unwrap();
        let mut m = Message::new("clipboard.update", p["sessionId"]);
        m.message_id = Some(p["envelopeMessageId"].into());
        m.nonce = Some(p["aesNonce"].into());
        m.ciphertext = Some(p["aesCiphertext"].into());
        m.sequence = Some(7);
        assert_eq!(m.compute_tag(&key, p["deviceId"]), p["expectedEnvelopeTag"]);
        m.tag = Some(p["expectedEnvelopeTag"].into());
        assert!(m.tag_matches(&key, p["deviceId"]));
        assert!(!m.tag_matches(&key, "someone-else"));
    }

    #[test]
    fn golden_frames() {
        let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/protocol-v1.json")).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        let mut checked = 0;
        for f in v["frames"].as_array().unwrap() {
            let Some(line) = f["line"].as_str() else { continue };
            let got = Message::decode(line.as_bytes());
            if f["expect"] == "reject" {
                assert!(got.is_err(), "{} should be rejected", f["name"]);
            } else if let Some(exp) = f["expect"].as_object() {
                let m = got.unwrap_or_else(|e| panic!("{}: {e}", f["name"]));
                assert_eq!(Some(&Value::String(m.kind.clone())), exp.get("kind"), "{}", f["name"]);
                assert_eq!(exp.get("messageId").and_then(Value::as_str), m.message_id.as_deref(), "{}", f["name"]);
                checked += 1;
            }
        }
        assert!(checked > 10);
    }

    #[test]
    fn round_trip() {
        let mut m = Message::new("pairing.offer", "s");
        m.commitment = Some("c".into());
        m.protocol_version = Some(2);
        assert_eq!(Message::decode(m.encode().as_bytes()).unwrap(), m);
    }
}
