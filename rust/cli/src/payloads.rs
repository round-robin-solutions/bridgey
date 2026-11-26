//! The agent kinds' payloads as this command writes and reads them (docs/protocol.md "Draft: agent devices",
//! protocol/messages.json). protocol/test-vectors/agent-v1.json pins both directions, and the phone checks the
//! same file: what this command writes is what the phone accepts, and what the phone writes reads the same here.
//!
//! Writers refuse what the phone would refuse (an answer `invalid` from the phone becomes a usage error here).
//! Readers drop what the contract calls invalid, keeping only the fields the vectors list.

use crate::crypto::is_uuid;
use serde_json::{json, Map, Value};

/// Grant names a request may name, as `bridgey grants` shows them (daemon::GRANTS).
fn known_grant(name: &str) -> bool {
    crate::daemon::GRANTS.iter().any(|g| g.0 == name)
}

/// `name is MIN to MAX characters (got N)` when the text is outside the range (characters, as the phone counts).
pub fn check_len(name: &str, text: &str, min: usize, max: usize) -> Result<(), String> {
    let n = text.chars().count();
    if n < min || n > max {
        return Err(format!("{name} is {min} to {max} characters (got {n})"));
    }
    Ok(())
}

fn id(value: &str, what: &str) -> Result<(), String> {
    if is_uuid(value) { Ok(()) } else { Err(format!("{what} is not a UUID")) }
}

fn optional(payload: &mut Value, key: &str, value: Option<&str>) {
    if let Some(v) = value {
        payload[key] = json!(v);
    }
}

/// notify.post and ask.request are at most 4,096 bytes of plaintext (protocol/messages.json).
const REQUEST_MAX_BYTES: usize = 4096;

fn fits(payload: Value) -> Result<Value, String> {
    if payload.to_string().len() > REQUEST_MAX_BYTES {
        return Err(format!("the request is over {REQUEST_MAX_BYTES} bytes once encoded; shorten the title or body"));
    }
    Ok(payload)
}

// region What this command writes

/// agent.hello, once per session after features.update. App and OS are at most 64 characters.
pub fn hello(app: &str, os: &str) -> Value {
    let cut = |t: &str| t.chars().take(64).collect::<String>();
    json!({"version": 1, "platform": "cli", "app": cut(app), "os": cut(os)})
}

/// agent.grant_request: 1 to 10 known grant names; a note is cut to 120 characters.
pub fn grant_request(request_id: &str, keys: &[String], note: Option<&str>) -> Result<Value, String> {
    id(request_id, "requestId")?;
    if keys.is_empty() || keys.len() > crate::daemon::GRANTS.len() || keys.iter().any(|k| !known_grant(k)) {
        let names: Vec<&str> = crate::daemon::GRANTS.iter().map(|g| g.0).collect();
        return Err(format!("name 1 to {} grants from: {}", names.len(), names.join(", ")));
    }
    let mut payload = json!({"version": 1, "requestId": request_id, "keys": keys});
    if let Some(n) = note {
        payload["note"] = json!(n.chars().take(120).collect::<String>());
    }
    Ok(payload)
}

/// notify.post. A title of 1 to 120 characters, a body of at most 1,000, tag and from of at most 64.
pub fn notify_post(notify_id: &str, title: &str, body: Option<&str>, priority: &str, tag: Option<&str>, from: Option<&str>) -> Result<Value, String> {
    id(notify_id, "notifyId")?;
    check_len("title", title, 1, 120)?;
    if let Some(b) = body {
        check_len("body", b, 0, 1000)?;
    }
    if priority != "normal" && priority != "high" {
        return Err(format!("priority is normal or high (got {priority})"));
    }
    if let Some(t) = tag {
        check_len("tag", t, 0, 64)?;
    }
    if let Some(f) = from {
        check_len("from", f, 0, 64)?;
    }
    let mut payload = json!({"version": 1, "notifyId": notify_id, "title": title, "priority": priority});
    optional(&mut payload, "body", body);
    optional(&mut payload, "tag", tag);
    optional(&mut payload, "from", from);
    fits(payload)
}

/// One answer button of ask.request.
fn check_option(o: &Value, seen: &mut Vec<String>) -> Result<(), String> {
    let id = o["id"].as_str().unwrap_or("");
    if id.is_empty() || id.len() > 32 || !id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-') {
        return Err(format!("option ID {id}: 1 to 32 of a-z, 0-9, _ and -"));
    }
    check_len("option label", o["label"].as_str().unwrap_or(""), 1, 20)?;
    if seen.iter().any(|s| s == id) {
        return Err(format!("option ID {id} is used twice"));
    }
    seen.push(id.to_string());
    Ok(())
}

/// The text fields of ask.request. `options` are `{id, label}` objects.
pub struct AskText<'a> {
    pub title: &'a str,
    pub body: Option<&'a str>,
    pub text_hint: Option<&'a str>,
    pub from: Option<&'a str>,
}

/// ask.request: 1 to 3 options, or at most 2 with a typed answer, and an expiry after `now`, at most 24 hours ahead.
pub fn ask_request(ask_id: &str, text: &AskText, options: &[Value], allow_text: bool, require_unlock: bool, expires_at: u64, now: u64) -> Result<Value, String> {
    id(ask_id, "askId")?;
    check_len("title", text.title, 1, 120)?;
    if let Some(b) = text.body {
        check_len("body", b, 0, 1000)?;
    }
    let mut seen = Vec::new();
    for o in options {
        check_option(o, &mut seen)?;
    }
    let max = if allow_text { 2 } else { 3 };
    if options.len() > max || (options.is_empty() && !allow_text) {
        return Err((if allow_text { "with --text, give at most 2 options" } else { "give 1 to 3 options (-o ID=LABEL) or --text" }).into());
    }
    if let Some(h) = text.text_hint {
        check_len("text hint", h, 0, 40)?;
    }
    if let Some(f) = text.from {
        check_len("from", f, 0, 64)?;
    }
    if expires_at <= now {
        return Err("--timeout must be above zero".into());
    }
    if expires_at - now > 86_400_000 {
        return Err("--timeout is at most 24h".into());
    }
    let options: Vec<Value> = options.iter().map(|o| json!({"id": o["id"], "label": o["label"]})).collect();
    let mut payload = json!({"version": 1, "askId": ask_id, "title": text.title, "options": options, "allowText": allow_text,
                             "requireUnlock": require_unlock, "expiresAt": expires_at});
    optional(&mut payload, "body", text.body);
    optional(&mut payload, "textHint", text.text_hint);
    optional(&mut payload, "from", text.from);
    fits(payload)
}

/// ask.cancel and ask.status: the ask's ID.
pub fn ask_ref(ask_id: &str) -> Result<Value, String> {
    id(ask_id, "askId")?;
    Ok(json!({"version": 1, "askId": ask_id}))
}

/// clipboard.request: the expiry after `now`, at most 10 minutes ahead.
pub fn clipboard_request(request_id: &str, expires_at: u64, now: u64) -> Result<Value, String> {
    id(request_id, "requestId")?;
    if expires_at <= now || expires_at - now > 600_000 {
        return Err("--timeout is above zero and at most 10m".into());
    }
    Ok(json!({"version": 1, "requestId": request_id, "expiresAt": expires_at}))
}

/// agent.notifications.query: a limit of 1 to 20.
pub fn notifications_query(query_id: &str, limit: u64) -> Result<Value, String> {
    id(query_id, "queryId")?;
    if !(1..=20).contains(&limit) {
        return Err("limit must be an integer from 1 to 20".into());
    }
    Ok(json!({"version": 1, "queryId": query_id, "limit": limit}))
}

/// The fields of codes.query.
pub struct CodesQuery<'a> {
    pub service: Option<&'a str>,
    pub since_ms: u64,
    pub newer_than: Option<u64>,
    pub wait_ms: u64,
    pub latest_only: bool,
}

/// codes.query: since at most an hour, a wait of at most 10 minutes, a service of at most 64 characters.
pub fn codes_query(query_id: &str, q: &CodesQuery) -> Result<Value, String> {
    id(query_id, "queryId")?;
    if q.since_ms > 3_600_000 || q.wait_ms > 600_000 {
        return Err("codes look back at most 1h and wait at most 10m per query".into());
    }
    if let Some(s) = q.service {
        check_len("service", s, 0, 64)?;
    }
    let mut payload = json!({"version": 1, "queryId": query_id, "sinceMs": q.since_ms, "waitMs": q.wait_ms, "latestOnly": q.latest_only});
    optional(&mut payload, "service", q.service);
    if let Some(n) = q.newer_than {
        payload["newerThan"] = json!(n);
    }
    Ok(payload)
}

/// codes.cancel: the held query's ID.
pub fn codes_cancel(query_id: &str) -> Result<Value, String> {
    id(query_id, "queryId")?;
    Ok(json!({"version": 1, "queryId": query_id}))
}

// endregion

// region What this command reads

fn version_one(p: &Value) -> Option<&Map<String, Value>> {
    p.as_object().filter(|_| p["version"] == 1)
}

fn uuid_field(p: &Value, key: &str) -> Option<String> {
    p[key].as_str().filter(|v| is_uuid(v)).map(str::to_string)
}

/// agent.grants: known grant names and fields only, bounded; an unknown state reads as off. The phone's words are
/// shown, never trusted. None when the version is not 1 or the grants are not an array.
pub fn grants(p: &Value) -> Option<Vec<Value>> {
    version_one(p)?;
    let list = p["grants"].as_array()?;
    Some(
        list.iter()
            .filter(|g| g["key"].as_str().is_some_and(known_grant))
            .take(crate::daemon::GRANTS.len())
            .map(|g| {
                let state = match g["state"].as_str() {
                    Some("on") => "on",
                    Some("waiting") => "waiting",
                    _ => "off",
                };
                let mut o = json!({"key": g["key"], "state": state});
                for k in ["grantedAt", "expiresAt"] {
                    if let Some(v) = g[k].as_u64() {
                        o[k] = json!(v);
                    }
                }
                if let Some(w) = g["window"].as_str().filter(|w| ["1h", "today", "7d", "forever"].contains(w)) {
                    o["window"] = json!(w);
                }
                if let Some(s) = g["scope"].as_str() {
                    o["scope"] = json!(crate::session::printable(s, 200));
                }
                o
            })
            .collect(),
    )
}

/// agent.request_result: the request's messageId (`ref`), its kind and the status. An unknown status is kept (a
/// command reads it as "cannot do this").
pub fn request_result(p: &Value) -> Option<Value> {
    version_one(p)?;
    let mut out = json!({"ref": p["ref"].as_str()?, "requestKind": p["requestKind"].as_str()?, "status": p["status"].as_str()?});
    if let Some(ms) = p["retryAfterMs"].as_u64() {
        out["retryAfterMs"] = json!(ms);
    }
    if let Some(g) = p["grant"].as_str() {
        out["grant"] = json!(g);
    }
    Some(out)
}

/// notify.result.
pub fn notify_result(p: &Value) -> Option<Value> {
    version_one(p)?;
    Some(json!({"notifyId": uuid_field(p, "notifyId")?, "status": p["status"].as_str()?}))
}

/// ask.posted, ask.dismissed, ask.expired and ask.cancelled: the ask's ID.
pub fn ask_ref_of(p: &Value) -> Option<String> {
    version_one(p)?;
    uuid_field(p, "askId")
}

/// ask.answer: an option or a text (at most 1,000 characters), never both or neither.
pub fn ask_answer(p: &Value) -> Option<Value> {
    version_one(p)?;
    let ask_id = uuid_field(p, "askId")?;
    let answered_at = p["answeredAt"].as_u64()?;
    let mut out = json!({"askId": ask_id, "answeredAt": answered_at});
    match (p.get("option"), p.get("text")) {
        (Some(Value::String(o)), None) if !o.is_empty() && o.chars().count() <= 32 => out["option"] = json!(o),
        (None, Some(Value::String(t))) if t.chars().count() <= 1000 => out["text"] = json!(t),
        _ => return None,
    }
    Some(out)
}

/// Text and HTML in clipboard.response together at most 32 KiB.
const CLIPBOARD_RESPONSE_MAX_BYTES: usize = 32 * 1024;

/// clipboard.response: sent (with text, and HTML when there is some), declined or expired.
pub fn clipboard_response(p: &Value) -> Option<Value> {
    version_one(p)?;
    let request_id = uuid_field(p, "requestId")?;
    let status = p["status"].as_str().filter(|s| ["sent", "declined", "expired"].contains(s))?;
    let mut out = json!({"requestId": request_id, "status": status});
    if status == "sent" {
        let text = p["text"].as_str()?;
        let html = match p.get("html") {
            None | Some(Value::Null) => None,
            Some(Value::String(h)) => Some(h.as_str()),
            Some(_) => return None,
        };
        if text.len() + html.map(str::len).unwrap_or(0) > CLIPBOARD_RESPONSE_MAX_BYTES {
            return None;
        }
        out["text"] = json!(text);
        if let Some(h) = html {
            out["html"] = json!(h);
        }
    }
    Some(out)
}

fn code_entry(c: &Value) -> Option<Value> {
    let via: Vec<&str> = c["via"].as_array()?.iter().map(Value::as_str).collect::<Option<_>>()?;
    Some(json!({
        "code": c["code"].as_str()?, "service": c["service"].as_str()?,
        "source": c["source"].as_str().filter(|s| *s == "sms" || *s == "email")?, "app": c["app"].as_str()?,
        "postedAt": c["postedAt"].as_u64()?, "latest": c["latest"].as_bool()?, "replaced": c["replaced"].as_bool()?, "via": via,
    }))
}

/// codes.result: at most 20 codes, newest first, how many devices read codes for the phone, and whether it timed out.
pub fn codes_result(p: &Value) -> Option<Value> {
    version_one(p)?;
    let list = p["codes"].as_array().filter(|a| a.len() <= 20)?;
    let codes: Vec<Value> = list.iter().map(code_entry).collect::<Option<_>>()?;
    Some(json!({"queryId": p["queryId"].as_str()?, "readers": p["readers"].as_u64()?, "timedOut": p["timedOut"].as_bool()?, "codes": codes}))
}

// endregion

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_798_000_000_000;

    fn vectors() -> Value {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/agent-v1.json");
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn cases(doc: &Value, group: &str) -> Vec<Value> {
        let list = doc[group].as_array().unwrap_or_else(|| panic!("agent-v1.json has no {group}")).clone();
        assert!(!list.is_empty(), "{group}");
        list
    }

    fn rejects(case: &Value) -> bool {
        case["expect"] == "reject"
    }

    fn s<'a>(p: &'a Value, key: &str) -> Option<&'a str> {
        p[key].as_str()
    }

    /// What this command writes: every case marked `write` exactly, and never the plaintext of a case the phone
    /// refuses (it refuses to write it, or writes something else).
    fn writes(doc: &Value, group: &str, write: impl Fn(&Value) -> Result<Value, String>) {
        for case in cases(doc, group) {
            let (p, name) = (&case["plaintext"], &case["name"]);
            let written = write(p);
            if rejects(&case) {
                assert_ne!(written.as_ref().ok(), Some(p), "{group}: {name} is refused by the phone");
            } else if case["write"] == true || group_writes_every_case(group) {
                assert_eq!(written.as_ref(), Ok(p), "{group}: {name}");
            }
        }
    }

    /// Groups written before `write` marks existed, whose accepted cases are all what this command writes.
    fn group_writes_every_case(group: &str) -> bool {
        matches!(group, "notifyPost" | "askRequest" | "codesQuery")
    }

    /// What this command reads: the fields it keeps for each accepted case, and nothing for a refused one.
    fn reads(doc: &Value, group: &str, read: impl Fn(&Value, &Value) -> Option<Value>) {
        for case in cases(doc, group) {
            let got = read(&case["plaintext"], &case);
            if rejects(&case) {
                assert_eq!(got, None, "{group}: {} is dropped", case["name"]);
            } else {
                assert_eq!(got.as_ref(), Some(&case["expect"]), "{group}: {}", case["name"]);
            }
        }
    }

    fn strings(p: &Value, key: &str) -> Vec<String> {
        p[key].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default()
    }

    #[test]
    fn written_like_the_agent_vectors() {
        let doc = vectors();
        writes(&doc, "agentHello", |p| Ok(hello(s(p, "app").unwrap_or(""), s(p, "os").unwrap_or(""))));
        writes(&doc, "agentGrantRequest", |p| grant_request(s(p, "requestId").unwrap_or(""), &strings(p, "keys"), s(p, "note")));
        writes(&doc, "notifyPost", |p| {
            notify_post(s(p, "notifyId").unwrap_or(""), s(p, "title").unwrap_or(""), s(p, "body"), s(p, "priority").unwrap_or(""), s(p, "tag"), s(p, "from"))
        });
        writes(&doc, "askRequest", |p| {
            let text = AskText { title: s(p, "title").unwrap_or(""), body: s(p, "body"), text_hint: s(p, "textHint"), from: s(p, "from") };
            let options = p["options"].as_array().cloned().unwrap_or_default();
            ask_request(s(p, "askId").unwrap_or(""), &text, &options, p["allowText"] == true, p["requireUnlock"] == true, p["expiresAt"].as_u64().unwrap_or(0), NOW)
        });
        writes(&doc, "askRef", |p| ask_ref(s(p, "askId").unwrap_or("")));
        writes(&doc, "clipboardRequest", |p| clipboard_request(s(p, "requestId").unwrap_or(""), p["expiresAt"].as_u64().unwrap_or(0), NOW));
        writes(&doc, "agentNotificationsQuery", |p| notifications_query(s(p, "queryId").unwrap_or(""), p["limit"].as_u64().unwrap_or(0)));
        writes(&doc, "codesQuery", |p| {
            let q = CodesQuery {
                service: s(p, "service"),
                since_ms: p["sinceMs"].as_u64().unwrap_or(0),
                newer_than: p["newerThan"].as_u64(),
                wait_ms: p["waitMs"].as_u64().unwrap_or(0),
                latest_only: p["latestOnly"] == true,
            };
            codes_query(s(p, "queryId").unwrap_or(""), &q)
        });
        writes(&doc, "codesCancel", |p| codes_cancel(s(p, "queryId").unwrap_or("")));
    }

    #[test]
    fn read_like_the_agent_vectors() {
        let doc = vectors();
        reads(&doc, "agentGrants", |p, _| grants(p).map(|g| json!({"grants": g})));
        reads(&doc, "agentRequestResult", |p, _| request_result(p));
        reads(&doc, "notifyResult", |p, _| notify_result(p));
        reads(&doc, "askRef", |p, _| ask_ref_of(p).map(|id| json!({"askId": id})));
        reads(&doc, "askAnswer", |p, _| ask_answer(p));
        reads(&doc, "clipboardResponse", |p, _| clipboard_response(p));
        reads(&doc, "codesResult", |p, _| codes_result(p));
        reads(&doc, "agentNotificationsResult", |p, case| {
            let limit = case["limit"].as_u64().unwrap() as usize;
            match crate::notifications::validate_result(p.clone(), "01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d21", limit) {
                Ok(v) => Some(json!({"queryId": v["queryId"], "status": "ok", "notifications": v["notifications"], "truncated": v["truncated"]})),
                Err(e) if e.code == "unavailable" => Some(json!({"queryId": p["queryId"], "status": "unavailable", "notifications": [], "truncated": p["truncated"]})),
                Err(_) => None,
            }
        });
    }

    /// The command line refuses, before anything is sent, what the phone would answer `invalid`.
    #[test]
    fn limits_the_phone_checks_are_checked_here() {
        let u = "01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d21";
        let long = "x".repeat(65);
        assert!(notify_post(u, "t", None, "normal", Some(&long), None).is_err(), "a tag of 65 characters");
        assert!(notify_post(u, "t", None, "normal", None, Some(&long)).is_err(), "from of 65 characters");
        let emoji = "\u{1F600}".repeat(1000);
        assert!(notify_post(u, &"\u{1F600}".repeat(120), Some(&emoji), "normal", None, None).is_err(), "over 4,096 bytes");
        let text = AskText { title: "t", body: None, text_hint: Some(&"h".repeat(41)), from: None };
        let yes = [json!({"id": "yes", "label": "Yes"})];
        assert!(ask_request(u, &text, &yes, true, false, NOW + 1, NOW).is_err(), "a text hint of 41 characters");
        let text = AskText { title: "t", body: None, text_hint: None, from: None };
        assert!(ask_request(u, &text, &yes, false, false, NOW, NOW).is_err(), "a timeout of zero");
        assert!(ask_request(u, &text, &yes, false, false, NOW + 86_400_000, NOW).is_ok(), "24 hours");
        assert!(clipboard_request(u, NOW, NOW).is_err());
        assert!(codes_query(u, &CodesQuery { service: Some(&long), since_ms: 0, newer_than: None, wait_ms: 0, latest_only: false }).is_err());
    }
}
