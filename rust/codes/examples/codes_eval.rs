//! The accuracy guard (docs/mesh-and-codes.md): the production path of this crate, end to end, on the research's
//! synthetic eval sets. SMS: the candidate rule (gate and digit-box join), then the reader (model, guard with links
//! blanked). Mail: the phone's preview shaping (as in the research's `shape_preview`, with the phone's gate), the
//! candidate rule (email pre-check), then the reader with its second pass on snippets. Scored as the research scores
//! (exact code, wrong code, code shown for a no-code message). No message text is printed.
//!
//! cargo run --release -p bridgey-codes --features llama --example codes_eval -- --model M.gguf \
//!   --sms synth=gen/test_meta.jsonl --sms bench=otp-samples.json --email blind2=blind_set2.jsonl [--threads 4]

use bridgey_codes::candidate::{code_candidate, Channel, NotificationFields};
use bridgey_codes::engine::LocalEngine;
use bridgey_codes::llama::LlamaRunner;
use bridgey_codes::reader::{Outcome, Reader};
use bridgey_codes::service::code_sender;
use bridgey_codes::text::phone_gate;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{Duration, Instant};

const PREVIEW_MAX_UTF16: usize = 600;

fn normalise(code: &str) -> String {
    code.chars().filter(|c| !c.is_whitespace() && *c != '-').collect::<String>().to_uppercase()
}

fn expected(item: &Value) -> Vec<String> {
    let mut codes: Vec<String> = Vec::new();
    match &item["code"] {
        Value::String(s) => codes.push(s.clone()),
        Value::Array(a) => codes.extend(a.iter().filter_map(Value::as_str).map(str::to_string)),
        _ => {}
    }
    codes.extend(item["alt"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_string));
    codes.iter().map(|c| normalise(c)).collect()
}

fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

/// The research's `cut_utf16`: cut at the last whitespace at or before the limit, never inside a token.
fn cut(s: &str) -> String {
    if utf16_len(s) <= PREVIEW_MAX_UTF16 {
        return s.to_string();
    }
    let chars: Vec<char> = s.chars().collect();
    let mut units = 0;
    let mut end = 0;
    for (i, ch) in chars.iter().enumerate() {
        units += ch.len_utf16();
        if units > PREVIEW_MAX_UTF16 {
            end = i;
            break;
        }
    }
    let mut at = end;
    while at > 0 && !chars[at].is_whitespace() {
        at -= 1;
    }
    if at == 0 {
        return String::new();
    }
    chars[..at].iter().collect::<String>().trim_end().to_string()
}

/// The phone's preview (research `shape_preview` with the phone's gate), or None when it sends none.
fn shape_preview(n: &Value) -> Option<String> {
    if n["group_summary"].as_bool() == Some(true) || n["text_lines"].as_u64().unwrap_or(0) > 1 {
        return None;
    }
    let subject = n["text"].as_str().unwrap_or("").trim().to_string();
    let mut body = match n["messaging_text"].as_str() {
        Some(m) if !m.is_empty() => m.trim().to_string(),
        _ => {
            let big = n["big_text"].as_str().unwrap_or("").trim().to_string();
            if big.is_empty() { subject.clone() } else { big }
        }
    };
    if !subject.is_empty() && !body.contains(&subject) {
        body = format!("{subject}\n{body}");
    }
    let body = cut(&body);
    (!body.is_empty() && phone_gate(&body)).then_some(body)
}

fn app_package(app: &str) -> (&'static str, &'static str) {
    match app {
        "gmail" => ("com.google.android.gm", "Gmail"),
        "outlook" => ("com.microsoft.office.outlook", "Outlook"),
        "proton" => ("ch.protonmail.android", "Proton Mail"),
        _ => ("com.readdle.spark", "Spark"),
    }
}

#[derive(Default)]
struct Tally {
    code_n: usize,
    exact: usize,
    wrong: usize,
    neg_n: usize,
    false_code: usize,
    timeouts: usize,
    reasons: std::collections::BTreeMap<&'static str, usize>,
    ms: Vec<f64>,
}

fn load(path: &str) -> Vec<Value> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
    if text.trim_start().starts_with('{') && !text.contains("\n{") {
        let doc: Value = serde_json::from_str(&text).unwrap();
        return doc["samples"].as_array().cloned().unwrap_or_default();
    }
    text.lines().filter(|l| !l.trim().is_empty()).map(|l| serde_json::from_str(l).unwrap()).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut model = None;
    let mut sets: Vec<(Channel, String, String)> = Vec::new();
    let mut threads = None;
    let mut budget = Duration::from_secs(10);
    let mut out = None;
    let mut i = 0;
    while i < args.len() {
        let value = args.get(i + 1).cloned().unwrap_or_default();
        match args[i].as_str() {
            "--model" => model = Some(PathBuf::from(&value)),
            "--threads" => threads = value.parse().ok(),
            "--budget-ms" => budget = Duration::from_millis(value.parse().unwrap()),
            "--out" => out = Some(value.clone()),
            "--sms" | "--email" => {
                let (name, path) = value.split_once('=').expect("name=path");
                sets.push((if args[i] == "--sms" { Channel::Sms } else { Channel::Email }, name.into(), path.into()));
            }
            other => panic!("unknown argument {other}"),
        }
        i += 2;
    }
    let model = model.expect("--model");
    let engine = LocalEngine::new(Duration::from_secs(3600), Box::new(move || Some(model.clone())), Box::new(move || Box::new(LlamaRunner::new(threads))));
    let mut reader = Reader::new(&engine);
    reader.budget = budget;
    // Warm up (load, first run), as the Mac does after a download.
    let warm = Instant::now();
    let _ = reader.read("OTP is 482913 for your login.", Some("HDFCBK"), Channel::Sms);
    println!("load and first read {:.0} ms", warm.elapsed().as_secs_f64() * 1000.0);
    let mut report = serde_json::Map::new();
    for (channel, name, path) in &sets {
        let mut t = Tally::default();
        for item in load(path) {
            let want = expected(&item);
            let fields = match channel {
                Channel::Sms => NotificationFields {
                    package_name: "com.google.android.apps.messaging".into(),
                    sms_default_app: Some(true),
                    text: item["body"].as_str().unwrap_or("").into(),
                    ..Default::default()
                },
                Channel::Email => NotificationFields {
                    package_name: app_package(item["app"].as_str().unwrap_or("")).0.into(),
                    sms_default_app: Some(false),
                    email_app: Some(true),
                    email_codes: true,
                    text: item["text"].as_str().unwrap_or("").into(),
                    preview: shape_preview(&item),
                    ..Default::default()
                },
            };
            let sender = match channel {
                Channel::Sms => item["sender"].as_str().unwrap_or("").to_string(),
                Channel::Email => code_sender(item["title"].as_str().unwrap_or(""), app_package(item["app"].as_str().unwrap_or("")).1),
            };
            let started = Instant::now();
            let outcome = match code_candidate(&fields) {
                Some(candidate) => reader.read(&candidate.text, Some(&sender), candidate.channel),
                None => Outcome::NoCode,
            };
            t.ms.push(started.elapsed().as_secs_f64() * 1000.0);
            if let Outcome::Fallback(reason) = &outcome {
                t.timeouts += 1;
                *t.reasons.entry(reason.wire()).or_default() += 1;
            }
            let shown = match &outcome {
                Outcome::Code(c) => Some(normalise(c)),
                _ => None,
            };
            if want.is_empty() {
                t.neg_n += 1;
                t.false_code += usize::from(shown.is_some());
            } else {
                t.code_n += 1;
                match shown {
                    Some(c) if want.contains(&c) || want.contains(&format!("G{c}")) => t.exact += 1,
                    Some(_) => t.wrong += 1,
                    None => {}
                }
            }
        }
        t.ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let median = t.ms.get(t.ms.len() / 2).copied().unwrap_or(0.0);
        let p95 = t.ms.get(t.ms.len() * 95 / 100).copied().unwrap_or(0.0);
        println!(
            "{name:8} codes {}/{} wrong {} false {}/{} fallbacks {} {:?} median {median:.0} ms p95 {p95:.0} ms",
            t.exact, t.code_n, t.wrong, t.false_code, t.neg_n, t.timeouts, t.reasons
        );
        report.insert(name.clone(), json!({"codes": t.exact, "codeN": t.code_n, "wrong": t.wrong, "falseCodes": t.false_code, "negN": t.neg_n, "fallbacks": t.timeouts, "medianMs": median, "p95Ms": p95}));
    }
    if let Some(out) = out {
        std::fs::write(out, serde_json::to_string_pretty(&Value::Object(report)).unwrap()).unwrap();
    }
    engine.shutdown();
}
