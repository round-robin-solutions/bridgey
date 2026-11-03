//! Session cryptography, the same as the apps' (docs/protocol.md "Pairing flow", SECURITY.md, and
//! SessionSecurity.kt): ephemeral P-256 ECDH, HKDF-SHA-256 with the session ID, AES-GCM payloads, the
//! protocol 2 commitment, code and envelope tag, and P-256 identity signatures.

use base64::Engine;
use bridgey_connect_proto::derive::{hmac_sha256, sha256};
use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM};
use ring::agreement::{self, EphemeralPrivateKey, UnparsedPublicKey, ECDH_P256};
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{self, EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_ASN1, ECDSA_P256_SHA256_ASN1_SIGNING};

pub const PROTOCOL_VERSION: i64 = 2;

pub fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

pub fn unb64(text: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::STANDARD.decode(text).ok()
}

pub fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

pub fn unb64url(text: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(text.trim_end_matches('=')).ok()
}

pub fn random<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    SystemRandom::new().fill(&mut out).expect("system random");
    out
}

/// A random (version 4) UUID, lowercase.
pub fn uuid4() -> String {
    let mut b = random::<16>();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    format_uuid(&b)
}

/// A time-ordered (version 7) UUID: a retry after a reconnect never duplicates an ask (agent-cli.md 7).
pub fn uuid7() -> String {
    let ms = crate::time::now_ms();
    let mut b = random::<16>();
    b[..6].copy_from_slice(&ms.to_be_bytes()[2..]);
    b[6] = (b[6] & 0x0f) | 0x70;
    b[8] = (b[8] & 0x3f) | 0x80;
    format_uuid(&b)
}

fn format_uuid(b: &[u8; 16]) -> String {
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

pub fn is_uuid(text: &str) -> bool {
    let b = text.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => *c == b'-',
            _ => c.is_ascii_hexdigit(),
        })
}

/// Each field as a 4-byte big-endian length and its UTF-8 bytes; an absent (or empty) field is 0xFFFFFFFF.
pub fn length_prefixed(fields: &[Option<&str>]) -> Vec<u8> {
    let mut out = Vec::new();
    for field in fields {
        match field.filter(|f| !f.is_empty()) {
            Some(f) => {
                out.extend_from_slice(&(f.len() as u32).to_be_bytes());
                out.extend_from_slice(f.as_bytes());
            }
            None => out.extend_from_slice(&[0xff; 4]),
        }
    }
    out
}

pub struct Ephemeral {
    private: Option<EphemeralPrivateKey>,
    /// Base64 of the 65-byte uncompressed point, as it travels.
    pub public: String,
}

impl Ephemeral {
    pub fn generate() -> Ephemeral {
        let private = EphemeralPrivateKey::generate(&ECDH_P256, &SystemRandom::new()).expect("ephemeral key");
        let public = b64(private.compute_public_key().expect("public key").as_ref());
        Ephemeral { private: Some(private), public }
    }

    /// The pairing material: (prk, session key). Consumes the private key (one agreement per session).
    pub fn agree(&mut self, remote_b64: &str, session_id: &str) -> Option<([u8; 32], [u8; 32])> {
        let remote = unb64(remote_b64).filter(|r| r.len() == 65 && r[0] == 4)?;
        let private = self.private.take()?;
        let shared = agreement::agree_ephemeral(private, &UnparsedPublicKey::new(&ECDH_P256, remote), |s| s.to_vec()).ok()?;
        Some(material(&shared, session_id))
    }
}

/// HKDF-SHA-256: salt SHA-256(session ID), info `bridgey-pairing-v1`, one block.
pub fn material(shared: &[u8], session_id: &str) -> ([u8; 32], [u8; 32]) {
    let prk = hmac_sha256(&sha256(session_id.as_bytes()), &[shared]);
    let key = hmac_sha256(&prk, &[b"bridgey-pairing-v1", &[1]]);
    (prk, key)
}

#[cfg(test)]
/// Protocol 1's code, from the session key (never shown by this command: it only reconnects with it).
pub fn code_v1(key: &[u8; 32]) -> String {
    let n = u32::from_be_bytes([key[0], key[1], key[2], key[3]]) % 1_000_000;
    format!("{n:06}")
}

/// Protocol 2's code: HKDF-Expand(prk, `bridgey-sas-v2` and both ephemeral keys), never session key bytes.
pub fn sas_code(prk: &[u8; 32], initiator_key: &str, responder_key: &str) -> String {
    let info = length_prefixed(&[Some("bridgey-sas-v2"), Some(initiator_key), Some(responder_key)]);
    let out = hmac_sha256(prk, &[&info, &[1]]);
    let n = u32::from_be_bytes([out[0], out[1], out[2], out[3]]) % 1_000_000;
    format!("{n:06}")
}

pub fn commitment(session_id: &str, public_key: &str) -> String {
    b64(&sha256(&length_prefixed(&[Some("bridgey-commit-v2"), Some(session_id), Some(public_key)])))
}

pub fn commitment_matches(commitment_b64: &str, session_id: &str, public_key: &str) -> bool {
    match (unb64(commitment_b64), unb64(&commitment(session_id, public_key))) {
        (Some(a), Some(b)) => ct_eq(&a, &b),
        _ => false,
    }
}

/// Constant-time comparison for MACs and commitments.
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn envelope_key(session_key: &[u8; 32]) -> [u8; 32] {
    hmac_sha256(session_key, &[b"bridgey-envelope-v2"])
}

pub fn confirmation_proof(key: &[u8; 32], session_id: &str, device_id: &str, identity_key: &str) -> String {
    let data = format!("bridgey-confirm-v1\0{session_id}\0{device_id}\0{identity_key}");
    b64(&hmac_sha256(key, &[data.as_bytes()]))
}

pub fn proof_matches(key: &[u8; 32], session_id: &str, device_id: &str, identity_key: &str, proof: &str) -> bool {
    match (unb64(proof), unb64(&confirmation_proof(key, session_id, device_id, identity_key))) {
        (Some(a), Some(b)) => ct_eq(&a, &b),
        _ => false,
    }
}

pub fn verify_signature(identity_key_b64: &str, data: &[u8], signature_b64: &str) -> bool {
    let (Some(key), Some(sig)) = (unb64(identity_key_b64), unb64(signature_b64)) else { return false };
    if key.len() != 65 || key[0] != 4 {
        return false;
    }
    signature::UnparsedPublicKey::new(&ECDSA_P256_SHA256_ASN1, key).verify(data, &sig).is_ok()
}

/// A P-256 signing key kept as PKCS#8 in a 0600 file (identity or node key).
pub struct SigningKey {
    pair: EcdsaKeyPair,
}

impl SigningKey {
    pub fn generate_pkcs8() -> Vec<u8> {
        EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &SystemRandom::new()).expect("key").as_ref().to_vec()
    }

    pub fn from_pkcs8(bytes: &[u8]) -> Option<SigningKey> {
        EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, bytes, &SystemRandom::new()).ok().map(|pair| SigningKey { pair })
    }

    pub fn public_raw(&self) -> Vec<u8> {
        self.pair.public_key().as_ref().to_vec()
    }

    /// DER ECDSA-P256-SHA256.
    pub fn sign(&self, data: &[u8]) -> Vec<u8> {
        self.pair.sign(&SystemRandom::new(), data).expect("sign").as_ref().to_vec()
    }
}

fn aead_key(key: &[u8; 32]) -> LessSafeKey {
    LessSafeKey::new(UnboundKey::new(&AES_256_GCM, key).expect("aes key"))
}

/// AES-256-GCM with a random nonce: (base64 nonce, base64 ciphertext and tag).
pub fn encrypt(key: &[u8; 32], plaintext: &[u8]) -> (String, String) {
    let nonce = random::<12>();
    let mut data = plaintext.to_vec();
    aead_key(key).seal_in_place_append_tag(Nonce::assume_unique_for_key(nonce), Aad::empty(), &mut data).expect("seal");
    (b64(&nonce), b64(&data))
}

pub fn decrypt(key: &[u8; 32], nonce_b64: &str, ciphertext_b64: &str) -> Option<Vec<u8>> {
    let nonce: [u8; 12] = unb64(nonce_b64)?.try_into().ok()?;
    let mut data = unb64(ciphertext_b64)?;
    let plain = aead_key(key).open_in_place(Nonce::assume_unique_for_key(nonce), Aad::empty(), &mut data).ok()?;
    Some(plain.to_vec())
}


#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn props() -> HashMap<String, String> {
        let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/crypto-v1.properties")).unwrap();
        text.lines().filter_map(|l| l.split_once('=')).map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    fn key32(text: &str) -> [u8; 32] {
        unb64(text).unwrap().try_into().unwrap()
    }

    #[test]
    fn shared_vectors() {
        let p = props();
        assert_eq!(commitment(&p["sessionId"], &p["publicKeyA"]), p["expectedCommitmentA"]);
        assert!(commitment_matches(&p["expectedCommitmentA"], &p["sessionId"], &p["publicKeyA"]));
        assert!(!commitment_matches(&p["expectedCommitmentA"], &p["sessionId"], &p["publicKeyB"]));
        let key = key32(&p["expectedKey"]);
        assert_eq!(code_v1(&key), p["expectedCode"]);
        assert_eq!(b64(&envelope_key(&key)), p["expectedEnvelopeKey"]);
        assert_eq!(confirmation_proof(&key, &p["sessionId"], &p["deviceId"], &p["identityKey"]), p["expectedConfirmationProof"]);
        let plain = decrypt(&key, &p["aesNonce"], &p["aesCiphertext"]).unwrap();
        assert_eq!(String::from_utf8(plain).unwrap(), p["aesPlaintext"]);
    }

    #[test]
    fn agreement_is_symmetric_and_round_trips() {
        let mut a = Ephemeral::generate();
        let mut b = Ephemeral::generate();
        let (pa, ka) = a.agree(&b.public.clone(), "s").unwrap();
        let (pb, kb) = b.agree(&a.public.clone(), "s").unwrap();
        assert_eq!(ka, kb);
        assert_eq!(sas_code(&pa, &a.public, &b.public), sas_code(&pb, &a.public, &b.public));
        let (n, c) = encrypt(&ka, b"hello");
        assert_eq!(decrypt(&kb, &n, &c).unwrap(), b"hello");
        assert!(a.agree(&b.public, "s").is_none(), "one agreement per key");
    }

    #[test]
    fn signatures_verify() {
        let key = SigningKey::from_pkcs8(&SigningKey::generate_pkcs8()).unwrap();
        let sig = key.sign(b"transcript");
        let public = b64(&key.public_raw());
        assert!(verify_signature(&public, b"transcript", &b64(&sig)));
        assert!(!verify_signature(&public, b"other", &b64(&sig)));
    }

    #[test]
    fn uuids() {
        assert!(is_uuid(&uuid4()));
        let v7 = uuid7();
        assert!(is_uuid(&v7));
        assert_eq!(&v7[14..15], "7");
        assert!(!is_uuid("x"));
    }
}
