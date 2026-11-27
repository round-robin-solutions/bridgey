//! Self-update for desktop clients without a store (Windows and Linux), on the edition's Stable, Beta and Nightly feeds
//! (`<UPDATE_FEED_BASE_URL>/<channel>.json`, written by scripts/rr/rrrelease.py). Rahul's standard for direct
//! downloads: a trusted feed, then the download's size, SHA-256 and signature checked before anything is installed,
//! and the person confirms.
//!
//! A feed's `windows` entry: `version`, `build`, `minimumOsBuild`, and per architecture (`x64`, `arm64`) `url`,
//! `sha256` (hex), `size` and `edSignature`: Ed25519 over the zip, by the release key that signs the Mac's Sparkle
//! updates. The `linux` entry has the same fields per AppImage architecture (`x86_64`, `aarch64`), without
//! `minimumOsBuild`. Builds are UTC build times (YYDDDHHMM), so a higher build is newer on every channel; a channel
//! switch never goes back to an older build.

use ring::digest::{Context, SHA256};
use serde_json::{json, Value};
use std::io::Read;
use std::path::Path;

pub const SCHEMA: i64 = 1;
/// The largest update the feed may offer (rrrelease.py checks the same).
pub const MAX_SIZE: u64 = 150 * 1024 * 1024;

/// An update the feed offers this device.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Offer {
    pub version: String,
    pub build: u64,
    pub url: String,
    pub sha256: String,
    pub size: u64,
    pub signature: String,
    pub notes: String,
    pub notes_url: String,
}

impl Offer {
    pub fn to_json(&self) -> Value {
        json!({"version": self.version, "build": self.build, "url": self.url, "sha256": self.sha256, "size": self.size, "signature": self.signature, "notes": self.notes, "notesUrl": self.notes_url})
    }
}

/// The edition's version names: 1.0.0 (Stable), 1.0.0-beta.2 (Beta), 1.0.0-nightly.20261116 (Nightly).
pub fn matches_channel(version: &str, channel: &str) -> bool {
    let core = |s: &str| {
        let parts: Vec<&str> = s.split('.').collect();
        parts.len() == 3 && parts.iter().all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
    };
    match channel {
        "stable" => core(version),
        "beta" => version.split_once("-beta.").is_some_and(|(c, n)| core(c) && !n.is_empty() && n.chars().all(|x| x.is_ascii_digit())),
        "nightly" => version.split_once("-nightly.").is_some_and(|(c, d)| core(c) && d.len() == 8 && d.chars().all(|x| x.is_ascii_digit())),
        _ => false,
    }
}

/// What the feed offers this device, or None when it has nothing newer. Err when the feed is not one to trust
/// (wrong app or channel, an asset outside the release repository, malformed fields).
pub fn check(feed: &str, app_id: &str, channel: &str, arch: &str, current_build: u64, trusted_prefix: &str) -> Result<Option<Offer>, String> {
    check_platform(feed, "windows", app_id, channel, arch, current_build, trusted_prefix)
}

/// `check` for a platform's own entry: `windows` or `linux`.
pub fn check_platform(feed: &str, platform: &str, app_id: &str, channel: &str, arch: &str, current_build: u64, trusted_prefix: &str) -> Result<Option<Offer>, String> {
    let label = match platform {
        "windows" => "Windows",
        "linux" => "Linux",
        _ => return Err("unknown platform".into()),
    };
    let Ok(Value::Object(f)) = serde_json::from_str::<Value>(feed) else { return Err("the feed is not JSON".into()) };
    if f.get("schema").and_then(Value::as_i64) != Some(SCHEMA) {
        return Err("unsupported feed schema".into());
    }
    if f.get("app").and_then(Value::as_str) != Some(app_id) {
        return Err("the feed is for another app".into());
    }
    if f.get("channel").and_then(Value::as_str) != Some(channel) {
        return Err("the feed is for another channel".into());
    }
    if !trusted_prefix.starts_with("https://") && !trusted_prefix.starts_with("http://127.0.0.1:") {
        return Err("the trusted prefix must be HTTPS".into());
    }
    let Some(Value::Object(w)) = f.get(platform) else { return Ok(None) };
    let version = w.get("version").and_then(Value::as_str).unwrap_or("");
    if !matches_channel(version, channel) {
        return Err(format!("the {label} version {version:?} is not a {channel} version"));
    }
    let build = w.get("build").and_then(Value::as_u64).filter(|b| *b > 0).ok_or(format!("the {label} build is invalid"))?;
    if build <= current_build {
        return Ok(None);
    }
    let Some(Value::Object(asset)) = w.get(arch) else { return Ok(None) };
    let url = asset.get("url").and_then(Value::as_str).unwrap_or("");
    if !url.starts_with(trusted_prefix) {
        return Err("the download is outside the release repository".into());
    }
    let sha256 = asset.get("sha256").and_then(Value::as_str).unwrap_or("");
    if sha256.len() != 64 || !sha256.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)) {
        return Err("the download's SHA-256 is invalid".into());
    }
    let size = asset.get("size").and_then(Value::as_u64).filter(|s| *s > 0 && *s <= MAX_SIZE).ok_or("the download's size is invalid")?;
    let signature = asset.get("edSignature").and_then(Value::as_str).unwrap_or("");
    if crate::crypto::unb64(signature).is_none_or(|s| s.len() != 64) {
        return Err("the download's signature is invalid".into());
    }
    Ok(Some(Offer {
        version: version.into(),
        build,
        url: url.into(),
        sha256: sha256.into(),
        size,
        signature: signature.into(),
        notes: f.get("notes").and_then(Value::as_str).unwrap_or("").chars().take(4_000).collect(),
        notes_url: f.get("notesUrl").and_then(Value::as_str).filter(|u| u.starts_with("https://")).unwrap_or("").into(),
    }))
}

/// Checks a downloaded update before it is installed: its size, its SHA-256 (hex), and the Ed25519 signature over it by
/// the release key (`public_key`, standard base64 of the 32-byte key, as the Mac's SUPublicEDKey).
pub fn verify_file(path: &Path, sha256: &str, size: u64, signature: &str, public_key: &str) -> Result<(), &'static str> {
    let key = crate::crypto::unb64(public_key).filter(|k| k.len() == 32).ok_or("the release key is invalid")?;
    let sig = crate::crypto::unb64(signature).filter(|s| s.len() == 64).ok_or("the signature is invalid")?;
    let meta = std::fs::metadata(path).map_err(|_| "the download is missing")?;
    if meta.len() != size || size > MAX_SIZE {
        return Err("the download's size does not match the feed");
    }
    let bytes = {
        let mut file = std::fs::File::open(path).map_err(|_| "the download is missing")?;
        let mut data = Vec::with_capacity(size as usize);
        file.read_to_end(&mut data).map_err(|_| "the download could not be read")?;
        data
    };
    let mut ctx = Context::new(&SHA256);
    ctx.update(&bytes);
    let digest: String = ctx.finish().as_ref().iter().map(|b| format!("{b:02x}")).collect();
    if digest != sha256.to_ascii_lowercase() {
        return Err("the download's SHA-256 does not match the feed");
    }
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, &key).verify(&bytes, &sig).map_err(|_| "the download is not signed by the release key")
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    const PREFIX: &str = "https://github.com/round-robin-solutions/bridgey/releases/download/";

    fn key() -> Ed25519KeyPair {
        Ed25519KeyPair::from_seed_unchecked(&[7u8; 32]).unwrap()
    }

    fn feed(build: u64, sha: &str, size: u64, sig: &str) -> String {
        json!({
            "schema": 1, "app": "in.roundrobin.bridgey", "channel": "beta", "version": "1.1.0-beta.2", "build": build, "notes": "What's new", "notesUrl": "https://github.com/x",
            "windows": {"version": "1.1.0-beta.2", "build": build, "minimumOsBuild": 19041,
                "x64": {"url": format!("{PREFIX}v1.1.0-beta.2/Bridgey-RR-1.1.0-beta.2-windows-x64.zip"), "sha256": sha, "size": size, "edSignature": sig}},
        })
        .to_string()
    }

    #[test]
    fn offers_only_newer_trusted_builds_for_this_architecture() {
        let sig = crate::crypto::b64(&[1u8; 64]);
        let sha = "a".repeat(64);
        let offer = check(&feed(263201050, &sha, 1000, &sig), "in.roundrobin.bridgey", "beta", "x64", 263190000, PREFIX).unwrap().unwrap();
        assert_eq!((offer.version.as_str(), offer.build, offer.size), ("1.1.0-beta.2", 263201050, 1000));
        assert_eq!(check(&feed(263201050, &sha, 1000, &sig), "in.roundrobin.bridgey", "beta", "x64", 263201050, PREFIX).unwrap(), None, "not newer");
        assert_eq!(check(&feed(263201050, &sha, 1000, &sig), "in.roundrobin.bridgey", "beta", "arm64", 1, PREFIX).unwrap(), None, "no arm64 asset");
        assert!(check(&feed(263201050, &sha, 1000, &sig), "in.roundrobin.bridgey", "stable", "x64", 1, PREFIX).is_err(), "another channel's feed");
        assert!(check(&feed(263201050, &sha, 1000, &sig), "other.app", "beta", "x64", 1, PREFIX).is_err());
        assert!(check(&feed(263201050, &sha, 1000, &sig), "in.roundrobin.bridgey", "beta", "x64", 1, "https://evil.example/").is_err(), "outside the trusted prefix");
        assert!(check(&feed(263201050, "xyz", 1000, &sig), "in.roundrobin.bridgey", "beta", "x64", 1, PREFIX).is_err());
        assert!(check(&feed(263201050, &sha, MAX_SIZE + 1, &sig), "in.roundrobin.bridgey", "beta", "x64", 1, PREFIX).is_err());
        let no_windows = json!({"schema": 1, "app": "in.roundrobin.bridgey", "channel": "beta"}).to_string();
        assert_eq!(check(&no_windows, "in.roundrobin.bridgey", "beta", "x64", 1, PREFIX).unwrap(), None);
    }

    #[test]
    fn linux_reads_its_own_entry() {
        let sig = crate::crypto::b64(&[1u8; 64]);
        let sha = "b".repeat(64);
        let feed = json!({
            "schema": 1, "app": "in.roundrobin.bridgey", "channel": "beta",
            "windows": {"version": "1.1.0-beta.2", "build": 263201050, "minimumOsBuild": 19041,
                "x64": {"url": format!("{PREFIX}v1.1.0-beta.2/w.zip"), "sha256": "a".repeat(64), "size": 10, "edSignature": sig}},
            "linux": {"version": "1.1.0-beta.2", "build": 263201050,
                "x86_64": {"url": format!("{PREFIX}v1.1.0-beta.2/Bridgey-RR-1.1.0-beta.2-linux-x86_64.AppImage"), "sha256": sha, "size": 2000, "edSignature": sig}},
        })
        .to_string();
        let offer = check_platform(&feed, "linux", "in.roundrobin.bridgey", "beta", "x86_64", 1, PREFIX).unwrap().unwrap();
        assert!(offer.url.ends_with("linux-x86_64.AppImage"));
        assert_eq!(offer.size, 2000);
        assert_eq!(check_platform(&feed, "linux", "in.roundrobin.bridgey", "beta", "aarch64", 1, PREFIX).unwrap(), None, "no aarch64 AppImage");
        assert_eq!(check(&feed, "in.roundrobin.bridgey", "beta", "x64", 1, PREFIX).unwrap().unwrap().size, 10, "Windows is unchanged");
        let windows_only = json!({"schema": 1, "app": "in.roundrobin.bridgey", "channel": "beta"}).to_string();
        assert_eq!(check_platform(&windows_only, "linux", "in.roundrobin.bridgey", "beta", "x86_64", 1, PREFIX).unwrap(), None);
        assert!(check_platform(&feed, "macos", "in.roundrobin.bridgey", "beta", "x86_64", 1, PREFIX).is_err());
    }

    #[test]
    fn version_names_follow_the_channels() {
        assert!(matches_channel("1.0.0", "stable") && !matches_channel("1.0.0-beta.1", "stable"));
        assert!(matches_channel("1.1.0-beta.12", "beta") && !matches_channel("1.1.0-beta.", "beta"));
        assert!(matches_channel("1.1.0-nightly.20261116", "nightly") && !matches_channel("1.1.0-nightly.2026111", "nightly"));
    }

    #[test]
    fn a_download_is_checked_for_size_hash_and_signature() {
        let dir = std::env::temp_dir().join(format!("bridgey-update-{}", crate::crypto::uuid4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("update.zip");
        let data = b"PK\x03\x04 an update".to_vec();
        std::fs::write(&path, &data).unwrap();
        let sha: String = ring::digest::digest(&SHA256, &data).as_ref().iter().map(|b| format!("{b:02x}")).collect();
        let k = key();
        let public = crate::crypto::b64(k.public_key().as_ref());
        let sig = crate::crypto::b64(k.sign(&data).as_ref());
        assert_eq!(verify_file(&path, &sha, data.len() as u64, &sig, &public), Ok(()));
        assert!(verify_file(&path, &sha, data.len() as u64 + 1, &sig, &public).is_err(), "size");
        assert!(verify_file(&path, &"0".repeat(64), data.len() as u64, &sig, &public).is_err(), "hash");
        let other = crate::crypto::b64(Ed25519KeyPair::from_seed_unchecked(&[9u8; 32]).unwrap().public_key().as_ref());
        assert_eq!(verify_file(&path, &sha, data.len() as u64, &sig, &other), Err("the download is not signed by the release key"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
