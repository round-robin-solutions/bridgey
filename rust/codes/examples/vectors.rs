//! Writes protocol/test-vectors/codes-reader-v1.json: this crate's answers for the code rules, so the Swift and Kotlin
//! copies are checked against the one source (docs/mesh-and-codes.md, "One reader"). Inputs are synthetic: hand
//! cases plus the original benchmark messages (otp-samples.json). Run from rust/: `cargo run -p bridgey-codes
//! --example vectors`; `tests/vectors.rs` fails when the file and the crate disagree.

use bridgey_codes::candidate::{code_candidate, NotificationFields};
use bridgey_codes::reader::Answer;
use bridgey_codes::{email, guard, prompt, service, text};
use serde_json::{json, Value};
use std::path::PathBuf;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn answer_json(answer: &Answer) -> Value {
    match answer {
        Answer::Candidate(code) => json!({"kind": "candidate", "code": code}),
        Answer::NoCode => json!({"kind": "none"}),
        Answer::Failed(_) => json!({"kind": "invalid"}),
    }
}

const GUARD_HAND: &[(&str, &str)] = &[
    ("482913", "OTP is 482913 for your login."),
    ("482913", "Your code is 482 913. Do not share."),
    ("482 913", "Your code is 482 913. Do not share."),
    ("G-482913", "G-482913 is your Google verification code."),
    ("482913", "G-482913 is your Google verification code."),
    ("PP301842", "Use PP-301842 to sign in."),
    ("301842", "Use PP-301842 to sign in."),
    ("5minMe", "Call me in 5 min me ok"),
    ("30-10-26", "Delivered on 30-10-26 at 10:00."),
    ("Welcome@4821", "Your temporary password is Welcome@4821"),
    ("482913", "Verify here: https://example.com/verify/482913 now"),
    ("2026", "(c) 2026 Example Inc."),
    ("123456789", "Code 123456789 for you"),
    ("abc123", "Your code is ABC123."),
    ("7Q39XT", "Sign in with code 7Q3-9XT"),
    ("7Q3-9XT", "Sign in with code 7Q3-9XT"),
    ("4829", "Use 48291 to log in."),
    ("", "Your code is 482913."),
    ("  482913  ", "OTP 482913."),
    ("AB", "AB-1234 is the code"),
    ("12-34", "Code 12-34 now"),
    ("4821", "PIN 4 8 2 1"),
];

const READ_TEXT: &[&str] = &[
    "Your verification code is 4 8 2 9 1 3",
    "Code: 48 29 13",
    "Your OTP is 6-0-2-7-3-1. Do not share it.",
    "Delivered on 30-10-26.",
    "Call 1 800 123 4567 for help",
    "1 2 is not a code",
    "Seats 1 2 3 4 5 6 7 8 9 are free",
    "Ref 1-2-3",
    "PIN 4 8 2 1 and 9 9",
];

const GUARD_TEXT: &[&str] = &[
    "Verify at https://example.com/verify/482913 or use 551204",
    "Open www.example.com/a/1234 now",
    "See example.co.in/track/40011234 for order",
    "\u{00A9} 2026 Example Inc. Code 330912",
    "(c) 2020-2026 Example. Copyright 2026",
    "mail me at a@b.com/x 4821",
];

const GATE: &[&str] = &[
    "Your OTP is 482913",
    "Hello, see you at 5",
    "Code 7Q3-9XT",
    "Your verification code is 4 8 2 9 1 3",
    "Use 591-047 to verify",
    "Thanks for your order",
    "abcd efgh",
    "Pay Rs 2,499.00",
];

const SERVICE: &[&str] = &[
    "AX-HDFCBK-S", "VM-HDFCBK", "HDFC Bank", "+919876543210", "57575", "", "Google", "Swiggy Alerts", "Amazon.in",
    "no-reply Netflix", "The Security Team at Acme", "Ваш Банк", "JD-SBIINB", "Microsoft account team",
];

const SENDER: &[(&str, &str)] = &[("HDFCBK", "Messages"), ("2 new messages", "Messages"), ("", "Gmail"), ("  Swiggy  ", "Messages"), ("12 New emails", "Outlook")];

const PARSE: &[&str] = &[
    "{\"kind\":\"otp\",\"code\":\"482913\"}",
    "{\"kind\":\"none\",\"code\":null}",
    "garbage",
    "{\"kind\":\"otp\",\"code\":482913}",
    "x {\"kind\":\"otp\",\"code\":\"G-1234\"} y",
    "{\"kind\":\"otp\"",
    "{\"code\":\"1234\"}",
    "{\"kind\":\"otp\",\"code\":\"\"}",
    "<end_of_turn>{\"kind\":\"none\"}",
];

fn main() {
    let samples: Value = serde_json::from_str(&std::fs::read_to_string(root().join("protocol/test-vectors/otp-samples.json")).unwrap()).unwrap();
    let mut guard_cases: Vec<Value> = Vec::new();
    for (answer, message) in GUARD_HAND {
        let joined = text::code_read_text(message);
        guard_cases.push(json!({"answer": answer, "text": message, "expect": guard::accept(Some(answer), &text::code_guard_text(&joined))}));
    }
    let mut gate: Vec<Value> = GATE.iter().map(|t| json!({"text": t, "expect": text::phone_gate(t)})).collect();
    for sample in samples["samples"].as_array().unwrap() {
        let body = sample["body"].as_str().unwrap();
        let joined = text::code_read_text(body);
        let guard_text = text::code_guard_text(&joined);
        for code in sample["code"].as_array().unwrap().iter().filter_map(Value::as_str) {
            guard_cases.push(json!({"answer": code, "text": body, "expect": guard::accept(Some(code), &guard_text)}));
        }
        gate.push(json!({"text": body, "expect": text::phone_gate(body)}));
    }
    let long_sender = "S".repeat(80);
    let prompts = [(Some("HDFCBK"), "OTP is 482913."), (None, "  Your code: 7391  "), (Some(long_sender.as_str()), "Code 1234")];
    let candidate_cases = [
        json!({"packageName": "com.google.android.apps.messaging", "smsDefaultApp": true, "text": "OTP is 4 8 2 9 1 3 for login"}),
        json!({"packageName": "com.google.android.apps.messaging", "smsDefaultApp": true, "redacted": true, "text": "OTP is 482913"}),
        json!({"packageName": "com.google.android.apps.messaging", "smsDefaultApp": true, "text": "See you at the station"}),
        json!({"packageName": "com.truecaller", "text": "Your OTP is 551204"}),
        json!({"packageName": "com.whatsapp", "smsDefaultApp": false, "text": "Your OTP is 551204"}),
        json!({"packageName": "com.google.android.gm", "smsDefaultApp": false, "emailApp": true, "emailCodes": true, "text": "Acme", "preview": "Your verification code is 330912. It expires in 10 minutes."}),
        json!({"packageName": "com.google.android.gm", "smsDefaultApp": false, "emailApp": true, "emailCodes": false, "text": "Acme", "preview": "Your verification code is 330912."}),
        json!({"packageName": "com.google.android.gm", "smsDefaultApp": false, "emailApp": true, "emailCodes": true, "text": "Acme", "preview": "Use code FEST50 for 20% off. Unsubscribe"}),
        json!({"packageName": "com.example.mail", "smsDefaultApp": false, "emailApp": true, "emailCodes": true, "text": "Your verification code is 330912."}),
        json!({"packageName": "com.google.android.apps.messaging", "smsDefaultApp": true, "text": "x".repeat(601) + " 482913"}),
    ];
    let snippets: Vec<Value> = ["Hello. Your verification code is 330912 and it expires soon. Thanks, Acme", "Nothing here"]
        .iter()
        .map(|t| json!({"text": t, "expect": email::email_model_snippets(t)}))
        .collect();
    let doc = json!({
        "note": "Written by rust/codes/examples/vectors.rs (the bridgey-codes crate is the source of truth for the code rules). guard.expect is accept(answer, code_guard_text(code_read_text(text))); gate is the phone's gate (join, then the gate).",
        "guard": guard_cases,
        "readText": READ_TEXT.iter().map(|t| json!({"text": t, "expect": text::code_read_text(t)})).collect::<Vec<_>>(),
        "guardText": GUARD_TEXT.iter().map(|t| json!({"text": t, "expect": text::code_guard_text(t)})).collect::<Vec<_>>(),
        "gate": gate,
        "serviceKey": SERVICE.iter().map(|s| json!({"sender": s, "expect": service::code_service_key(s), "brokerKey": service::broker_service_key(s)})).collect::<Vec<_>>(),
        "sender": SENDER.iter().map(|(t, a)| json!({"title": t, "applicationName": a, "expect": service::code_sender(t, a)})).collect::<Vec<_>>(),
        "prompt": prompts.iter().map(|(s, t)| json!({"sender": s, "text": t, "expect": prompt::user(*s, t)})).collect::<Vec<_>>(),
        "parse": PARSE.iter().map(|o| json!({"output": o, "expect": answer_json(&prompt::parse(o))})).collect::<Vec<_>>(),
        "candidate": candidate_cases.iter().map(|c| {
            let fields: NotificationFields = serde_json::from_value(c.clone()).unwrap();
            json!({"fields": c, "expect": code_candidate(&fields)})
        }).collect::<Vec<_>>(),
        "emailSnippets": snippets,
    });
    let mut out = String::from("{\n");
    let object = doc.as_object().unwrap();
    for (index, (key, value)) in object.iter().enumerate() {
        out.push_str(&format!("{}: ", serde_json::to_string(key).unwrap()));
        match value {
            Value::Array(items) => {
                out.push_str("[\n");
                let lines: Vec<String> = items.iter().map(|v| format!("  {}", serde_json::to_string(v).unwrap())).collect();
                out.push_str(&lines.join(",\n"));
                out.push_str("\n]");
            }
            other => out.push_str(&serde_json::to_string(other).unwrap()),
        }
        out.push_str(if index + 1 < object.len() { ",\n" } else { "\n" });
    }
    out.push_str("}\n");
    let path = root().join("protocol/test-vectors/codes-reader-v1.json");
    std::fs::write(&path, out).unwrap();
    println!("wrote {}", path.display());
}
