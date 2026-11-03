//! Remote pairing invites (docs/protocol.md "agent devices"): `bridgey://pair#<base64url JSON>`.

use crate::crypto::{b64url, unb64url};
use bridgey_connect_proto::derive;
use serde_json::Value;

pub const LIFETIME_S: u64 = 600;

#[derive(Clone, Debug)]
pub struct Invite {
    pub secret: [u8; 32],
    pub control_url: String,
    pub name: String,
    pub expires_s: u64,
}

impl Invite {
    pub fn new(control_url: &str, name: &str, now_ms: u64) -> Invite {
        Invite { secret: crate::crypto::random::<32>(), control_url: control_url.into(), name: name.chars().take(64).collect(), expires_s: now_ms / 1000 + LIFETIME_S }
    }

    pub fn json(&self) -> String {
        // Keys in a fixed order (v, s, c, n, p, x), so the same invite always gives the same link.
        let s = |v: &str| Value::String(v.into()).to_string();
        format!("{{\"v\":1,\"s\":{},\"c\":{},\"n\":{},\"p\":\"cli\",\"x\":{}}}", s(&b64url(&self.secret)), s(&self.control_url), s(&self.name), self.expires_s)
    }

    pub fn link(&self) -> String {
        format!("bridgey://pair#{}", b64url(self.json().as_bytes()))
    }

    pub fn rdv(&self) -> String {
        derive::invite_rdv_id(&self.secret)
    }

    pub fn label(&self) -> String {
        format!("invite:{}", self.rdv())
    }

    pub fn hash(&self) -> String {
        derive::invite_hash(&self.secret)
    }

    /// Reads a link or bare fragment (the phone's side of the rules, for tests and `bridgey doctor`).
    pub fn parse(text: &str, now_ms: u64) -> Result<Invite, &'static str> {
        if text.len() > 1500 {
            return Err("too long");
        }
        let fragment = text.trim().strip_prefix("bridgey://pair#").unwrap_or(text.trim());
        let bytes = unb64url(fragment).ok_or("not base64url")?;
        if bytes.len() > 1024 {
            return Err("too long");
        }
        let v: Value = serde_json::from_slice(&bytes).map_err(|_| "not JSON")?;
        Self::from_json(&v, now_ms)
    }

    pub fn from_json(v: &Value, now_ms: u64) -> Result<Invite, &'static str> {
        if v["v"].as_i64() != Some(1) {
            return Err("version");
        }
        let secret: [u8; 32] = v["s"].as_str().and_then(unb64url).and_then(|s| s.try_into().ok()).ok_or("secret")?;
        let control_url = v["c"].as_str().filter(|c| !c.is_empty()).ok_or("control URL")?.to_string();
        let name = v["n"].as_str().ok_or("name")?.to_string();
        if name.chars().count() > 64 {
            return Err("name");
        }
        let expires_s = v["x"].as_u64().ok_or("expiry")?;
        let expires_ms = expires_s.saturating_mul(1000);
        if now_ms > 0 && (expires_ms < now_ms || expires_ms > now_ms + LIFETIME_S * 1000 + 60_000) {
            return Err("expired");
        }
        Ok(Invite { secret, control_url, name, expires_s })
    }
}

/// The QR code as Unicode half blocks (two rows per line), dark on light with a quiet zone, readable over SSH.
pub fn qr(text: &str) -> String {
    let Ok(code) = qrcode::QrCode::with_error_correction_level(text.as_bytes(), qrcode::EcLevel::L) else { return String::new() };
    let width = code.width();
    let colors = code.to_colors();
    let dark = |x: i32, y: i32| -> bool {
        if x < 0 || y < 0 || x >= width as i32 || y >= width as i32 {
            return false;
        }
        colors[y as usize * width + x as usize] == qrcode::Color::Dark
    };
    let quiet = 2;
    let mut out = String::new();
    let mut y = -quiet;
    while y < width as i32 + quiet {
        for x in -quiet..width as i32 + quiet {
            // Light modules are drawn, so the code reads on dark and light terminals alike.
            out.push(match (dark(x, y), dark(x, y + 1)) {
                (false, false) => '█',
                (false, true) => '▀',
                (true, false) => '▄',
                (true, true) => ' ',
            });
        }
        out.push('\n');
        y += 2;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vectors() -> Value {
        serde_json::from_str(&std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/agent-v1.json")).unwrap()).unwrap()
    }

    #[test]
    fn shared_invite_vectors() {
        let v = vectors();
        let i = &v["invite"];
        let secret: [u8; 32] = crate::crypto::unb64(i["secret"].as_str().unwrap()).unwrap().try_into().unwrap();
        let inv = Invite::parse(i["link"].as_str().unwrap(), 0).unwrap();
        assert_eq!(inv.secret, secret);
        assert_eq!(inv.json(), i["json"].as_str().unwrap());
        assert_eq!(inv.link(), i["link"].as_str().unwrap());
        assert_eq!(inv.rdv(), i["rdv"].as_str().unwrap());
        assert_eq!(inv.hash(), i["inviteHash"].as_str().unwrap());
        assert_eq!(crate::crypto::b64(&derive::invite_sig_key(&secret)), i["sigKey"].as_str().unwrap());
        for bad in i["invalid"].as_array().unwrap() {
            let parsed: Value = serde_json::from_str(bad["json"].as_str().unwrap()).unwrap();
            assert!(Invite::from_json(&parsed, 0).is_err(), "{}", bad["name"]);
        }
        let t = &i["transcript"];
        let text = ["bridgey-auth-v2", t["sessionId"].as_str().unwrap(), t["initiatorId"].as_str().unwrap(), t["responderId"].as_str().unwrap(), t["initiatorKey"].as_str().unwrap(), t["responderKey"].as_str().unwrap(), t["exporter"].as_str().unwrap(), &inv.hash()].join("\0");
        assert_eq!(crate::crypto::b64(text.as_bytes()), t["expected"].as_str().unwrap());
    }

    #[test]
    fn fresh_invites_expire() {
        let now = 1_800_000_000_000;
        let inv = Invite::new("wss://x/v1/ws", "Contabo Europe", now);
        assert!(Invite::parse(&inv.link(), now).is_ok());
        assert!(Invite::parse(&inv.link(), now + 601_000).is_err());
        assert!(!qr(&inv.link()).is_empty());
    }
}
