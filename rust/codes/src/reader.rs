//! One message in, one outcome out, within the budget (Swift `CodeReader`). The model decides; the guard only
//! refuses. A mail that gives no code on the first read gets up to two more reads on snippets around its best
//! tokens, all inside one budget; a text message is read once.

use crate::candidate::Channel;
use crate::email::email_model_snippets;
use crate::guard;
use crate::text::code_guard_text;
use std::time::{Duration, Instant};

/// The whole read, from receipt to answer, never waits longer than this.
pub const BUDGET: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Timeout,
    Unavailable,
    InvalidResponse,
    NotConfigured,
    /// The model is not downloaded (or was removed).
    ModelMissing,
}

impl Failure {
    pub fn wire(self) -> &'static str {
        match self {
            Failure::Timeout => "timeout",
            Failure::Unavailable => "unavailable",
            Failure::InvalidResponse => "invalid_response",
            Failure::NotConfigured => "not_configured",
            Failure::ModelMissing => "model_missing",
        }
    }
}

/// What the engine said about one text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Answer {
    Candidate(String),
    NoCode,
    Failed(Failure),
}

/// What the reader decided for one message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// A code that passed the guard.
    Code(String),
    /// The model found no code, or the guard refused its answer.
    NoCode,
    Fallback(Failure),
}

impl Outcome {
    /// For diagnostics and audits: an outcome word, never the code.
    pub fn word(&self) -> &'static str {
        match self {
            Outcome::Code(_) => "found",
            Outcome::NoCode => "none",
            Outcome::Fallback(f) => f.wire(),
        }
    }
}

/// Where answers come from: the model on this device (`engine::LocalEngine`), or a test fake. `budget` is how long
/// the caller waits; a source that cannot answer in time returns `Failed(Timeout)` and may finish in the
/// background.
pub trait AnswerSource: Send + Sync {
    fn answer(&self, text: &str, sender: Option<&str>, budget: Duration) -> Answer;
}

pub struct Reader<'a> {
    pub source: &'a dyn AnswerSource,
    pub budget: Duration,
}

impl<'a> Reader<'a> {
    pub fn new(source: &'a dyn AnswerSource) -> Reader<'a> {
        Reader { source, budget: BUDGET }
    }

    /// One message, SMS or mail, through the same model, prompt and guard. `text` is the candidate's (joined) text.
    pub fn read(&self, text: &str, sender: Option<&str>, channel: Channel) -> Outcome {
        let deadline = Instant::now() + self.budget;
        let guard_text = code_guard_text(text);
        let mut pieces = vec![text.to_string()];
        if channel == Channel::Email {
            pieces.extend(email_model_snippets(text));
        }
        let mut outcome = Outcome::NoCode;
        for (index, piece) in pieces.iter().enumerate() {
            let left = deadline.saturating_duration_since(Instant::now());
            if left <= Duration::from_millis(50) {
                return if index == 0 { Outcome::Fallback(Failure::Timeout) } else { outcome };
            }
            outcome = match self.source.answer(piece, sender, left) {
                Answer::Candidate(code) => guard::accept(Some(&code), &guard_text).map(Outcome::Code).unwrap_or(Outcome::NoCode),
                Answer::NoCode => Outcome::NoCode,
                Answer::Failed(reason) => Outcome::Fallback(reason),
            };
            if outcome != Outcome::NoCode {
                return outcome;
            }
        }
        outcome
    }
}
