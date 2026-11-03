//! Errors with their exit codes (agent-cli.md section 5) and their JSON form.

use serde_json::{json, Map, Value};

#[derive(Clone, Debug)]
pub struct CliError {
    pub code: String,
    pub message: String,
    pub exit: i32,
    pub extra: Map<String, Value>,
}

impl CliError {
    pub fn new(code: &str, message: impl Into<String>) -> CliError {
        CliError { code: code.into(), message: message.into(), exit: exit_for(code), extra: Map::new() }
    }

    pub fn with(mut self, key: &str, value: impl Into<Value>) -> CliError {
        self.extra.insert(key.into(), value.into());
        self
    }

    pub fn to_json(&self) -> Value {
        let mut e = Map::new();
        e.insert("code".into(), json!(self.code));
        e.insert("message".into(), json!(self.message));
        e.insert("exit".into(), json!(self.exit));
        for (k, v) in &self.extra {
            e.insert(k.clone(), v.clone());
        }
        Value::Object(e)
    }

    pub fn from_json(v: &Value) -> CliError {
        let code = v["code"].as_str().unwrap_or("failed").to_string();
        let mut extra = v.as_object().cloned().unwrap_or_default();
        for k in ["code", "message", "exit"] {
            extra.remove(k);
        }
        CliError { exit: v["exit"].as_i64().map(|e| e as i32).unwrap_or_else(|| exit_for(&code)), message: v["message"].as_str().unwrap_or("failed").to_string(), code, extra }
    }
}

impl From<String> for CliError {
    fn from(message: String) -> CliError {
        CliError::new("failed", message)
    }
}

impl From<&str> for CliError {
    fn from(message: &str) -> CliError {
        CliError::new("failed", message)
    }
}

pub fn exit_for(code: &str) -> i32 {
    match code {
        "usage" => 2,
        "unreachable" => 3,
        "timeout" => 4,
        "not_granted" => 5,
        "rate_limited" => 6,
        "declined" | "dismissed" | "rejected" | "unexpected_answer" => 7,
        "not_paired" | "unknown_device" => 8,
        "transfer_failed" => 9,
        "incompatible" | "unsupported" => 10,
        "interrupted_resumable" => 11,
        "interrupted" => 130,
        _ => 1,
    }
}
