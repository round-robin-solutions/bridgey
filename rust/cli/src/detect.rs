//! Detect codes (docs/mesh-and-codes.md): this install reads one-time codes for the phone when no Mac is reading,
//! with the same model, prompt and guard as the Mac (the `bridgey-codes` crate).
//!
//! - The model: `bridgey codes model download --accept-terms` fetches the same pinned file the Mac downloads (the
//!   manifest on the fork's `models` release, SHA-256 checked) into `state/models/` (0700). Nothing runs without it.
//! - The phone sends `codes.candidate` (a text message that passed its gate) only while it granted Detect codes;
//!   the daemon reads it on the model's own thread and answers `codes.detected` with the code or `none`.
//! - Message text and codes stay in memory for the read only: never logged, never written. The audit entry says
//!   which phone, which app and the outcome.
//!
//! Builds without the `detect` feature carry no model runner: they never advertise `codes_detect_draft1`.

use crate::errors::CliError;
use crate::paths::{private_dir, write_private, Paths};
use crate::time::now_ms;
use serde_json::{json, Value};
use std::path::PathBuf;

/// Edition setting OTP_MODEL_MANIFEST_URL (rr-edition.properties), as the Mac uses it.
pub const MANIFEST_URL: &str = "https://github.com/round-robin-solutions/bridgey/releases/download/models/otp-model.json";
/// Every model file comes from the fork's `models` release, over HTTPS.
pub const ASSET_PREFIX: &str = "https://github.com/round-robin-solutions/bridgey/releases/download/models/";
/// The manifest this build was made with (the Mac bundles the same one); a newer `version` online wins.
const BUNDLED_MANIFEST: &str = r#"{"schema":1,"version":1,"name":"Gemma 3 270M, fine-tuned for codes (Q4_K_M)","url":"https://github.com/round-robin-solutions/bridgey/releases/download/models/bridgey-otp-v1.gguf","size":253115744,"sha256":"69fe14b205ecaebbd1fa5d167f48a25c687b493341ff92476ca163a2ea12390f","termsVersion":"gemma-2026-04-01+pup-2024-02-21+bridgey-1","licenceURL":"https://ai.google.dev/gemma/terms","prohibitedUseURL":"https://ai.google.dev/gemma/prohibited_use_policy"}"#;
const MAXIMUM_BYTES: u64 = 2_000_000_000;

/// How long one candidate may take on this install (the phone waits 30 seconds).
#[cfg(feature = "detect")]
const DETECT_BUDGET: std::time::Duration = std::time::Duration::from_secs(10);

/// Whether this build carries the model runner.
pub const BUILT_WITH_DETECTOR: bool = cfg!(feature = "detect");

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Manifest {
    pub version: u64,
    pub name: String,
    pub url: String,
    pub size: u64,
    pub sha256: String,
    pub terms_version: String,
    pub licence_url: String,
    pub prohibited_use_url: String,
}

impl Manifest {
    /// `None` unless the manifest is well formed and its model comes from [`ASSET_PREFIX`] (the Mac's rule).
    pub fn parse(bytes: &[u8]) -> Option<Manifest> {
        if bytes.len() > 16_384 {
            return None;
        }
        let v: Value = serde_json::from_slice(bytes).ok()?;
        let s = |k: &str| v[k].as_str().map(str::to_string);
        let m = Manifest {
            version: v["version"].as_u64()?,
            name: s("name")?,
            url: s("url")?,
            size: v["size"].as_u64()?,
            sha256: s("sha256")?,
            terms_version: s("termsVersion")?,
            licence_url: s("licenceURL")?,
            prohibited_use_url: s("prohibitedUseURL")?,
        };
        let valid = v["schema"].as_u64() == Some(1)
            && m.version >= 1
            && !m.name.is_empty()
            && !m.terms_version.is_empty()
            && m.url.starts_with(ASSET_PREFIX)
            && !m.url[ASSET_PREFIX.len()..].contains(['/', '?', '#', '\\'])
            && m.size > 1_000_000
            && m.size <= MAXIMUM_BYTES
            && m.sha256.len() == 64
            && m.sha256.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
            && m.licence_url.starts_with("https://")
            && m.prohibited_use_url.starts_with("https://");
        valid.then_some(m)
    }

    pub fn file_name(&self) -> String {
        format!("bridgey-otp-v{}.gguf", self.version)
    }
}

pub fn bundled() -> Manifest {
    Manifest::parse(BUNDLED_MANIFEST.as_bytes()).expect("bundled manifest")
}

pub fn models_dir(paths: &Paths) -> PathBuf {
    paths.state.join("models")
}

/// The installed model file, when its record and the file agree (name and size). The hash was checked once, at
/// download.
pub fn installed(paths: &Paths) -> Option<(Value, PathBuf)> {
    let dir = models_dir(paths);
    let record: Value = serde_json::from_slice(&std::fs::read(dir.join("installed.json")).ok()?).ok()?;
    let name = record["fileName"].as_str()?;
    if name.contains('/') || !name.starts_with("bridgey-otp-v") || !name.ends_with(".gguf") {
        return None;
    }
    let file = dir.join(name);
    let size = std::fs::metadata(&file).ok()?.len();
    (Some(size) == record["size"].as_u64()).then_some((record, file))
}

/// Whether this install can detect codes now: built with the runner and a model in place.
pub fn available(paths: &Paths) -> bool {
    BUILT_WITH_DETECTOR && installed(paths).is_some()
}

pub fn status(paths: &Paths) -> Value {
    let installed = installed(paths).map(|(r, _)| r);
    json!({
        "built": BUILT_WITH_DETECTOR,
        "installed": installed,
        "available": BUILT_WITH_DETECTOR && installed.is_some(),
        "manifest": manifest_json(&bundled()),
    })
}

fn manifest_json(m: &Manifest) -> Value {
    json!({"version": m.version, "name": m.name, "size": m.size, "sha256": m.sha256, "termsVersion": m.terms_version, "licenceURL": m.licence_url, "prohibitedUseURL": m.prohibited_use_url})
}

fn curl(args: &[&str]) -> Result<Vec<u8>, CliError> {
    let out = std::process::Command::new("curl")
        .args(["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--retry", "2"])
        .args(args)
        .output()
        .map_err(|e| CliError::new("failed", format!("curl is needed to download the model: {e}")))?;
    if !out.status.success() {
        return Err(CliError::new("failed", format!("download failed: {}", String::from_utf8_lossy(&out.stderr).trim())));
    }
    Ok(out.stdout)
}

/// The newest of the bundled manifest and the one online (the Mac's rule); the bundled one when offline.
pub fn current_manifest() -> Manifest {
    let online = curl(&["--max-filesize", "16384", "--max-time", "20", MANIFEST_URL]).ok().and_then(|b| Manifest::parse(&b));
    match online {
        Some(m) if m.version > bundled().version => m,
        _ => bundled(),
    }
}

fn sha256_file(path: &std::path::Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        ctx.update(&buf[..n]);
    }
    Ok(ctx.finish().as_ref().iter().map(|b| format!("{b:02x}")).collect())
}

/// Downloads the model after the terms were accepted. Resumes a partial file; checks the SHA-256 before the file
/// is used. Returns the installed record.
pub fn download(paths: &Paths, accept_terms: bool) -> Result<Value, CliError> {
    let manifest = current_manifest();
    if !accept_terms {
        return Err(CliError::new(
            "usage",
            format!(
                "The code model is {} ({} MB). Using it means accepting the Gemma Terms of Use ({}) and the Gemma Prohibited Use Policy ({}). Run again with --accept-terms to download it.",
                manifest.name,
                manifest.size / 1_000_000,
                manifest.licence_url,
                manifest.prohibited_use_url
            ),
        ));
    }
    paths.ensure().map_err(|e| CliError::new("failed", e.to_string()))?;
    let dir = models_dir(paths);
    private_dir(&dir).map_err(|e| CliError::new("failed", e.to_string()))?;
    let accepted = json!({"acceptedAt": now_ms(), "modelVersion": manifest.version, "termsVersion": manifest.terms_version});
    write_private(&dir.join("acceptance.json"), accepted.to_string().as_bytes()).map_err(|e| CliError::new("failed", e.to_string()))?;
    let part = dir.join(format!("{}.part", manifest.file_name()));
    let part_text = part.to_string_lossy().to_string();
    let size_text = manifest.size.to_string();
    curl(&["--continue-at", "-", "--max-filesize", &size_text, "--output", &part_text, &manifest.url])?;
    let got = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
    if got != manifest.size {
        let _ = std::fs::remove_file(&part);
        return Err(CliError::new("failed", format!("the model download has {got} bytes, expected {}; try again", manifest.size)));
    }
    let hash = sha256_file(&part).map_err(|e| CliError::new("failed", e.to_string()))?;
    if hash != manifest.sha256 {
        let _ = std::fs::remove_file(&part);
        return Err(CliError::new("failed", "the model file does not match its SHA-256; it was deleted"));
    }
    let file = dir.join(manifest.file_name());
    std::fs::rename(&part, &file).map_err(|e| CliError::new("failed", e.to_string()))?;
    let _ = std::fs::set_permissions(&file, std::os::unix::fs::PermissionsExt::from_mode(0o600));
    let record = json!({"version": manifest.version, "name": manifest.name, "size": manifest.size, "sha256": manifest.sha256, "fileName": manifest.file_name(), "installedAt": now_ms()});
    write_private(&dir.join("installed.json"), record.to_string().as_bytes()).map_err(|e| CliError::new("failed", e.to_string()))?;
    // Older versions go.
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with("bridgey-otp-v") && name != manifest.file_name() {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
    Ok(record)
}

/// Removes the model and its records (the terms acceptance stays, with its date).
pub fn remove(paths: &Paths) -> Result<Value, CliError> {
    let dir = models_dir(paths);
    let mut removed = 0;
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if (name.starts_with("bridgey-otp-v") || name == "installed.json") && std::fs::remove_file(e.path()).is_ok() && name != "installed.json" {
                removed += 1;
            }
        }
    }
    Ok(json!({"removed": removed}))
}

// MARK: - Wire

/// A code candidate from the phone (`codes.candidate`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub id: String,
    pub source: String,
    pub app: String,
    pub sender: String,
    pub text: String,
    pub posted_at: u64,
}

const APPS: &[&str] = &["messages", "gmail", "outlook", "proton", "spark"];

/// `None` for anything outside the contract (the message is dropped).
pub fn decode_candidate(p: &Value) -> Option<Candidate> {
    if p["version"] != 1 {
        return None;
    }
    let id = p["candidateId"].as_str().filter(|i| crate::crypto::is_uuid(i))?.to_string();
    let source = p["source"].as_str().filter(|s| *s == "sms" || *s == "email")?.to_string();
    let app = p["app"].as_str().filter(|a| APPS.contains(a))?.to_string();
    if (source == "sms") != (app == "messages") {
        return None;
    }
    let sender = p["sender"].as_str().filter(|s| s.chars().count() <= 64)?.to_string();
    let text = p["text"].as_str().filter(|t| !t.is_empty() && t.encode_utf16().count() <= 600)?.to_string();
    let posted_at = p["postedAt"].as_u64()?;
    Some(Candidate { id, source, app, sender, text, posted_at })
}

/// `codes.detected` for one outcome. Only a found code carries the code; a failure carries its word.
pub fn detected_payload(candidate_id: &str, outcome: &bridgey_codes::Outcome) -> Value {
    match outcome {
        bridgey_codes::Outcome::Code(code) => json!({"version": 1, "candidateId": candidate_id, "outcome": "found", "code": code}),
        bridgey_codes::Outcome::NoCode => json!({"version": 1, "candidateId": candidate_id, "outcome": "none"}),
        bridgey_codes::Outcome::Fallback(reason) => json!({"version": 1, "candidateId": candidate_id, "outcome": "failed", "reason": reason.wire()}),
    }
}

/// The model on this install, loaded on the first candidate and unloaded after 15 idle minutes.
pub struct Detector {
    #[cfg(feature = "detect")]
    engine: bridgey_codes::engine::LocalEngine,
}

impl Detector {
    #[cfg_attr(not(feature = "detect"), allow(unused_variables))]
    pub fn new(paths: &Paths) -> Detector {
        #[cfg(feature = "detect")]
        {
            let paths = paths.clone();
            let engine = bridgey_codes::engine::LocalEngine::new(
                bridgey_codes::engine::DEFAULT_IDLE,
                Box::new(move || installed(&paths).map(|(_, file)| file)),
                Box::new(|| Box::new(bridgey_codes::llama::LlamaRunner::default())),
            );
            Detector { engine }
        }
        #[cfg(not(feature = "detect"))]
        Detector {}
    }

    /// Unloads the model before the daemon exits.
    pub fn shutdown(&self) {
        #[cfg(feature = "detect")]
        self.engine.shutdown();
    }

    /// One candidate through the shared reader (blocking; run it off the async threads).
    pub fn read(&self, candidate: &Candidate) -> bridgey_codes::Outcome {
        let channel = if candidate.source == "email" { bridgey_codes::Channel::Email } else { bridgey_codes::Channel::Sms };
        #[cfg(feature = "detect")]
        {
            // No banner waits on a server, so the read gets longer than the Mac's 2 seconds: a busy host still answers
            // well inside the phone's 30 second wait.
            let mut reader = bridgey_codes::Reader::new(&self.engine);
            reader.budget = DETECT_BUDGET;
            reader.read(&candidate.text, Some(&candidate.sender), channel)
        }
        #[cfg(not(feature = "detect"))]
        {
            let _ = channel;
            bridgey_codes::Outcome::Fallback(bridgey_codes::Failure::NotConfigured)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bundled_manifest_is_the_published_one() {
        let m = bundled();
        assert_eq!(m.version, 1);
        assert_eq!(m.size, 253_115_744);
        assert_eq!(m.file_name(), "bridgey-otp-v1.gguf");
    }

    #[test]
    fn a_manifest_from_elsewhere_is_refused() {
        let other = BUNDLED_MANIFEST.replace("round-robin-solutions/bridgey", "someone/else");
        assert!(Manifest::parse(other.as_bytes()).is_none());
        let nested = BUNDLED_MANIFEST.replace("models/bridgey-otp-v1.gguf", "models/../x/bridgey-otp-v1.gguf");
        assert!(Manifest::parse(nested.as_bytes()).is_none());
        let upper = BUNDLED_MANIFEST.replace("69fe14b2", "69FE14B2");
        assert!(Manifest::parse(upper.as_bytes()).is_none());
    }

    #[test]
    fn candidates_follow_the_agent_vectors() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../protocol/test-vectors/agent-v1.json");
        let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        for v in doc["codesCandidate"].as_array().unwrap() {
            let got = decode_candidate(&v["plaintext"]);
            if v["expect"] == "reject" {
                assert!(got.is_none(), "{}", v["name"]);
            } else {
                let c = got.unwrap_or_else(|| panic!("{}", v["name"]));
                let e = &v["expect"];
                assert_eq!(json!({"candidateId": c.id, "source": c.source, "app": c.app, "sender": c.sender, "text": c.text, "postedAt": c.posted_at}), *e, "{}", v["name"]);
            }
        }
    }

    #[test]
    fn detected_payloads_match_the_vectors() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../protocol/test-vectors/agent-v1.json");
        let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let by_name = |n: &str| doc["codesDetected"].as_array().unwrap().iter().find(|v| v["name"] == n).unwrap()["plaintext"].clone();
        let id = by_name("found")["candidateId"].as_str().unwrap().to_string();
        assert_eq!(detected_payload(&id, &bridgey_codes::Outcome::Code("482913".into())), by_name("found"));
        assert_eq!(detected_payload(&id, &bridgey_codes::Outcome::NoCode), by_name("none"));
        assert_eq!(detected_payload(&id, &bridgey_codes::Outcome::Fallback(bridgey_codes::Failure::ModelMissing)), by_name("failed with a reason"));
    }
}
