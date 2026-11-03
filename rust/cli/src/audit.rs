//! This install's audit log (agent-cli.md section 9): `state/audit.jsonl`, 0600, rotated at 10 MB, 5 files.
//! An entry has the time, command, device, outcome, a hash of the arguments and the caller as far as it is
//! known. Never message text, clipboard content, codes, answers or file contents.

use crate::paths::Paths;
use serde_json::{json, Value};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;

const ROTATE_BYTES: u64 = 10 * 1024 * 1024;
const KEEP: usize = 5;

pub fn path(paths: &Paths) -> std::path::PathBuf {
    paths.state.join("audit.jsonl")
}

/// The caller, from the client process: parent process name, Unix user and `BRIDGEY_CALLER`.
pub fn caller() -> Value {
    let ppid = unsafe { libc::getppid() };
    let parent = std::fs::read_to_string(format!("/proc/{ppid}/comm")).ok().map(|s| s.trim().to_string()).or_else(|| {
        std::process::Command::new("ps").args(["-o", "comm=", "-p", &ppid.to_string()]).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().rsplit('/').next().unwrap_or("").to_string())
    });
    let user = std::env::var("USER").ok().or_else(|| std::env::var("LOGNAME").ok());
    let label = std::env::var("BRIDGEY_CALLER").ok().map(|c| c.chars().filter(|c| !c.is_control()).take(64).collect::<String>());
    json!({"parent": parent, "user": user, "uid": unsafe { libc::getuid() }, "label": label})
}

/// A short keyed hash of the arguments, so two runs of the same command can be told apart without keeping them.
/// The key (`state/audit.key`, 0600) stops anyone with the log alone from guessing short arguments. Clipboard
/// text, HTML and invite links are left out entirely.
pub fn args_hash(paths: &Paths, args: &Value) -> String {
    let mut a = args.clone();
    if let Some(o) = a.as_object_mut() {
        for k in ["text", "html", "join"] {
            if let Some(v) = o.remove(k) {
                o.insert(format!("{k}Bytes"), Value::from(v.as_str().map(str::len).unwrap_or(0)));
            }
        }
    }
    let key_path = paths.state.join("audit.key");
    let key = match std::fs::read(&key_path) {
        Ok(k) if k.len() == 32 => k,
        _ => {
            let k = crate::crypto::random::<32>().to_vec();
            let _ = crate::paths::write_private(&key_path, &k);
            k
        }
    };
    crate::crypto::b64url(&bridgey_connect_proto::derive::hmac_sha256(&key, &[a.to_string().as_bytes()])[..12])
}

pub fn record(paths: &Paths, entry: Value) {
    let file = path(paths);
    if std::fs::metadata(&file).map(|m| m.len() >= ROTATE_BYTES).unwrap_or(false) {
        for i in (1..KEEP).rev() {
            let from = if i == 1 { file.clone() } else { paths.state.join(format!("audit.jsonl.{}", i - 1)) };
            let _ = std::fs::rename(&from, paths.state.join(format!("audit.jsonl.{i}")));
        }
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(&file) {
        let _ = writeln!(f, "{entry}");
    }
}

/// Entries at or after `since_ms`, oldest first, from every rotated file.
pub fn read(paths: &Paths, since_ms: u64) -> Vec<Value> {
    let mut files: Vec<std::path::PathBuf> = (1..KEEP).rev().map(|i| paths.state.join(format!("audit.jsonl.{i}"))).collect();
    files.push(path(paths));
    let mut out = Vec::new();
    for f in files {
        let Ok(text) = std::fs::read_to_string(&f) else { continue };
        for line in text.lines() {
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                if v["at"].as_u64().unwrap_or(0) >= since_ms {
                    out.push(v);
                }
            }
        }
    }
    out
}
