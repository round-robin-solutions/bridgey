//! Key and identifier derivations (spec section 5.5).
//!
//! ```text
//! pairSecret = HKDF-SHA256(cLow || cHigh, salt "bridgey-pair-secret-v1", info idLow \0 idHigh, 32)
//! sigKey     = HKDF-SHA256(pairSecret, salt "", info "bridgey-signal-v1", 32)
//! rdvId(d)   = base64url(HMAC-SHA256(pairSecret, "bridgey-rdv-v1" || d)[0..16])
//! pairCheck  = base64url(HMAC-SHA256(pairSecret, "bridgey-pair-check-v1")[0..8])
//! nodeId     = base64url(SHA-256(node)[0..16])
//! ```

use crate::b64;
use ring::{digest, hkdf, hmac};

struct Len(usize);

impl hkdf::KeyType for Len {
    fn len(&self) -> usize {
        self.0
    }
}

/// RFC 5869 HKDF-SHA256. An empty salt is a block of zeros, as the RFC says.
pub fn hkdf_sha256(ikm: &[u8], salt: &[u8], info: &[u8], len: usize) -> Vec<u8> {
    let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, salt).extract(ikm);
    let info = [info];
    let okm = prk.expand(&info, Len(len)).expect("HKDF length");
    let mut out = vec![0u8; len];
    okm.fill(&mut out).expect("HKDF fill");
    out
}

pub fn hmac_sha256(key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    let key = hmac::Key::new(hmac::HMAC_SHA256, key);
    let mut ctx = hmac::Context::with_key(&key);
    for part in parts {
        ctx.update(part);
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(ctx.sign().as_ref());
    out
}

pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    out.copy_from_slice(digest::digest(&digest::SHA256, bytes).as_ref());
    out
}

/// The lower and higher device ID, in the apps' order (plain string comparison).
pub fn ordered<'a>(a: &'a str, b: &'a str) -> (&'a str, &'a str) {
    if a < b {
        (a, b)
    } else {
        (b, a)
    }
}

/// `side` is 0 for the lower device ID and 1 for the higher.
pub fn side(local_id: &str, remote_id: &str) -> u8 {
    if local_id < remote_id {
        0
    } else {
        1
    }
}

pub fn pair_secret(c_low: &[u8], c_high: &[u8], id_low: &str, id_high: &str) -> [u8; 32] {
    let mut ikm = Vec::with_capacity(c_low.len() + c_high.len());
    ikm.extend_from_slice(c_low);
    ikm.extend_from_slice(c_high);
    let mut info = Vec::new();
    info.extend_from_slice(id_low.as_bytes());
    info.push(0);
    info.extend_from_slice(id_high.as_bytes());
    let okm = hkdf_sha256(&ikm, b"bridgey-pair-secret-v1", &info, 32);
    let mut out = [0u8; 32];
    out.copy_from_slice(&okm);
    out
}

pub fn sig_key(pair_secret: &[u8]) -> [u8; 32] {
    let okm = hkdf_sha256(pair_secret, b"", b"bridgey-signal-v1", 32);
    let mut out = [0u8; 32];
    out.copy_from_slice(&okm);
    out
}

pub fn rdv_id(pair_secret: &[u8], date: &str) -> String {
    let mac = hmac_sha256(pair_secret, &[b"bridgey-rdv-v1", date.as_bytes()]);
    b64::url_encode(&mac[..16])
}

pub fn pair_check(pair_secret: &[u8]) -> String {
    let mac = hmac_sha256(pair_secret, &[b"bridgey-pair-check-v1"]);
    b64::url_encode(&mac[..8])
}

pub fn net_tag(pair_secret: &[u8], fingerprint: &[u8]) -> String {
    let mac = hmac_sha256(pair_secret, &[b"bridgey-net-v1", fingerprint]);
    b64::url_encode(&mac[..8])
}

pub fn node_id(node_public_key: &[u8]) -> String {
    b64::url_encode(&sha256(node_public_key)[..16])
}

/// What a node signs to authenticate: `"bridgey-rdv-auth-v1\0" || nonce || node`.
pub fn auth_message(nonce: &[u8], node_public_key: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(20 + nonce.len() + node_public_key.len());
    out.extend_from_slice(b"bridgey-rdv-auth-v1\0");
    out.extend_from_slice(nonce);
    out.extend_from_slice(node_public_key);
    out
}

/// Proof of work: `SHA-256("bridgey-pow-v1" || nonce || node || solution)` starts with `bits` zero bits.
pub fn pow_ok(nonce: &[u8], node_public_key: &[u8], solution: &[u8], bits: u32) -> bool {
    if bits == 0 {
        return true;
    }
    let mut ctx = digest::Context::new(&digest::SHA256);
    ctx.update(b"bridgey-pow-v1");
    ctx.update(nonce);
    ctx.update(node_public_key);
    ctx.update(solution);
    leading_zero_bits(ctx.finish().as_ref()) >= bits
}

/// Finds a proof-of-work solution (an 8-byte counter). Cost doubles per bit.
pub fn pow_solve(nonce: &[u8], node_public_key: &[u8], bits: u32) -> Vec<u8> {
    let mut counter: u64 = 0;
    loop {
        let solution = counter.to_be_bytes();
        if pow_ok(nonce, node_public_key, &solution, bits) {
            return solution.to_vec();
        }
        counter += 1;
    }
}

fn leading_zero_bits(bytes: &[u8]) -> u32 {
    let mut bits = 0;
    for byte in bytes {
        if *byte == 0 {
            bits += 8;
        } else {
            bits += byte.leading_zeros();
            break;
        }
    }
    bits
}

/// UTC calendar date `YYYY-MM-DD` for Unix milliseconds.
pub fn utc_date(unix_ms: u64) -> String {
    let days = (unix_ms / 86_400_000) as i64;
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}")
}

/// The rendezvous dates a device registers: today and yesterday, and from 23:00 UTC tomorrow too.
pub fn rdv_dates(unix_ms: u64) -> Vec<String> {
    let day = 86_400_000;
    let mut dates = vec![utc_date(unix_ms), utc_date(unix_ms.saturating_sub(day))];
    if unix_ms % day >= 23 * 3_600_000 {
        dates.push(utc_date(unix_ms + day));
    }
    dates
}

// Howard Hinnant's days-to-civil algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates() {
        assert_eq!(utc_date(0), "1970-01-01");
        assert_eq!(utc_date(1_761_400_000_000), "2025-10-25");
        // 2026-10-27 23:30 UTC registers tomorrow too.
        let late = 1_793_143_800_000;
        assert_eq!(utc_date(late), "2026-10-27");
        assert_eq!(rdv_dates(late), vec!["2026-10-27", "2026-10-26", "2026-10-28"]);
        assert_eq!(rdv_dates(late - 3_600_000).len(), 2);
    }

    #[test]
    fn sides() {
        assert_eq!(side("a", "b"), 0);
        assert_eq!(side("b", "a"), 1);
        assert_eq!(ordered("b", "a"), ("a", "b"));
    }

    #[test]
    fn pow() {
        let solution = pow_solve(b"nonce", b"node", 8);
        assert!(pow_ok(b"nonce", b"node", &solution, 8));
        assert!(pow_ok(b"nonce", b"node", b"anything", 0));
    }
}
