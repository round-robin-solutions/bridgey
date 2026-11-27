//! protocol/messages.json and this command agree, as the Android, Mac and rust/client contract tests check theirs:
//! every kind the code sends or handles is listed for `cli` with a direction that fits, nothing else is listed for
//! `cli`, and every feature key this command advertises is in the contract.

use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

const SOURCES: &[(&str, &str)] = &[
    ("audit.rs", include_str!("audit.rs")),
    ("client.rs", include_str!("client.rs")),
    ("config.rs", include_str!("config.rs")),
    ("crypto.rs", include_str!("crypto.rs")),
    ("daemon.rs", include_str!("daemon.rs")),
    ("detect.rs", include_str!("detect.rs")),
    ("doctor.rs", include_str!("doctor.rs")),
    ("errors.rs", include_str!("errors.rs")),
    ("files.rs", include_str!("files.rs")),
    ("invite.rs", include_str!("invite.rs")),
    ("ipc.rs", include_str!("ipc.rs")),
    ("main.rs", include_str!("main.rs")),
    ("notifications.rs", include_str!("notifications.rs")),
    ("ops.rs", include_str!("ops.rs")),
    ("paths.rs", include_str!("paths.rs")),
    ("payloads.rs", include_str!("payloads.rs")),
    ("service.rs", include_str!("service.rs")),
    ("session.rs", include_str!("session.rs")),
    ("store.rs", include_str!("store.rs")),
    ("tailnet.rs", include_str!("tailnet.rs")),
    ("time.rs", include_str!("time.rs")),
    ("wire.rs", include_str!("wire.rs")),
];

/// Literals shaped like a kind that are not message kinds: audit command names, the core's events and service names.
/// Files and settings keys are recognised on their own.
const NOT_KINDS: &[&str] = &["codes.detect", "files.receive", "connect.failed", "tunnel.closed", "in.roundrobin.bridgey.cli", "bridgey.service"];

/// Calls that put a kind on the wire.
const SENDS: &[&str] = &["send_json(", "send_json_id(", "send_raw_id(", "send_encrypted(", "send_outer(", "Message::new("];

/// Kinds this command reads although the contract has only agents sending them, and why.
const READ_AGAINST_DIRECTION: &[(&str, &str)] = &[
    // Another server paired over the tailnet introduces itself; candidates from it are refused (detect.rs).
    ("agent.hello", "a peer that says it is an agent never sends code candidates here"),
];

fn is_kind(s: &str) -> bool {
    let mut parts = s.split('.');
    let first = parts.next().unwrap_or("");
    let rest: Vec<&str> = parts.collect();
    first.starts_with(|c: char| c.is_ascii_lowercase())
        && first.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && !rest.is_empty()
        && rest.iter().all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'))
}

fn not_a_kind(s: &str) -> bool {
    const FILES: &[&str] = &[".json", ".jsonl", ".log", ".toml", ".p8", ".key", ".sock", ".lock"];
    NOT_KINDS.contains(&s) || FILES.iter().any(|f| s.ends_with(f)) || crate::config::KEYS.iter().any(|(k, _)| *k == s)
}

/// The code of a file without its test module.
fn code(text: &str) -> &str {
    text.split("\n#[cfg(test)]\nmod ").next().unwrap()
}

/// The string literals of Rust source, each with the byte offset where its text starts. Comments, char literals and
/// lifetimes are skipped, escapes and raw strings understood: enough for this crate's code.
fn literals(code: &str) -> Vec<(usize, &str)> {
    let b = code.as_bytes();
    let (mut i, mut out) = (0, Vec::new());
    while i < b.len() {
        match b[i] {
            b'/' if b.get(i + 1) == Some(&b'/') => i = code[i..].find('\n').map_or(b.len(), |n| i + n),
            b'/' if b.get(i + 1) == Some(&b'*') => i = code[i + 2..].find("*/").map_or(b.len(), |n| i + n + 4),
            b'r' if matches!(b.get(i + 1), Some(b'"' | b'#')) && (i == 0 || !(b[i - 1].is_ascii_alphanumeric() || b[i - 1] == b'_')) => {
                let hashes = b[i + 1..].iter().take_while(|c| **c == b'#').count();
                if b.get(i + 1 + hashes) != Some(&b'"') {
                    i += 1;
                    continue;
                }
                let start = i + 2 + hashes;
                let close = format!("\"{}", "#".repeat(hashes));
                let end = code[start..].find(&close).map_or(b.len(), |n| start + n);
                out.push((start, &code[start..end]));
                i = end + close.len();
            }
            b'"' => {
                let start = i + 1;
                let mut j = start;
                while j < b.len() && b[j] != b'"' {
                    j += if b[j] == b'\\' { 2 } else { 1 };
                }
                out.push((start, &code[start..j.min(b.len())]));
                i = j + 1;
            }
            b'\'' => {
                // A char literal ('x', '\'', '"', '█') or a lifetime ('a, 'static).
                let close = if b.get(i + 1) == Some(&b'\\') { code[i + 3..].find('\'').map(|n| i + 3 + n) } else { code[i + 1..].char_indices().nth(1).filter(|(_, c)| *c == '\'').map(|(n, _)| i + 1 + n) };
                i = close.map_or(i + 1, |c| c + 1);
            }
            _ => i += 1,
        }
    }
    out
}

/// Kinds the sources send and handle, each with the first file that does.
fn scan() -> (BTreeMap<String, &'static str>, BTreeMap<String, &'static str>) {
    let (mut sent, mut handled) = (BTreeMap::new(), BTreeMap::new());
    for (file, text) in SOURCES {
        let code = code(text);
        for (start, literal) in literals(code) {
            if !is_kind(literal) || not_a_kind(literal) {
                continue;
            }
            let before = &code[..start - 1];
            let map = if SENDS.iter().any(|s| before.ends_with(s)) { &mut sent } else { &mut handled };
            map.entry(literal.to_string()).or_insert(*file);
        }
    }
    (sent, handled)
}

fn contract() -> Value {
    serde_json::from_str(include_str!("../../../protocol/messages.json")).unwrap()
}

#[test]
fn every_kind_this_command_uses_is_listed_for_cli() {
    let (sent, handled) = scan();
    let contract = contract();
    let listed: BTreeMap<String, &Value> = contract["messages"].as_array().unwrap().iter().map(|m| (m["kind"].as_str().unwrap().to_string(), m)).collect();
    let mut problems = Vec::new();
    let used: BTreeSet<&String> = sent.keys().chain(handled.keys()).collect();
    for kind in &used {
        let file = sent.get(*kind).or(handled.get(*kind)).unwrap();
        match listed.get(*kind) {
            None => problems.push(format!("{kind} (in {file}) is not in protocol/messages.json")),
            Some(m) if !m["implemented"].as_array().unwrap().iter().any(|p| p == "cli") => {
                problems.push(format!("{kind} (in {file}) is used but messages.json does not list cli"))
            }
            Some(m) => {
                let status = m["status"].as_str().unwrap();
                if status == "designed" || status == "retired" {
                    problems.push(format!("{kind} (in {file}) is {status} in messages.json"));
                }
            }
        }
    }
    for (kind, m) in &listed {
        if m["implemented"].as_array().unwrap().iter().any(|p| p == "cli") && !used.contains(kind) {
            problems.push(format!("messages.json lists {kind} for cli, but the sources never use it"));
        }
    }
    assert_eq!(problems, Vec::<String>::new(), "document new messages in docs/protocol.md and protocol/messages.json");
}

/// This command sends only what an agent may send, and reads only what is sent to one.
#[test]
fn directions_fit_an_agent() {
    let (sent, handled) = scan();
    let contract = contract();
    let direction = |kind: &str| -> String {
        contract["messages"].as_array().unwrap().iter().find(|m| m["kind"] == kind).map(|m| m["direction"].as_str().unwrap().to_string()).unwrap_or_default()
    };
    let mut problems = Vec::new();
    for (kind, file) in &sent {
        let d = direction(kind);
        if d != "either" && d != "agent-to-phone" {
            problems.push(format!("{file} sends {kind}, which messages.json has going {d}"));
        }
    }
    for (kind, file) in &handled {
        let d = direction(kind);
        if d != "either" && d != "phone-to-agent" && !READ_AGAINST_DIRECTION.iter().any(|(k, _)| k == kind) {
            problems.push(format!("{file} reads {kind}, which messages.json has going {d}"));
        }
    }
    for (kind, _) in READ_AGAINST_DIRECTION {
        assert!(handled.contains_key(*kind), "{kind} is no longer read; drop it from READ_AGAINST_DIRECTION");
    }
    assert_eq!(problems, Vec::<String>::new());
}

/// Every key in this command's features.update is in the contract, the five core keys are there, and every kind it
/// uses is gated by a key it advertises (or by none, for the session itself).
#[test]
fn advertised_keys_are_listed_and_gate_the_kinds() {
    let contract = contract();
    let features: BTreeMap<&str, &Value> = contract["features"].as_array().unwrap().iter().map(|f| (f["key"].as_str().unwrap(), f)).collect();
    let ours: BTreeSet<&str> = crate::daemon::OWN_FEATURES.iter().map(|(k, _)| *k).collect();
    for key in &ours {
        assert!(features.contains_key(key), "{key} is advertised but not in protocol/messages.json");
    }
    for (key, f) in &features {
        if f["requiredInMap"] == true {
            assert!(ours.contains(key), "every map carries {key}");
        }
    }
    let (sent, handled) = scan();
    for kind in sent.keys().chain(handled.keys()) {
        let m = contract["messages"].as_array().unwrap().iter().find(|m| m["kind"] == kind.as_str()).unwrap();
        let keys: Vec<&str> = m["feature"].as_str().map(|f| f.split(" | ").collect()).unwrap_or_default();
        assert!(keys.is_empty() || keys.iter().any(|k| ours.contains(k)), "{kind} is gated by {keys:?}, which this command does not advertise");
    }
}

#[test]
fn the_scan_sees_each_style() {
    let sample = "let q = '\"'; // \"no.kind\"\nsend_json(\"a.one\", r#\"b.two\"#); let e = \"\\\"c.three\\\"\"; fn f<'a>(x: &'a str) {} let c = '\\''; \"d.four\"";
    let found: Vec<&str> = literals(sample).into_iter().map(|(_, l)| l).collect();
    assert_eq!(found, ["a.one", "b.two", "\\\"c.three\\\"", "d.four"]);
    assert!(is_kind("ask.request") && is_kind("files.chunk.ack") && !is_kind("Ask.x") && !is_kind("ask") && !is_kind("a..b"));
    assert!(not_a_kind("audit.jsonl") && not_a_kind("timeouts.connect") && not_a_kind("codes.detect") && not_a_kind("transfers.fast") && !not_a_kind("codes.query"));
    let (sent, handled) = scan();
    assert_eq!(sent.get("notify.post"), Some(&"ops.rs"), "send_json_id");
    assert_eq!(sent.get("pairing.offer"), Some(&"session.rs"), "Message::new");
    assert_eq!(handled.get("codes.candidate"), Some(&"daemon.rs"), "a match arm");
    assert_eq!(handled.get("files.chunk.ack"), Some(&"files.rs"), "a match on r.kind");
    assert_eq!(sent.get("files.accept"), Some(&"files.rs"), "send_outer");
    assert!(!sent.contains_key("codes.candidate") && !handled.contains_key("notify.post"));
}
