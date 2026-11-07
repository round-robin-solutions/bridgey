//! Strict bounded on-demand notification results. Never persisted in the CLI audit.
use crate::errors::CliError;
use serde_json::Value;

pub fn validate_result(payload: Value, query: &str, limit: usize) -> Result<Value, CliError> {
    let invalid = || {
        CliError::new(
            "incompatible",
            "The phone returned an invalid notification snapshot",
        )
    };
    if payload.to_string().len() > 24 * 1024
        || payload["version"].as_u64() != Some(1)
        || payload["queryId"].as_str() != Some(query)
    {
        return Err(invalid());
    }
    if payload["status"] == "unavailable" {
        return Err(CliError::new("unavailable", "Notification reading is unavailable; check notification access and forwarding on the phone"));
    }
    if payload["status"] != "ok" || !payload["truncated"].is_boolean() {
        return Err(invalid());
    }
    let items = payload["notifications"].as_array().ok_or_else(invalid)?;
    if items.len() > limit.min(20) {
        return Err(invalid());
    }
    for item in items {
        for (key, max) in [
            ("id", 128),
            ("packageName", 256),
            ("applicationName", 128),
            ("title", 512),
            ("text", 2048),
        ] {
            if !item[key].as_str().is_some_and(|s| s.chars().count() <= max) {
                return Err(invalid());
            }
        }
        if item["postedAt"].as_u64().is_none() {
            return Err(invalid());
        }
    }
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn snapshot() -> Value {
        json!({"version":1,"queryId":"query","status":"ok","truncated":false,
               "notifications":[{"id":"opaque","packageName":"example.app","applicationName":"Example","title":"Synthetic","text":"Fixture","postedAt":1}]})
    }
    #[test]
    fn accepts_only_bounded_correlated_snapshots() {
        assert!(validate_result(snapshot(), "query", 20).is_ok());
        assert!(validate_result(snapshot(), "different", 20).is_err());
        assert!(validate_result(snapshot(), "query", 0).is_err());
        let mut value = snapshot();
        value["notifications"][0]["text"] = json!("x".repeat(2049));
        assert!(validate_result(value, "query", 20).is_err());
        let mut value = snapshot();
        value["notifications"][0]["postedAt"] = json!(-1);
        assert!(validate_result(value, "query", 20).is_err());
    }
    #[test]
    fn unavailable_is_not_an_empty_success() {
        let err = validate_result(json!({"version":1,"queryId":"query","status":"unavailable","notifications":[],"truncated":false}), "query", 20).unwrap_err();
        assert_eq!(err.code, "unavailable");
    }
}
