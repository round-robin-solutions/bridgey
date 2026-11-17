//! Quick actions (docs/protocol.md "Quick actions", "Open links right away"): links both ways (`links`, and
//! `links_open_draft1` for links a phone asks to open at once), the phone's media controls for this device's player
//! (`media`, the phone sends commands and this device answers with `media.state`), with the apps' limits.

use serde_json::{json, Map, Value};

pub const LINKS_OPEN: &str = "links_open_draft1";
/// Requests and results are at most 8 KiB; media state 32 KiB.
pub const MAX_REQUEST: usize = 8_192;
pub const MAX_MEDIA_STATE: usize = 32_768;
const MAX_SEQUENCE: u64 = 9_007_199_254_740_991;
const MAX_POSITION: i64 = 604_800;
/// Base64 of at most 16 KiB of JPEG.
const MAX_ARTWORK: usize = 21_848;
pub const MEDIA_CONTROLS: [&str; 6] = ["toggle", "pause", "next", "previous", "seek", "volume"];

/// A web link the apps accept: http or https, a host, no user name or password, no whitespace, control characters or
/// backslashes, a valid port, at most 4,096 bytes (QuickActions.kt, QuickActions.swift).
pub fn validated_web_link(value: &str) -> Option<String> {
    let text = value.trim();
    if text.len() > 4_096 || text.is_empty() || text.chars().any(|c| c.is_whitespace() || (c as u32) < 32 || c == '\\' || c == '\u{7f}') {
        return None;
    }
    let lower = text.to_ascii_lowercase();
    let rest = lower.strip_prefix("https://").or_else(|| lower.strip_prefix("http://"))?;
    let original_rest = &text[text.len() - rest.len()..];
    let end = original_rest.find(['/', '?', '#']).unwrap_or(original_rest.len());
    let authority = &original_rest[..end];
    if authority.contains('@') || authority.is_empty() {
        return None;
    }
    let (host, port) = if let Some(v6) = authority.strip_prefix('[') {
        let close = v6.find(']')?;
        let after = &v6[close + 1..];
        (&v6[..close], after.strip_prefix(':'))
    } else {
        match authority.rsplit_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (authority, None),
        }
    };
    if host.is_empty() || host.contains(['[', ']']) {
        return None;
    }
    if let Some(p) = port {
        let n: u32 = p.parse().ok().filter(|_| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))?;
        if !(1..=65_535).contains(&n) {
            return None;
        }
    }
    Some(text.to_string())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub request_id: String,
    pub feature: String,
    pub action: String,
    pub value: String,
    pub sequence: u64,
}

fn integer(v: Option<&Value>) -> Option<i64> {
    let n = v?.as_number()?;
    n.as_i64().or_else(|| n.as_f64().filter(|f| f.fract() == 0.0 && f.abs() < 9.007e15).map(|f| f as i64))
}

/// `quick.request`: version 1, a UUID request ID, links or media, an action, a string value and a positive sequence.
pub fn decode_request(plain: &[u8]) -> Option<Request> {
    if plain.len() > MAX_REQUEST {
        return None;
    }
    let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(plain) else { return None };
    if integer(o.get("version")) != Some(1) {
        return None;
    }
    let request_id = o.get("requestId")?.as_str().filter(|r| crate::crypto::is_uuid(r))?.to_ascii_lowercase();
    let feature = o.get("feature")?.as_str().filter(|f| matches!(*f, "links" | "media"))?.to_string();
    let action = o.get("action")?.as_str()?.to_string();
    let value = o.get("value").and_then(Value::as_str).unwrap_or("").to_string();
    let sequence = integer(o.get("sequence")).filter(|s| (1..=MAX_SEQUENCE as i64).contains(s))? as u64;
    Some(Request { request_id, feature, action, value, sequence })
}

/// A media command the phone may send, with its value checked (seek 0 to 604800 s, volume 0 to 100).
pub fn media_command(action: &str, value: &str) -> Option<(String, Option<i64>)> {
    match action {
        "toggle" | "pause" | "next" | "previous" => Some((action.into(), None)),
        "seek" => value.trim().parse::<i64>().ok().filter(|v| (0..=MAX_POSITION).contains(v)).map(|v| (action.into(), Some(v))),
        "volume" => value.trim().parse::<i64>().ok().filter(|v| (0..=100).contains(v)).map(|v| (action.into(), Some(v))),
        _ => None,
    }
}

pub fn request_payload(request_id: &str, feature: &str, action: &str, value: &str, sequence: u64) -> String {
    json!({"version": 1, "requestId": request_id, "feature": feature, "action": action, "value": value, "sequence": sequence}).to_string()
}

pub fn result_payload(request_id: &str, feature: &str, accepted: bool, opened: Option<bool>, reason: Option<&str>) -> String {
    let mut o = json!({"version": 1, "requestId": request_id, "feature": feature, "accepted": accepted});
    if let Some(opened) = opened {
        o["opened"] = json!(opened);
    }
    if let Some(reason) = reason {
        o["reason"] = json!(reason);
    }
    o.to_string()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuickResult {
    pub request_id: String,
    pub feature: String,
    pub accepted: bool,
    pub opened: bool,
}

pub fn decode_result(plain: &[u8]) -> Option<QuickResult> {
    if plain.len() > MAX_REQUEST {
        return None;
    }
    let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(plain) else { return None };
    if integer(o.get("version")) != Some(1) {
        return None;
    }
    Some(QuickResult {
        request_id: o.get("requestId")?.as_str()?.to_ascii_lowercase(),
        feature: o.get("feature")?.as_str()?.to_string(),
        accepted: o.get("accepted").and_then(Value::as_bool) == Some(true),
        opened: o.get("opened").and_then(Value::as_bool) == Some(true),
    })
}

fn bounded(o: &Map<String, Value>, key: &str, max: usize) -> String {
    o.get(key).and_then(Value::as_str).unwrap_or("").chars().filter(|c| !c.is_control()).take(max).collect()
}

/// `media.state` from what the host reports about its player: version 1, the player's name, title and artist, playing,
/// position and duration (0 to 604800 s), volume (0 to 100), the commands the player takes, a short detail and
/// optional artwork (base64 JPEG, at most 16 KiB). None when the host's JSON is not an object.
pub fn media_state_payload(host: &str) -> Option<String> {
    let Ok(Value::Object(o)) = serde_json::from_str::<Value>(host) else { return None };
    let clamp = |key: &str, max: i64| integer(o.get(key)).unwrap_or(0).clamp(0, max);
    let controls: Vec<&str> = match o.get("controls") {
        Some(Value::Array(list)) => MEDIA_CONTROLS.iter().copied().filter(|c| list.iter().any(|v| v.as_str() == Some(*c))).collect(),
        _ => MEDIA_CONTROLS.to_vec(),
    };
    let mut state = json!({
        "version": 1,
        "player": bounded(&o, "player", 64),
        "title": bounded(&o, "title", 256),
        "artist": bounded(&o, "artist", 256),
        "playing": o.get("playing").and_then(Value::as_bool).unwrap_or(false),
        "position": clamp("position", MAX_POSITION),
        "duration": clamp("duration", MAX_POSITION),
        "volume": clamp("volume", 100),
        "detail": bounded(&o, "detail", 256),
        "controls": controls,
    });
    if let Some(art) = o.get("artwork").and_then(Value::as_str).filter(|a| !a.is_empty() && a.len() <= MAX_ARTWORK) {
        state["artwork"] = json!(art);
    }
    let text = state.to_string();
    (text.len() <= MAX_MEDIA_STATE).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_follow_the_apps_rules() {
        for good in ["https://example.com", "http://example.com:8080/a?b=c#d", "https://[2001:db8::1]:443/x", "HTTPS://Example.com/Path"] {
            assert!(validated_web_link(good).is_some(), "{good}");
        }
        for bad in ["ftp://example.com", "https://user:pw@example.com", "https://", "https://example.com:0", "https://example.com:70000", "https://exa mple.com", "https://example.com\\x", "javascript:alert(1)", "https://example.com:8a", &format!("https://e.com/{}", "a".repeat(4100))] {
            assert!(validated_web_link(bad).is_none(), "{bad}");
        }
        assert_eq!(validated_web_link("  https://example.com  ").as_deref(), Some("https://example.com"));
    }

    #[test]
    fn requests_and_media_commands() {
        let id = crate::crypto::uuid4();
        let r = decode_request(request_payload(&id, "media", "seek", "42", 3).as_bytes()).unwrap();
        assert_eq!((r.feature.as_str(), r.action.as_str(), r.sequence), ("media", "seek", 3));
        assert!(decode_request(request_payload(&id, "media", "seek", "42", 0).as_bytes()).is_none(), "sequences start at 1");
        assert!(decode_request(request_payload("nope", "media", "toggle", "", 1).as_bytes()).is_none());
        assert!(decode_request(request_payload(&id, "files", "x", "", 1).as_bytes()).is_none());
        assert_eq!(media_command("seek", "604800"), Some(("seek".into(), Some(604_800))));
        assert_eq!(media_command("seek", "604801"), None);
        assert_eq!(media_command("volume", "101"), None);
        assert_eq!(media_command("shell", "rm"), None);
    }

    #[test]
    fn media_state_is_bounded() {
        let host = json!({"player": "Spotify", "title": "x".repeat(400), "playing": true, "position": -5, "duration": 999_999, "volume": 300, "controls": ["toggle", "next", "bogus"]}).to_string();
        let state: Value = serde_json::from_str(&media_state_payload(&host).unwrap()).unwrap();
        assert_eq!(state["title"].as_str().unwrap().chars().count(), 256);
        assert_eq!((state["position"].as_i64(), state["duration"].as_i64(), state["volume"].as_i64()), (Some(0), Some(604_800), Some(100)));
        assert_eq!(state["controls"], json!(["toggle", "next"]));
        assert!(state.get("artwork").is_none());
    }
}
