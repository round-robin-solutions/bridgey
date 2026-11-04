//! The prompt the model was trained on (research `common.py`, `user_prompt`) and its JSON answer.

use crate::reader::{Answer, Failure};
use crate::text::MAXIMUM_SENDER_LENGTH;
use crate::utf16;

pub const INSTRUCTION: &str = "Find the one-time code in this SMS. Answer JSON.";
/// The answer is about 13 tokens; 24 leaves room.
pub const MAXIMUM_ANSWER_TOKENS: usize = 24;

/// The user turn: the instruction, the sender (at most 64 UTF-16 units) and the message, for SMS and mail alike.
pub fn user(sender: Option<&str>, text: &str) -> String {
    let from = utf16::prefix(sender.unwrap_or("").trim(), MAXIMUM_SENDER_LENGTH);
    format!("{INSTRUCTION}\nSender: {from}\nSMS: {}", text.trim())
}

/// `{"kind":"otp","code":"482913"}` gives a candidate, `{"kind":"none","code":null}` no code; anything else is an
/// invalid answer (the plain notification shows). Only a string code counts, as on the Mac.
pub fn parse(output: &str) -> Answer {
    let Some(open) = output.find('{') else { return Answer::Failed(Failure::InvalidResponse) };
    let Some(close) = output[open..].find('}').map(|i| open + i) else { return Answer::Failed(Failure::InvalidResponse) };
    let Ok(serde_json::Value::Object(object)) = serde_json::from_str::<serde_json::Value>(&output[open..=close]) else {
        return Answer::Failed(Failure::InvalidResponse);
    };
    let Some(kind) = object.get("kind").and_then(|k| k.as_str()) else { return Answer::Failed(Failure::InvalidResponse) };
    match object.get("code").and_then(|c| c.as_str()) {
        Some(code) if kind == "otp" && !code.is_empty() => Answer::Candidate(code.to_string()),
        _ => Answer::NoCode,
    }
}

/// The answer is complete once its JSON object closes.
pub fn is_complete(output: &str) -> bool {
    output.find('{').is_some_and(|open| output[open..].contains('}'))
}
