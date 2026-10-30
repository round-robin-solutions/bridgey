//! Sealed peer signalling (spec section 6.4).
//!
//! ```text
//! body = base64url( 0x01 || nonce(12) || AES-256-GCM(sigKey, nonce, plaintext, aad) )
//! aad  = "bridgey-signal-v1" \0 rdvId \0 side \0 sid      (side as the ASCII digit "0" or "1")
//! ```

use crate::b64;
use ring::aead;

pub const VERSION: u8 = 0x01;
pub const MAX_PLAINTEXT: usize = 4_096;

pub fn aad(rdv_id: &str, side: u8, sid: &str) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"bridgey-signal-v1\0");
    out.extend_from_slice(rdv_id.as_bytes());
    out.push(0);
    out.extend_from_slice(side.to_string().as_bytes());
    out.push(0);
    out.extend_from_slice(sid.as_bytes());
    out
}

pub fn seal_with_nonce(key: &[u8; 32], rdv_id: &str, side: u8, sid: &str, plaintext: &[u8], nonce: [u8; 12]) -> String {
    let key = aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, key).expect("key"));
    let mut in_out = plaintext.to_vec();
    key.seal_in_place_append_tag(aead::Nonce::assume_unique_for_key(nonce), aead::Aad::from(aad(rdv_id, side, sid)), &mut in_out)
        .expect("seal");
    let mut body = Vec::with_capacity(1 + 12 + in_out.len());
    body.push(VERSION);
    body.extend_from_slice(&nonce);
    body.extend_from_slice(&in_out);
    b64::url_encode(&body)
}

pub fn seal(key: &[u8; 32], rdv_id: &str, side: u8, sid: &str, plaintext: &[u8]) -> String {
    let mut nonce = [0u8; 12];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut nonce).expect("random");
    seal_with_nonce(key, rdv_id, side, sid, plaintext, nonce)
}

/// The plaintext, or `None` when the body is malformed, from another pair or tampered with.
pub fn open(key: &[u8; 32], rdv_id: &str, side: u8, sid: &str, body: &str) -> Option<Vec<u8>> {
    let raw = b64::url_decode(body)?;
    if raw.len() < 1 + 12 + 16 || raw[0] != VERSION || raw.len() > 1 + 12 + MAX_PLAINTEXT + 16 {
        return None;
    }
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&raw[1..13]);
    let key = aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, key).ok()?);
    let mut in_out = raw[13..].to_vec();
    let plain = key
        .open_in_place(aead::Nonce::assume_unique_for_key(nonce), aead::Aad::from(aad(rdv_id, side, sid)), &mut in_out)
        .ok()?;
    Some(plain.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_binding() {
        let key = [7u8; 32];
        let body = seal(&key, "rdv", 0, "sid", b"{\"t\":\"bye\"}");
        assert_eq!(open(&key, "rdv", 0, "sid", &body).unwrap(), b"{\"t\":\"bye\"}");
        assert!(open(&key, "rdv", 1, "sid", &body).is_none());
        assert!(open(&key, "other", 0, "sid", &body).is_none());
        assert!(open(&key, "rdv", 0, "sid2", &body).is_none());
        assert!(open(&[8u8; 32], "rdv", 0, "sid", &body).is_none());
        assert!(open(&key, "rdv", 0, "sid", "!!").is_none());
    }
}
