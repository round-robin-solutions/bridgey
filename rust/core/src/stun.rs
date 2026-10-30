//! A small STUN codec (RFC 8489) with the TURN (RFC 8656) and ICE (RFC 8445) attributes Bridgey uses.

use ring::hmac;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub const MAGIC: u32 = 0x2112_A442;
const FINGERPRINT_XOR: u32 = 0x5354_554e;

pub const REQUEST: u16 = 0x0000;
pub const INDICATION: u16 = 0x0010;
pub const SUCCESS: u16 = 0x0100;
pub const ERROR: u16 = 0x0110;

pub const BINDING: u16 = 0x001;
pub const ALLOCATE: u16 = 0x003;
pub const REFRESH: u16 = 0x004;
pub const SEND: u16 = 0x006;
pub const DATA: u16 = 0x007;
pub const CREATE_PERMISSION: u16 = 0x008;
pub const CHANNEL_BIND: u16 = 0x009;

pub const ATTR_USERNAME: u16 = 0x0006;
pub const ATTR_MESSAGE_INTEGRITY: u16 = 0x0008;
pub const ATTR_ERROR_CODE: u16 = 0x0009;
pub const ATTR_CHANNEL_NUMBER: u16 = 0x000C;
pub const ATTR_LIFETIME: u16 = 0x000D;
pub const ATTR_XOR_PEER_ADDRESS: u16 = 0x0012;
pub const ATTR_DATA: u16 = 0x0013;
pub const ATTR_REALM: u16 = 0x0014;
pub const ATTR_NONCE: u16 = 0x0015;
pub const ATTR_XOR_RELAYED_ADDRESS: u16 = 0x0016;
pub const ATTR_REQUESTED_TRANSPORT: u16 = 0x0019;
pub const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;
pub const ATTR_PRIORITY: u16 = 0x0024;
pub const ATTR_USE_CANDIDATE: u16 = 0x0025;
pub const ATTR_FINGERPRINT: u16 = 0x8028;
pub const ATTR_ICE_CONTROLLED: u16 = 0x8029;
pub const ATTR_ICE_CONTROLLING: u16 = 0x802A;

/// True when the first byte says STUN (RFC 9443: 0 to 3).
pub fn is_stun(packet: &[u8]) -> bool {
    packet.len() >= 20 && packet[0] < 4 && u32::from_be_bytes([packet[4], packet[5], packet[6], packet[7]]) == MAGIC
}

#[derive(Clone, Debug)]
pub struct Message {
    pub method: u16,
    pub class: u16,
    pub txid: [u8; 12],
    pub attrs: Vec<(u16, Vec<u8>)>,
    /// The bytes as received, for integrity checks.
    raw: Vec<u8>,
    /// Offset of MESSAGE-INTEGRITY in `raw`, when present.
    integrity_at: Option<usize>,
}

impl Message {
    pub fn new(method: u16, class: u16, txid: [u8; 12]) -> Self {
        Message { method, class, txid, attrs: Vec::new(), raw: Vec::new(), integrity_at: None }
    }

    pub fn request(method: u16) -> Self {
        Self::new(method, REQUEST, random_txid())
    }

    pub fn add(&mut self, kind: u16, value: Vec<u8>) -> &mut Self {
        self.attrs.push((kind, value));
        self
    }

    pub fn get(&self, kind: u16) -> Option<&[u8]> {
        self.attrs.iter().find(|(k, _)| *k == kind).map(|(_, v)| v.as_slice())
    }

    pub fn has(&self, kind: u16) -> bool {
        self.get(kind).is_some()
    }

    pub fn string(&self, kind: u16) -> Option<String> {
        self.get(kind).and_then(|v| String::from_utf8(v.to_vec()).ok())
    }

    pub fn u32(&self, kind: u16) -> Option<u32> {
        self.get(kind).filter(|v| v.len() >= 4).map(|v| u32::from_be_bytes([v[0], v[1], v[2], v[3]]))
    }

    pub fn xor_address(&self, kind: u16) -> Option<SocketAddr> {
        decode_xor_address(self.get(kind)?, &self.txid)
    }

    /// The error code (for example 401), when this is an error response.
    pub fn error_code(&self) -> Option<u16> {
        let v = self.get(ATTR_ERROR_CODE)?;
        (v.len() >= 4).then(|| u16::from(v[2] & 0x7) * 100 + u16::from(v[3]))
    }

    fn header(&self, length: usize) -> Vec<u8> {
        let mut out = Vec::with_capacity(20 + length);
        let kind = (self.method & 0x000F) | ((self.method & 0x0070) << 1) | ((self.method & 0x0F80) << 2) | self.class;
        out.extend_from_slice(&kind.to_be_bytes());
        out.extend_from_slice(&(length as u16).to_be_bytes());
        out.extend_from_slice(&MAGIC.to_be_bytes());
        out.extend_from_slice(&self.txid);
        out
    }

    /// Encodes the message, then MESSAGE-INTEGRITY (HMAC-SHA1 under `key`) and FINGERPRINT.
    pub fn encode(&self, key: Option<&[u8]>, fingerprint: bool) -> Vec<u8> {
        let mut body = Vec::new();
        for (kind, value) in &self.attrs {
            push_attr(&mut body, *kind, value);
        }
        let mut length = body.len();
        if key.is_some() {
            length += 24;
        }
        if fingerprint {
            length += 8;
        }
        let mut out = self.header(length);
        out.extend_from_slice(&body);
        if let Some(key) = key {
            // The length already counts MESSAGE-INTEGRITY (and FINGERPRINT); RFC 8489 section 14.5
            // says the HMAC covers the header with the length up to and including MESSAGE-INTEGRITY.
            let mut covered = out.clone();
            let mi_len = (covered.len() - 20 + 24) as u16;
            covered[2..4].copy_from_slice(&mi_len.to_be_bytes());
            let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, key), &covered);
            push_attr(&mut out, ATTR_MESSAGE_INTEGRITY, tag.as_ref());
        }
        if fingerprint {
            let crc = crc32fast::hash(&out) ^ FINGERPRINT_XOR;
            push_attr(&mut out, ATTR_FINGERPRINT, &crc.to_be_bytes());
        }
        out
    }

    pub fn decode(packet: &[u8]) -> Option<Message> {
        if !is_stun(packet) {
            return None;
        }
        let kind = u16::from_be_bytes([packet[0], packet[1]]);
        let length = u16::from_be_bytes([packet[2], packet[3]]) as usize;
        if !length.is_multiple_of(4) || 20 + length != packet.len() {
            return None;
        }
        let class = kind & 0x0110;
        let method = (kind & 0x000F) | ((kind & 0x00E0) >> 1) | ((kind & 0x3E00) >> 2);
        let mut txid = [0u8; 12];
        txid.copy_from_slice(&packet[8..20]);
        let mut attrs = Vec::new();
        let mut integrity_at = None;
        let mut at = 20;
        while at + 4 <= packet.len() {
            let attr = u16::from_be_bytes([packet[at], packet[at + 1]]);
            let len = u16::from_be_bytes([packet[at + 2], packet[at + 3]]) as usize;
            let end = at + 4 + len;
            if end > packet.len() {
                return None;
            }
            if attr == ATTR_MESSAGE_INTEGRITY {
                integrity_at = Some(at);
            }
            if integrity_at.is_none() || attr == ATTR_MESSAGE_INTEGRITY || attr == ATTR_FINGERPRINT {
                attrs.push((attr, packet[at + 4..end].to_vec()));
            }
            at = end + (4 - len % 4) % 4;
        }
        Some(Message { method, class, txid, attrs, raw: packet.to_vec(), integrity_at })
    }

    /// Checks MESSAGE-INTEGRITY under `key`.
    pub fn verify(&self, key: &[u8]) -> bool {
        let Some(at) = self.integrity_at else { return false };
        let Some(tag) = self.get(ATTR_MESSAGE_INTEGRITY) else { return false };
        let mut covered = self.raw[..at].to_vec();
        let mi_len = (at - 20 + 24) as u16;
        covered[2..4].copy_from_slice(&mi_len.to_be_bytes());
        hmac::verify(&hmac::Key::new(hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, key), &covered, tag).is_ok()
    }
}

fn push_attr(out: &mut Vec<u8>, kind: u16, value: &[u8]) {
    out.extend_from_slice(&kind.to_be_bytes());
    out.extend_from_slice(&(value.len() as u16).to_be_bytes());
    out.extend_from_slice(value);
    out.resize(out.len() + (4 - value.len() % 4) % 4, 0);
}

pub fn random_txid() -> [u8; 12] {
    let mut txid = [0u8; 12];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut txid).expect("random");
    txid
}

pub fn encode_xor_address(addr: SocketAddr, txid: &[u8; 12]) -> Vec<u8> {
    let addr = crate::addrs::canonical(addr);
    let port = addr.port() ^ (MAGIC >> 16) as u16;
    let mut out = vec![0u8];
    match addr.ip() {
        IpAddr::V4(ip) => {
            out.push(1);
            out.extend_from_slice(&port.to_be_bytes());
            let x = u32::from(ip) ^ MAGIC;
            out.extend_from_slice(&x.to_be_bytes());
        }
        IpAddr::V6(ip) => {
            out.push(2);
            out.extend_from_slice(&port.to_be_bytes());
            let mut key = MAGIC.to_be_bytes().to_vec();
            key.extend_from_slice(txid);
            out.extend(ip.octets().iter().zip(key.iter()).map(|(a, b)| a ^ b));
        }
    }
    out
}

pub fn decode_xor_address(v: &[u8], txid: &[u8; 12]) -> Option<SocketAddr> {
    if v.len() < 8 {
        return None;
    }
    let port = u16::from_be_bytes([v[2], v[3]]) ^ (MAGIC >> 16) as u16;
    match v[1] {
        1 => {
            let x = u32::from_be_bytes([v[4], v[5], v[6], v[7]]) ^ MAGIC;
            Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(x)), port))
        }
        2 if v.len() >= 20 => {
            let mut key = MAGIC.to_be_bytes().to_vec();
            key.extend_from_slice(txid);
            let mut octets = [0u8; 16];
            for (i, octet) in octets.iter_mut().enumerate() {
                *octet = v[4 + i] ^ key[i];
            }
            Some(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(octets)), port))
        }
        _ => None,
    }
}

/// TURN long-term credential key: MD5(username ":" realm ":" password).
pub fn long_term_key(username: &str, realm: &str, password: &str) -> Vec<u8> {
    use md5::{Digest, Md5};
    Md5::digest(format!("{username}:{realm}:{password}").as_bytes()).to_vec()
}

/// TURN ChannelData: channel numbers 0x4000 to 0x4FFF, first byte 64 to 79 (RFC 9443).
pub fn is_channel_data(packet: &[u8]) -> bool {
    packet.len() >= 4 && (0x40..=0x4F).contains(&packet[0])
}

pub fn channel_data(channel: u16, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + payload.len() + 3);
    out.extend_from_slice(&channel.to_be_bytes());
    out.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// The channel and payload of a ChannelData message.
pub fn parse_channel_data(packet: &[u8]) -> Option<(u16, &[u8])> {
    if !is_channel_data(packet) {
        return None;
    }
    let channel = u16::from_be_bytes([packet[0], packet[1]]);
    let len = u16::from_be_bytes([packet[2], packet[3]]) as usize;
    packet.get(4..4 + len).map(|payload| (channel, payload))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_with_integrity() {
        let mut m = Message::request(BINDING);
        m.add(ATTR_USERNAME, b"abcd:efgh".to_vec()).add(ATTR_PRIORITY, 7u32.to_be_bytes().to_vec());
        let bytes = m.encode(Some(b"password"), true);
        let back = Message::decode(&bytes).unwrap();
        assert_eq!(back.method, BINDING);
        assert_eq!(back.class, REQUEST);
        assert_eq!(back.string(ATTR_USERNAME).unwrap(), "abcd:efgh");
        assert_eq!(back.u32(ATTR_PRIORITY), Some(7));
        assert!(back.verify(b"password"));
        assert!(!back.verify(b"other"));
    }

    #[test]
    fn method_class_bits() {
        let m = Message::new(CHANNEL_BIND, ERROR, [0; 12]);
        let back = Message::decode(&m.encode(None, false)).unwrap();
        assert_eq!((back.method, back.class), (CHANNEL_BIND, ERROR));
        let m = Message::new(DATA, INDICATION, [0; 12]);
        let back = Message::decode(&m.encode(None, false)).unwrap();
        assert_eq!((back.method, back.class), (DATA, INDICATION));
    }

    #[test]
    fn xor_addresses() {
        let txid = random_txid();
        for addr in ["192.0.2.1:3478", "[2001:db8::1]:42458"] {
            let addr: SocketAddr = addr.parse().unwrap();
            assert_eq!(decode_xor_address(&encode_xor_address(addr, &txid), &txid), Some(addr));
        }
    }

    // RFC 5769 section 2.1 sample request (short-term credential "VOkJxbRl1RmTxUk/WvJxBt").
    #[test]
    fn rfc5769_sample_request() {
        let hex = "000100582112a442b7e7a701bc34d686fa87dfae802200105354554e207465737420636c69656e74002400046e0001ff80290008932ff9b151263b36000600096576746a3a68367659202020000800149aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a280280004e57a3bcf";
        let bytes: Vec<u8> = (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap()).collect();
        let m = Message::decode(&bytes).unwrap();
        assert!(m.verify(b"VOkJxbRl1RmTxUk/WvJxBt"));
        assert_eq!(m.string(ATTR_USERNAME).unwrap(), "evtj:h6vY");
    }

    #[test]
    fn channel_data_round_trip() {
        let packet = channel_data(0x4001, b"hello");
        assert!(is_channel_data(&packet));
        assert_eq!(parse_channel_data(&packet), Some((0x4001, &b"hello"[..])));
    }
}
