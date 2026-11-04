//! The crate against the shared vectors: its own (codes-reader-v1.json, written by examples/vectors.rs) and the
//! email rule's (email-codes-v1.json, written by the research's email_guard.py, which the Swift and Kotlin ports
//! pass too).

use bridgey_codes::candidate::{code_candidate, NotificationFields};
use bridgey_codes::reader::Answer;
use bridgey_codes::{email, guard, prompt, service, text};
use serde_json::{json, Value};
use std::path::PathBuf;

fn load(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../protocol/test-vectors").join(name);
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn s(v: &Value) -> &str {
    v.as_str().unwrap_or("")
}

#[test]
fn email_rule_matches_the_research_vectors() {
    let doc = load("email-codes-v1.json");
    let mut failures = Vec::new();
    for (i, v) in doc["vectors"].as_array().unwrap().iter().enumerate() {
        let t = s(&v["text"]);
        if text::phone_gate(t) != v["phoneGate"].as_bool().unwrap() {
            failures.push(format!("{i} phoneGate"));
        }
        let normalised = text::code_read_text(t);
        if normalised != s(&v["normalised"]) {
            failures.push(format!("{i} normalised"));
        }
        let pre = email::email_code_precheck(&normalised);
        if pre != v["precheck"].as_bool().unwrap() {
            failures.push(format!("{i} precheck"));
        }
        if text::code_guard_text(&normalised) != s(&v["guardText"]) {
            failures.push(format!("{i} guardText"));
        }
        let snippets = if v["precheck"].as_bool().unwrap() { email::email_model_snippets(&normalised) } else { vec![] };
        let want: Vec<String> = v["snippets"].as_array().unwrap().iter().map(|x| s(x).to_string()).collect();
        if snippets != want {
            failures.push(format!("{i} snippets"));
        }
    }
    assert!(failures.is_empty(), "{} of {} vectors differ: {:?}", failures.len(), doc["vectors"].as_array().unwrap().len(), failures);
}

#[test]
fn crate_matches_its_own_vectors() {
    let doc = load("codes-reader-v1.json");
    for v in doc["guard"].as_array().unwrap() {
        let joined = text::code_read_text(s(&v["text"]));
        let got = guard::accept(v["answer"].as_str(), &text::code_guard_text(&joined));
        assert_eq!(json!(got), v["expect"], "guard {v}");
    }
    for v in doc["readText"].as_array().unwrap() {
        assert_eq!(text::code_read_text(s(&v["text"])), s(&v["expect"]), "readText {v}");
    }
    for v in doc["guardText"].as_array().unwrap() {
        assert_eq!(text::code_guard_text(s(&v["text"])), s(&v["expect"]), "guardText {v}");
    }
    for v in doc["gate"].as_array().unwrap() {
        assert_eq!(text::phone_gate(s(&v["text"])), v["expect"].as_bool().unwrap(), "gate {v}");
    }
    for v in doc["serviceKey"].as_array().unwrap() {
        assert_eq!(service::code_service_key(s(&v["sender"])), s(&v["expect"]), "serviceKey {v}");
        assert_eq!(service::broker_service_key(s(&v["sender"])), s(&v["brokerKey"]), "brokerKey {v}");
    }
    for v in doc["sender"].as_array().unwrap() {
        assert_eq!(service::code_sender(s(&v["title"]), s(&v["applicationName"])), s(&v["expect"]), "sender {v}");
    }
    for v in doc["prompt"].as_array().unwrap() {
        assert_eq!(prompt::user(v["sender"].as_str(), s(&v["text"])), s(&v["expect"]), "prompt {v}");
    }
    for v in doc["parse"].as_array().unwrap() {
        let got = match prompt::parse(s(&v["output"])) {
            Answer::Candidate(code) => json!({"kind": "candidate", "code": code}),
            Answer::NoCode => json!({"kind": "none"}),
            Answer::Failed(_) => json!({"kind": "invalid"}),
        };
        assert_eq!(got, v["expect"], "parse {v}");
    }
    for v in doc["candidate"].as_array().unwrap() {
        let fields: NotificationFields = serde_json::from_value(v["fields"].clone()).unwrap();
        assert_eq!(json!(code_candidate(&fields)), v["expect"], "candidate {v}");
    }
    for v in doc["emailSnippets"].as_array().unwrap() {
        assert_eq!(json!(email::email_model_snippets(s(&v["text"]))), v["expect"], "snippets {v}");
    }
}
