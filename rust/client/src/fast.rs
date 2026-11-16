//! Fast transfers (draft `files_fast_draft1`, docs/protocol.md "Fast transfers"): binary frames for file chunks, the
//! replay guard that stands in for the messageId window, and the sender's window of unacknowledged bytes. The same
//! rules as the apps' FastTransfer.kt and FastTransfer.swift, checked against protocol/test-vectors/files-fast-v1.json.

use crate::crypto::{length_prefixed, random};
use bridgey_connect_proto::derive::hmac_sha256;
use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM};
use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

/// The feature key: a capability, advertised whenever this client supports it.
pub const FEATURE: &str = "files_fast_draft1";
/// The first byte of a binary frame; it can never start a JSON frame or UTF-8 text.
pub const MARKER: u8 = 0xB1;
pub const HEADER: usize = 6;
pub const KIND_CHUNK: u8 = 1;
pub const KIND_SPEED: u8 = 2;
pub const MAX_PLAINTEXT: usize = 1_048_576;
pub const MAX_ID: usize = 64;
/// ID length, ID, sequence, nonce, the largest ciphertext and its tag.
pub const MAX_BODY: usize = 1 + MAX_ID + 8 + 12 + MAX_PLAINTEXT + 16;
/// What senders use; receivers take up to `MAX_PLAINTEXT`.
pub const CHUNK: usize = 256 * 1024;
pub const MAX_SEQUENCE: u64 = 9_007_199_254_740_991;
const LABEL: &str = "bridgey-fast-frame-v2";

/// HMAC-SHA-256(session key, `bridgey-fast-frame-key-v2`), kept apart from the session key.
pub fn frame_key(session_key: &[u8; 32]) -> [u8; 32] {
    hmac_sha256(session_key, &[b"bridgey-fast-frame-key-v2"])
}

fn aad(sender: &str, kind: u8, id: &str, sequence: u64) -> Vec<u8> {
    length_prefixed(&[Some(LABEL), Some(sender), Some(&kind.to_string()), Some(id), Some(&sequence.to_string())])
}

fn valid_id(id: &[u8]) -> bool {
    (1..=MAX_ID).contains(&id.len()) && id.iter().all(|b| (0x21..=0x7E).contains(b))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    pub kind: u8,
    pub id: String,
    pub sequence: u64,
    pub plaintext: Vec<u8>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    /// A field outside its rules: dropped and counted.
    Malformed,
    /// The tag does not verify (wrong key, sender, kind, ID, sequence or a changed byte): dropped and counted.
    Undecryptable,
}

/// One whole frame, header included, sent by `sender` (this device's ID). `nonce` is random unless a vector fixes it.
pub fn seal(kind: u8, id: &str, sequence: u64, plaintext: &[u8], key: &[u8; 32], sender: &str, nonce: Option<[u8; 12]>) -> Option<Vec<u8>> {
    if !valid_id(id.as_bytes()) || sequence > MAX_SEQUENCE || plaintext.is_empty() || plaintext.len() > MAX_PLAINTEXT {
        return None;
    }
    let nonce = nonce.unwrap_or_else(random::<12>);
    let mut sealed = plaintext.to_vec();
    let cipher = LessSafeKey::new(UnboundKey::new(&AES_256_GCM, key).ok()?);
    cipher.seal_in_place_append_tag(Nonce::assume_unique_for_key(nonce), Aad::from(aad(sender, kind, id, sequence)), &mut sealed).ok()?;
    let body = 1 + id.len() + 8 + 12 + sealed.len();
    let mut frame = Vec::with_capacity(HEADER + body);
    frame.push(MARKER);
    frame.push(kind);
    frame.extend_from_slice(&(body as u32).to_be_bytes());
    frame.push(id.len() as u8);
    frame.extend_from_slice(id.as_bytes());
    frame.extend_from_slice(&sequence.to_be_bytes());
    frame.extend_from_slice(&nonce);
    frame.extend_from_slice(&sealed);
    Some(frame)
}

/// The body length a header declares, or None when it is outside 1 to `MAX_BODY` (the session must close: the stream
/// can no longer be split into frames).
pub fn body_length(header: &[u8; HEADER]) -> Option<usize> {
    let len = u32::from_be_bytes([header[2], header[3], header[4], header[5]]) as usize;
    (header[0] == MARKER && (1..=MAX_BODY).contains(&len)).then_some(len)
}

/// Reads and decrypts a frame body (what follows the header) sent by `sender` (the other device's ID).
pub fn open_body(kind: u8, body: &[u8], key: &[u8; 32], sender: &str) -> Result<Frame, FrameError> {
    let id_len = *body.first().ok_or(FrameError::Malformed)? as usize;
    if body.len() > MAX_BODY || !(1..=MAX_ID).contains(&id_len) || body.len() < 1 + id_len + 8 + 12 + 16 + 1 {
        return Err(FrameError::Malformed);
    }
    let id = &body[1..1 + id_len];
    if !valid_id(id) {
        return Err(FrameError::Malformed);
    }
    let sequence = u64::from_be_bytes(body[1 + id_len..1 + id_len + 8].try_into().unwrap());
    if sequence > MAX_SEQUENCE {
        return Err(FrameError::Malformed);
    }
    let nonce_at = 1 + id_len + 8;
    let cipher_at = nonce_at + 12;
    if body.len() - 16 - cipher_at > MAX_PLAINTEXT {
        return Err(FrameError::Malformed);
    }
    let id = String::from_utf8(id.to_vec()).map_err(|_| FrameError::Malformed)?;
    let nonce: [u8; 12] = body[nonce_at..cipher_at].try_into().unwrap();
    let mut data = body[cipher_at..].to_vec();
    let cipher = LessSafeKey::new(UnboundKey::new(&AES_256_GCM, key).map_err(|_| FrameError::Undecryptable)?);
    let plain = cipher.open_in_place(Nonce::assume_unique_for_key(nonce), Aad::from(aad(sender, kind, &id, sequence)), &mut data).map_err(|_| FrameError::Undecryptable)?;
    let plaintext = plain.to_vec();
    Ok(Frame { kind, id, sequence, plaintext })
}

/// Binary frames skip the messageId window: per kind and ID the sequence must rise. The 256 most recently used IDs
/// are remembered, so a long transfer is never forgotten while short ones come and go.
#[derive(Default)]
pub struct ReplayGuard {
    highest: HashMap<(u8, String), u64>,
    /// Least recently used first.
    order: VecDeque<(u8, String)>,
}

impl ReplayGuard {
    const CAPACITY: usize = 256;

    pub fn accept(&mut self, kind: u8, id: &str, sequence: u64) -> bool {
        let key = (kind, id.to_string());
        if let Some(last) = self.highest.get(&key) {
            if sequence <= *last {
                return false;
            }
            if self.order.back() != Some(&key) {
                if let Some(i) = self.order.iter().position(|k| *k == key) {
                    self.order.remove(i);
                }
                self.order.push_back(key.clone());
            }
        } else {
            self.order.push_back(key.clone());
            if self.order.len() > Self::CAPACITY {
                if let Some(old) = self.order.pop_front() {
                    self.highest.remove(&old);
                }
            }
        }
        self.highest.insert(key, sequence);
        true
    }
}

/// Sender-side flow control for one transfer (TransferPacer in FastTransfer.swift). Legacy peers: at most 64 chunks
/// unacknowledged. Fast peers: a window of unacknowledged bytes that grows while acknowledgements come back quickly and
/// shrinks to 70% when their round trip climbs 40 ms over the lowest seen in 10 s, between 512 KiB and 32 MiB.
pub struct Pacer {
    pub fast: bool,
    pub chunk: usize,
    in_flight: VecDeque<(u64, usize, Instant)>,
    in_flight_bytes: u64,
    window: u64,
    minimum: u64,
    base: VecDeque<(Instant, Duration)>,
    last_decrease: Option<Instant>,
    window_limited: bool,
    /// An acknowledgement arrived for this transfer at least once (legacy receivers may never send one).
    pub acked_any: bool,
}

impl Pacer {
    pub const LEGACY_CHUNKS: usize = 64;
    pub const INITIAL: u64 = 2 * 1024 * 1024;
    pub const MAXIMUM: u64 = 32 * 1024 * 1024;
    const TARGET: Duration = Duration::from_millis(40);
    const BASE_MEMORY: Duration = Duration::from_secs(10);

    /// `initial`: where the window ended for the previous file to the same device, so a queue does not start over.
    pub fn new(fast: bool, chunk: usize, initial: Option<u64>) -> Pacer {
        let minimum = 2 * CHUNK as u64;
        let window = if fast { initial.unwrap_or(Self::INITIAL).clamp(minimum, Self::MAXIMUM) } else { Self::LEGACY_CHUNKS as u64 };
        Pacer { fast, chunk, in_flight: VecDeque::new(), in_flight_bytes: 0, window, minimum, base: VecDeque::new(), last_decrease: None, window_limited: false, acked_any: false }
    }

    pub fn window(&self) -> u64 {
        self.window
    }

    pub fn unacknowledged(&self) -> usize {
        self.in_flight.len()
    }

    /// One more chunk of `bytes` fits. With nothing in flight a chunk always fits.
    pub fn room(&mut self, bytes: usize) -> bool {
        if self.in_flight.is_empty() {
            return true;
        }
        if self.fast {
            let fits = self.in_flight_bytes + bytes as u64 <= self.window;
            if !fits {
                self.window_limited = true;
            }
            fits
        } else {
            self.in_flight.len() < Self::LEGACY_CHUNKS
        }
    }

    pub fn sent(&mut self, sequence: u64, bytes: usize, at: Instant) {
        self.in_flight.push_back((sequence, bytes, at));
        self.in_flight_bytes += bytes as u64;
    }

    /// A cumulative acknowledgement through `sequence`.
    pub fn acknowledged(&mut self, sequence: u64, at: Instant) {
        self.acked_any = true;
        let mut acked = 0usize;
        let mut newest = None;
        while let Some(&(seq, bytes, sent)) = self.in_flight.front() {
            if seq > sequence {
                break;
            }
            acked += bytes;
            newest = Some(sent);
            self.in_flight.pop_front();
        }
        self.in_flight_bytes -= acked as u64;
        if let Some(sent) = newest {
            self.sample(at.saturating_duration_since(sent), acked, at);
        }
    }

    fn sample(&mut self, rtt: Duration, acked: usize, at: Instant) {
        while self.base.front().is_some_and(|(t, _)| at.saturating_duration_since(*t) > Self::BASE_MEMORY) {
            self.base.pop_front();
        }
        self.base.push_back((at, rtt));
        while self.base.len() > 64 {
            self.base.pop_front();
        }
        if !self.fast {
            return;
        }
        let Some(base) = self.base.iter().map(|(_, r)| *r).min() else { return };
        let queueing = rtt.saturating_sub(base);
        if queueing > Self::TARGET {
            // At most one decrease per round trip, so one burst of late acknowledgements counts once.
            if self.last_decrease.is_none_or(|t| at.saturating_duration_since(t) >= rtt.max(Duration::from_millis(20))) {
                self.window = self.minimum.max((self.window as f64 * 0.7) as u64);
                self.last_decrease = Some(at);
            }
        } else if self.window_limited {
            let growth = if queueing < Self::TARGET / 2 { acked as u64 } else { acked as u64 * self.chunk as u64 / self.window.max(1) };
            self.window = Self::MAXIMUM.min(self.window + growth.max(1));
            self.window_limited = false;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::unb64;
    use serde_json::Value;

    fn vectors() -> Value {
        serde_json::from_str(&std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/files-fast-v1.json")).unwrap()).unwrap()
    }

    #[test]
    fn frame_key_vector() {
        let v = vectors();
        let session: [u8; 32] = unb64(v["frameKey"]["sessionKeyBase64"].as_str().unwrap()).unwrap().try_into().unwrap();
        assert_eq!(crate::crypto::b64(&frame_key(&session)), v["frameKey"]["frameKeyBase64"].as_str().unwrap());
    }

    /// Every frame in the shared vectors reads (and where marked, writes) exactly as both apps do.
    #[test]
    fn shared_frames() {
        let v = vectors();
        let key: [u8; 32] = unb64(v["keyBase64"].as_str().unwrap()).unwrap().try_into().unwrap();
        let (sender, receiver) = (v["senderDeviceId"].as_str().unwrap(), v["receiverDeviceId"].as_str().unwrap());
        let _ = receiver;
        let mut checked = 0;
        for f in v["fastFrame"].as_array().unwrap() {
            let name = f["name"].as_str().unwrap();
            let mut bytes = unb64(f["frameBase64"].as_str().unwrap()).unwrap();
            if let Some(pad) = f["zeroPadTo"].as_u64() {
                bytes.resize(pad as usize, 0);
            }
            let header: Option<[u8; HEADER]> = bytes.get(..HEADER).and_then(|h| h.try_into().ok());
            let outcome = header.and_then(|h| body_length(&h).map(|len| (h[1], len))).map(|(kind, len)| {
                if bytes.len() < HEADER + len {
                    return Err(FrameError::Malformed);
                }
                open_body(kind, &bytes[HEADER..HEADER + len], &key, sender)
            });
            match &f["expect"] {
                Value::String(s) if s == "reject" => assert!(!matches!(outcome, Some(Ok(_))), "{name} is rejected"),
                Value::String(s) if s == "skip" => {
                    let frame = outcome.unwrap().unwrap_or_else(|e| panic!("{name}: {e:?}"));
                    assert!(frame.kind != KIND_CHUNK && frame.kind != KIND_SPEED, "{name} is an unknown kind");
                }
                Value::Object(exp) => {
                    let frame = outcome.unwrap().unwrap_or_else(|e| panic!("{name}: {e:?}"));
                    assert_eq!(u64::from(frame.kind), exp["kind"].as_u64().unwrap(), "{name}");
                    assert_eq!(frame.id, exp["id"].as_str().unwrap(), "{name}");
                    assert_eq!(frame.sequence, exp["sequence"].as_u64().unwrap(), "{name}");
                    assert_eq!(frame.plaintext, unb64(exp["plaintextBase64"].as_str().unwrap()).unwrap(), "{name}");
                    if f["write"] == Value::Bool(true) {
                        let nonce: [u8; 12] = unb64(f["nonceBase64"].as_str().unwrap()).unwrap().try_into().unwrap();
                        let written = seal(frame.kind, &frame.id, frame.sequence, &frame.plaintext, &key, sender, Some(nonce)).unwrap();
                        assert_eq!(written, bytes, "{name} writes the same bytes");
                    }
                    checked += 1;
                }
                other => panic!("{name}: unexpected {other}"),
            }
        }
        assert!(checked >= 8);
    }

    #[test]
    fn replay_guard_rises_per_kind_and_id() {
        let mut g = ReplayGuard::default();
        assert!(g.accept(1, "a", 0));
        assert!(!g.accept(1, "a", 0));
        assert!(g.accept(1, "a", 1));
        assert!(g.accept(2, "a", 0), "another kind has its own sequence");
        for i in 0..300 {
            assert!(g.accept(1, &format!("t{i}"), 0));
        }
        assert!(g.accept(1, "a", 0), "the oldest IDs are forgotten after 256");
    }

    #[test]
    fn pacer_grows_while_fast_and_shrinks_on_queueing() {
        let t0 = Instant::now();
        let mut p = Pacer::new(true, CHUNK, None);
        assert_eq!(p.window(), Pacer::INITIAL);
        let mut seq = 0;
        while p.room(CHUNK) {
            p.sent(seq, CHUNK, t0);
            seq += 1;
        }
        assert_eq!(seq, 8, "2 MiB of 256 KiB chunks");
        p.acknowledged(seq - 1, t0 + Duration::from_millis(5));
        assert!(p.window() > Pacer::INITIAL, "fast acknowledgements grow the window");
        let grown = p.window();
        p.sent(seq, CHUNK, t0 + Duration::from_millis(10));
        p.acknowledged(seq, t0 + Duration::from_millis(200));
        assert!(p.window() < grown, "a round trip 40 ms over the base shrinks it");
        let mut legacy = Pacer::new(false, 24 * 1024, None);
        for s in 0..64 {
            assert!(legacy.room(24 * 1024));
            legacy.sent(s, 24 * 1024, t0);
        }
        assert!(!legacy.room(24 * 1024), "64 chunks unacknowledged at most");
    }
}
